import AVFoundation
import CoreVideo
import Foundation
import Vision

struct DetectionResult {
    /// Faces detected at any head angle, including full profile.
    var faceCount: Int
    /// Human bodies detected (upper body — works with the head turned away).
    /// Only computed on face-less frames; 0 whenever faceCount > 0.
    var bodyCount: Int
    /// A face positively matched the enrolled owner (any face when unenrolled).
    var ownerMatched: Bool
    /// A judgeable face was seen that is *confidently* not the owner. An
    /// unmatched-but-ambiguous face does not set this: "don't know" must not be
    /// reported as "not you".
    var strangerSeen: Bool
    /// A judgeable face failed to match without being confidently a stranger.
    /// Distinct from `strangerSeen` because the model is unsure — but distinct
    /// from a turned-away face too, because here it *could* see and still
    /// couldn't confirm. Sustained indefinitely, that is how an ambiguous
    /// intruder would hold the screen, so the chain caps how long it accepts it.
    var frontalButUnmatched: Bool
    /// Sample from the largest near-frontal face — only populated in enrollment mode.
    var enrollmentSample: EnrollmentSample?
    /// When the frame was delivered, captured before any analysis ran. The
    /// presence clock must be stamped with this rather than "now on the main
    /// thread": Vision + up to 4 Core ML embeddings + a main-thread hop sit in
    /// between, and counting that latency as absence made the countdown late.
    var capturedAt: TimeInterval
}

/// Pure generation fence used under `FaceMonitor.stateLock`. Kept separate so
/// the stale-result refusal is testable without constructing AVFoundation.
struct CaptureGenerationGate {
    private(set) var activeID: Int?

    mutating func activate(_ id: Int) { activeID = id }
    mutating func invalidate() { activeID = nil }
    func accepts(_ id: Int) -> Bool { activeID == id }
}

/// Matches a capture-quality observation back to the rectangle observation
/// used for pose gating and embedding. The two Vision requests may order or
/// detect faces differently, so array position is not a safe association.
enum FaceCaptureQualityMatcher {
    static func quality(
        for face: CGRect,
        candidates: [(box: CGRect, quality: Float)],
        minimumOverlap: CGFloat = 0.5
    ) -> Float? {
        let best = candidates.map { candidate in
            (quality: candidate.quality, overlap: intersectionOverUnion(face, candidate.box))
        }.max { $0.overlap < $1.overlap }
        guard let best, best.overlap >= minimumOverlap else { return nil }
        return best.quality
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

/// Low-footprint webcam face watcher: 640x480 capture with Vision analysis
/// throttled to `analysisInterval`, and the embedding model run only on frames
/// where a face was actually detected.
///
/// The analysis throttle is what bounds the cost. The sensor is *asked* for its
/// slowest supported rate, but that request is not always honoured — see
/// `configureIfNeeded` — so no particular frame rate should be assumed.
final class FaceMonitor: NSObject {
    /// Called on an internal queue for every analyzed frame.
    /// Carries the capture-generation ID with the result so the main-thread
    /// consumer can revalidate it after its dispatch hop. Checking only here on
    /// the analysis queue leaves a race where teardown can invalidate the
    /// generation after the check but before the queued callback runs.
    var onResult: ((Int, DetectionResult) -> Void)?

    private let recognizer: FaceRecognizer
    /// Exposed for the enrollment preview layer only.
    let session = AVCaptureSession()
    /// Owns every AVCaptureSession/configuration mutation. Kept separate from
    /// analysis so a Vision/Core ML call that never returns cannot strand stop,
    /// teardown and every retry behind itself. AVFoundation session mutations
    /// remain serialized with each other.
    private let sessionQueue = DispatchQueue(
        label: "com.xavierloo.lockscreen-dah.camera.session",
        qos: .utility
    )
    private var configured = false
    /// Session-queue-owned generation currently attached to `session`.
    private var captureGeneration: CaptureGeneration?
    private var nextGenerationID = 0

    // Everything the main thread and generation queues share, guarded by a lock
    // rather than a sync hop: those queues run Vision + Core ML, so one
    // sync hop from main could stall the UI behind a whole frame analysis —
    // exactly the kind of stall that would blow the countdown's timing.
    private let stateLock = NSLock()
    private var firstFrame: TimeInterval?
    private var lastFrame: TimeInterval?
    /// When `startRunning()` actually returned for this session, or nil while the
    /// session is still being configured (or is stopped).
    ///
    /// Distinct from "when the coordinator asked us to start" on purpose. Opening
    /// the device is slow — device lookup, input creation, session configuration,
    /// then the ISP powering on — measured at ~7.7 s end to end on an M1 Pro
    /// built-in camera. Judging frame staleness against the request instant
    /// declared the camera dead before the system had even been asked to stream.
    private var streamingSince: TimeInterval?
    /// Read by callback queues to reject frames and results from a generation
    /// removed during recovery. Nil is set synchronously before teardown is
    /// dispatched, so a late callback cannot resurrect stale liveness.
    private var generationGate = CaptureGenerationGate()
    private var interval: TimeInterval = 1.5
    private var enrollmentMode = false

    /// Everything that can be poisoned by one stuck Vision/Core ML call. A
    /// rebuilt capture graph gets a fresh instance, including its own serial
    /// delegate queue and mutable inference scratch. The old generation may stay
    /// hung forever without blocking or sharing mutable state with the new one.
    private final class CaptureGeneration: NSObject,
        AVCaptureVideoDataOutputSampleBufferDelegate {
        let id: Int
        let output = AVCaptureVideoDataOutput()
        let faceRequest: VNDetectFaceRectanglesRequest = {
            let request = VNDetectFaceRectanglesRequest()
            request.revision = VNDetectFaceRectanglesRequestRevision3
            return request
        }()
        /// Enrollment-only request. Apple defines this as capture suitability,
        /// not presentation-attack detection; its score is used only to rank
        /// samples captured seconds apart in the same requested pose.
        let faceQualityRequest = VNDetectFaceCaptureQualityRequest()
        let humanRequest: VNDetectHumanRectanglesRequest = {
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = true
            return request
        }()
        let inferenceContext: FaceRecognizer.InferenceContext
        var lastAnalysis = -Double.infinity

        private weak var owner: FaceMonitor?
        private let queue: DispatchQueue

        init(id: Int, owner: FaceMonitor) {
            self.id = id
            self.owner = owner
            inferenceContext = owner.recognizer.makeInferenceContext()
            queue = DispatchQueue(
                label: "com.xavierloo.lockscreen-dah.camera.analysis.\(id)",
                qos: .utility
            )
            super.init()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            owner?.captureOutput(sampleBuffer, from: self)
        }
    }

    /// Enrollment only accepts near-frontal samples (~45°) so the stored
    /// profile is clean; presence detection accepts any head angle.
    private let maxEnrollmentYaw: Float = 0.8
    /// A face is only *judgeable* — eligible to be accused — when it is
    /// near-frontal on both axes (radians, ~30°). Yaw alone was not enough: a
    /// head tipped down at the keyboard is frontal left-to-right, so it was being
    /// judged, failed, and accused the owner's own face. Profile embeddings are
    /// too unreliable to accuse anyone off-angle.
    ///
    /// The pitch tolerance is an informed guess, not a tuned value — see
    /// docs/TESTING.md.
    private let maxStrangerYaw: Float = 0.5
    private let maxStrangerPitch: Float = 0.5
    /// Below this similarity a frontal face is *confidently* not the owner.
    ///
    /// Deliberately far below `matchThreshold`, leaving an ambiguous band
    /// between them. Different identities cluster near zero against a
    /// multi-template profile, so that band is where the owner's own marginal
    /// frames live — head tipped down at the keyboard, a moment of bad light —
    /// not a stranger's.
    ///
    /// This band existed, was removed, and is now back. It was removed because a
    /// stranger scoring inside it could hold the screen open indefinitely — but
    /// that was a fault in the *continuity* rule, which counted any face
    /// regardless of identity. Continuity now ignores a flagged face
    /// (`PresenceTracker.observe`), so the fault is fixed at its source and
    /// collapsing the band only cost the owner false countdowns.
    private let strangerSimilarity: Float = 0.15
    /// At most this many faces get the (pricier) embedding pass per frame.
    private let maxFacesToMatch = 4

    /// Whether the model can fairly be asked about this face. A missing angle
    /// counts as off-angle: the safe reading of "unknown" is "don't judge",
    /// because judging wrongly accuses the owner.
    private func isJudgeable(_ face: VNFaceObservation) -> Bool {
        guard let yaw = face.yaw?.floatValue, let pitch = face.pitch?.floatValue else { return false }
        // Pitch is judged against the resting pose recorded at enrollment. A
        // laptop camera looks down at you, so "level" is ~0.2 rad here and
        // different again on another desk; an absolute bar would mean a
        // different thing for every user.
        return abs(yaw) <= maxStrangerYaw
            && abs(pitch - recognizer.baselinePitch) <= maxStrangerPitch
    }

    init(recognizer: FaceRecognizer) {
        self.recognizer = recognizer
        super.init()
        // A session that hits a runtime error (camera unplugged, device seized
        // by another process, wedged after a sleep/wake device re-enumeration)
        // stays broken forever otherwise: `configured` latches true, so no
        // later start() would ever rebuild the inputs. Drop the whole
        // configuration so the next start() reconstructs it from scratch.
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.camera.error("session runtime error: \(reason?.code ?? 0, privacy: .public); dropping configuration")
            self?.invalidateLiveness()
            self?.sessionQueue.async { self?.teardownConfiguration() }
        }
    }

    /// Returns the session to its pre-configuration state so a subsequent
    /// `start()` re-runs `configureIfNeeded()` against whatever device is
    /// present now. Must run on `sessionQueue`.
    private func teardownConfiguration() {
        if session.isRunning { session.stopRunning() }
        guard configured else { return }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        captureGeneration = nil
        configured = false
        invalidateLiveness()
    }

    var analysisInterval: TimeInterval {
        get { stateLock.lock(); defer { stateLock.unlock() }; return interval }
        set { stateLock.lock(); interval = newValue; stateLock.unlock() }
    }

    var collectEnrollmentSamples: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return enrollmentMode }
        set { stateLock.lock(); enrollmentMode = newValue; stateLock.unlock() }
    }

    /// `completion` runs on the main queue once configuration and startRunning
    /// have finished, whether or not they succeeded. The enrollment preview
    /// needs it: building an `AVCaptureVideoPreviewLayer` from `session` while
    /// this queue is still inside `beginConfiguration`/`addOutput` is
    /// concurrent mutation of one session from two threads, which
    /// AVFoundation does not support (black preview, or a thrown exception on
    /// the connection add).
    func start(completion: (() -> Void)? = nil) {
        // Invalidated here, on the calling thread, rather than inside the block
        // below. Until sessionQueue runs, `lastFrameAt` may still hold the
        // previous session's timestamp, already older than the staleness bar, so
        // the 1 Hz supervisor could tear the new session down within a tick of
        // starting it. Measured: 8 of 10 teardowns reported a frame gap larger
        // than the session had existed, and the retry loop could never escape.
        stateLock.lock()
        let alreadyActive = generationGate.activeID != nil
        stateLock.unlock()
        if !alreadyActive { invalidateLiveness() }

        sessionQueue.async {
            self.configureIfNeeded()
            if self.configured {
                let wasRunning = self.session.isRunning
                if !wasRunning { self.session.startRunning() }
                self.stateLock.lock()
                if !wasRunning { self.streamingSince = Uptime.now }
                if let id = self.captureGeneration?.id {
                    self.generationGate.activate(id)
                }
                self.stateLock.unlock()
            }
            // Fires even when configuration failed, so a caller waiting to show
            // UI is never left hanging on a machine with no usable camera.
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    /// Stops the session **and drops its configuration**, so the next `start()`
    /// rebuilds inputs and outputs from scratch.
    ///
    /// The recovery path needs this rather than `stop()`. `configured` latches
    /// true and was only ever reset by the runtime-error notification, so a
    /// session that wedges *without* posting an error — which is a real state,
    /// the same one that reads as running while delivering nothing — was retried
    /// forever against the identical broken graph. The retry ladder could recover
    /// "the device was briefly busy" and nothing else.
    func teardown() {
        // Synchronous invalidation makes the coordinator stop trusting the old
        // stream immediately. The destructive work uses the independent session
        // queue, so even a permanently hung analysis cannot block recovery.
        invalidateLiveness()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.teardownConfiguration()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            // Liveness must not survive a stop: a stopped session has proven
            // nothing about the future, and leaving it set let the coordinator
            // read "camera is fine" while it was actually off.
            self.invalidateLiveness()
        }
    }

    private func invalidateLiveness() {
        stateLock.lock()
        firstFrame = nil
        lastFrame = nil
        streamingSince = nil
        generationGate.invalidate()
        stateLock.unlock()
    }

    /// When this session actually began streaming, or nil while it is still
    /// opening the device. Nil means "no opinion yet" — the caller must not read
    /// it as a stalled camera; see `MonitorCoordinator.cameraIsStale`.
    var streamingSinceAt: TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamingSince
    }

    /// When the most recent frame arrived, or nil if none has since `start()`.
    ///
    /// This is the app's liveness signal and it is *continuous*: frames arrive at
    /// the sensor's own rate regardless of the analysis throttle, so a gap means
    /// the pipeline has stopped rather than that we're sampling slowly. Checking
    /// it once at startup — as an earlier design did — could not see a session
    /// that died later, which is the failure the user actually hit.
    var lastFrameAt: TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastFrame
    }

    /// When this session delivered its first frame, or nil if it hasn't yet.
    /// The grace clock is anchored no earlier than this: a session that only
    /// just opened has had no opportunity to see anyone, so counting absence
    /// from before it would black out a seated user.
    var firstFrameAt: TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return firstFrame
    }

    /// Retries device configuration on every call rather than giving up
    /// permanently after one failure: a transient hiccup (camera briefly
    /// busy, device still enumerating right after waking from sleep) used to
    /// disable monitoring's ability to ever see anything again for the rest
    /// of the app's life, silently, since nothing else ever re-attempted it.
    private func configureIfNeeded() {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            Log.camera.error("no video device available")
            return
        }
        guard
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            // The usual cause is another process holding the device.
            Log.camera.error("cannot open the video device as an input")
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        session.addInput(input)
        let generation = CaptureGeneration(id: nextGenerationID, owner: self)
        nextGenerationID += 1
        // No videoSettings: keep the camera's native YUV format — skipping the
        // BGRA conversion saves CPU and memory; Vision and CoreImage take YUV.
        guard session.canAddOutput(generation.output) else {
            session.removeInput(input)
            session.commitConfiguration()
            Log.camera.error("cannot add the video data output")
            return
        }
        session.addOutput(generation.output)
        session.commitConfiguration()

        // Ask the sensor for the slowest rate it admits to supporting. This is a
        // *request*, not a guarantee, and on some hardware it is simply ignored:
        // measured on a built-in FaceTime HD Camera whose every format reports
        // 15-30 fps, the device delivered ~27 fps no matter what — including with
        // the session preset removed and the format chosen by hand. So do not
        // document a specific frame rate as fact, and do not build a feature on
        // the assumption that this worked. What actually bounds the expensive
        // work is the analysis throttle in captureOutput; this only trims the
        // capture pipeline on devices that honour it.
        if let slowest = device.activeFormat.videoSupportedFrameRateRanges
            .map(\.minFrameRate).min(), slowest > 0 {
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: Int32(slowest.rounded()))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                // Non-fatal: analysis throttling still bounds the real work.
            }
        }
        captureGeneration = generation
        configured = true
    }

    // MARK: - Frame analysis

    func generationIsActive(_ id: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generationGate.accepts(id)
    }

    private func captureOutput(_ sampleBuffer: CMSampleBuffer, from generation: CaptureGeneration) {
        let now = Uptime.now
        // Counted before the analysis throttle: delivery alone proves the
        // capture pipeline is alive, whether or not this frame gets analyzed.
        stateLock.lock()
        guard generationGate.accepts(generation.id) else {
            stateLock.unlock()
            return
        }
        if firstFrame == nil { firstFrame = now }
        lastFrame = now
        let interval = self.interval
        let enrollmentMode = self.enrollmentMode
        stateLock.unlock()

        guard now - generation.lastAnalysis >= interval else { return }
        generation.lastAnalysis = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([generation.faceRequest])) != nil else { return }
        let faces = generation.faceRequest.results ?? []
        var qualityFaces: [VNFaceObservation] = []
        if enrollmentMode {
            // Keep the revision-pinned rectangle request as the source of pose
            // and embedding geometry. Capture quality is a second observation
            // set and is correlated by overlap below; substituting it directly
            // can lose yaw/pitch or attach another face's score.
            if (try? handler.perform([generation.faceQualityRequest])) != nil {
                qualityFaces = generation.faceQualityRequest.results ?? []
            }
        }

        // The body pass is only a fallback presence signal for when no face is
        // visible at all (head fully turned away) — skip it when a face is in
        // frame, where it could never change the outcome.
        var bodyCount = 0
        if faces.isEmpty, (try? handler.perform([generation.humanRequest])) != nil {
            bodyCount = generation.humanRequest.results?.count ?? 0
        }

        // -1 distinguishes "no face was scored at all" from a genuine 0.0 match.
        var bestSimilarity: Float = -1
        // Recorded alongside the score because a face that is *unjudgeable* sets
        // neither the stranger nor the unconfirmed flag, and therefore sustains
        // seat continuity indefinitely — so "why was this face not judged?" is a
        // question the log has to be able to answer. A nil angle is meaningful:
        // it is read as off-angle, deliberately.
        var bestYaw: Float?
        var bestPitch: Float?
        var bestJudgeable = false
        var result = DetectionResult(
            faceCount: faces.count,
            bodyCount: bodyCount,
            ownerMatched: false,
            strangerSeen: false,
            frontalButUnmatched: false,
            capturedAt: now
        )

        if enrollmentMode {
            let frontal = faces.filter { face in
                guard let yaw = face.yaw else { return true }
                return abs(yaw.floatValue) <= maxEnrollmentYaw
            }
            let largest = frontal.max {
                $0.boundingBox.width * $0.boundingBox.height <
                $1.boundingBox.width * $1.boundingBox.height
            }
            if let largest, let embedding = recognizer.embedding(
                for: largest,
                in: pixelBuffer,
                context: generation.inferenceContext
            ) {
                let captureQuality = FaceCaptureQualityMatcher.quality(
                    for: largest.boundingBox,
                    candidates: qualityFaces.compactMap { qualityFace in
                        qualityFace.faceCaptureQuality.map {
                            (box: qualityFace.boundingBox, quality: $0)
                        }
                    }
                )
                result.enrollmentSample = EnrollmentSample(
                    embedding: embedding,
                    yaw: largest.yaw?.floatValue ?? 0,
                    pitch: largest.pitch?.floatValue ?? 0,
                    captureQuality: captureQuality
                )
            }
        } else if !faces.isEmpty {
            if recognizer.isPresenceOnly {
                result.ownerMatched = true
            } else {
                // Owner among any of the faces counts as a match, even with
                // other people in frame. Largest faces first — the owner is
                // usually the closest to the camera. Turned heads that no
                // longer match are handled upstream by the presence chain.
                let byArea = faces.sorted {
                    $0.boundingBox.width * $0.boundingBox.height >
                    $1.boundingBox.width * $1.boundingBox.height
                }
                for face in byArea.prefix(maxFacesToMatch) {
                    guard let embedding = recognizer.embedding(
                        for: face,
                        in: pixelBuffer,
                        context: generation.inferenceContext
                    ),
                          let similarity = recognizer.similarityToOwner(embedding)
                    else { continue }
                    if similarity > bestSimilarity {
                        bestSimilarity = similarity
                        bestYaw = face.yaw?.floatValue
                        bestPitch = face.pitch?.floatValue
                        bestJudgeable = isJudgeable(face)
                    }
                    if similarity >= Settings.matchThreshold {
                        result.ownerMatched = true
                        break
                    }
                    // Only judge a face the model can fairly be asked about, and
                    // only accuse one it is confident about. A judgeable face
                    // that merely failed to match is reported separately, so the
                    // chain can bound it without treating "don't know" as
                    // "not you" — the conflation that put a blackout on screen.
                    if isJudgeable(face) {
                        if similarity < strangerSimilarity {
                            result.strangerSeen = true
                        } else {
                            result.frontalButUnmatched = true
                        }
                    }
                }
            }
        }

        // Teardown invalidates the generation before session control runs. A
        // hung old inference that eventually returns must not log or answer into
        // the rebuilt session.
        guard generationIsActive(generation.id) else { return }

        // Info level, not debug. Debug is never written to the persistent store,
        // so it can only be watched live — which is useless for a symptom the
        // user reports an hour later, and it wasted a capture attempt proving
        // exactly that. Info stays out of an ordinary `log show`, so a score —
        // not identifying on its own, but biometric-adjacent — still isn't in a
        // default capture, yet it can be read back after the fact:
        //   /usr/bin/log show --info --last 1h \
        //     --predicate 'subsystem == "com.xavierloo.lockscreen-dah" AND category == "recognition"'
        //
        // It is recorded at all because whether the match threshold is too tight
        // has so far been decided by reasoning, and the reasoning has been wrong
        // twice.
        if !enrollmentMode {
            Log.recognition.info(
                "faces=\(result.faceCount, privacy: .public) bodies=\(result.bodyCount, privacy: .public) best=\(bestSimilarity, format: .fixed(precision: 3), privacy: .public) bar=\(Settings.matchThreshold, format: .fixed(precision: 2), privacy: .public) matched=\(result.ownerMatched, privacy: .public) stranger=\(result.strangerSeen, privacy: .public) unconfirmed=\(result.frontalButUnmatched, privacy: .public) judgeable=\(bestJudgeable, privacy: .public) yaw=\(bestYaw.map { String(format: "%+.3f", $0) } ?? "nil", privacy: .public) pitch=\(bestPitch.map { String(format: "%+.3f", $0) } ?? "nil", privacy: .public) baseline=\(self.recognizer.baselinePitch, format: .fixed(precision: 3), privacy: .public)"
            )
        }

        onResult?(generation.id, result)
    }
}

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

/// Low-footprint webcam face watcher: 640x480 capture with Vision analysis
/// throttled to `analysisInterval`, and the embedding model run only on frames
/// where a face was actually detected.
///
/// The analysis throttle is what bounds the cost. The sensor is *asked* for its
/// slowest supported rate, but that request is not always honoured — see
/// `configureIfNeeded` — so no particular frame rate should be assumed.
final class FaceMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on an internal queue for every analyzed frame.
    var onResult: ((DetectionResult) -> Void)?

    private let recognizer: FaceRecognizer
    /// Exposed for the enrollment preview layer only.
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.xavierloo.lockscreen-dah.camera", qos: .utility)
    private var configured = false
    // -infinity rather than 0: uptime starts near 0 at boot, and this must
    // mean "never analyzed" so the first frame is always taken.
    private var lastAnalysis = -Double.infinity

    // Everything the main thread and the camera queue share, guarded by a lock
    // rather than `queue.sync`: the camera queue runs Vision + Core ML, so a
    // sync hop from main could stall the UI behind a whole frame analysis —
    // exactly the kind of stall that would blow the countdown's timing.
    private let stateLock = NSLock()
    private var firstFrame: TimeInterval?
    private var lastFrame: TimeInterval?
    private var interval: TimeInterval = 1.5
    private var enrollmentMode = false

    // Reused across frames (only touched on `queue`) — Vision request objects
    // are stateless between perform calls; only the handler is per-buffer.
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    /// Upper-body detection keeps "present" true while the head is turned
    /// toward another screen (a profile/back-of-head face may not detect).
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        return request
    }()

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
            self?.queue.async { self?.teardownConfiguration() }
        }
    }

    /// Returns the session to its pre-configuration state so a subsequent
    /// `start()` re-runs `configureIfNeeded()` against whatever device is
    /// present now. Must run on `queue`.
    private func teardownConfiguration() {
        guard configured else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        configured = false
        resetLiveness()
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
        queue.async {
            self.configureIfNeeded()
            if self.configured, !self.session.isRunning {
                // Reset liveness only for a genuine (re)start, so an
                // already-running session's proven frame delivery isn't
                // discarded by a no-op call.
                self.resetLiveness()
                self.session.startRunning()
            }
            // Fires even when configuration failed, so a caller waiting to show
            // UI is never left hanging on a machine with no usable camera.
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            // Liveness must not survive a stop: a stopped session has proven
            // nothing about the future, and leaving it set let the coordinator
            // read "camera is fine" while it was actually off.
            self.resetLiveness()
        }
    }

    private func resetLiveness() {
        stateLock.lock()
        firstFrame = nil
        lastFrame = nil
        stateLock.unlock()
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
        output.alwaysDiscardsLateVideoFrames = true
        // No videoSettings: keep the camera's native YUV format — skipping the
        // BGRA conversion saves CPU and memory; Vision and CoreImage take YUV.
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
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

        configured = true
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Uptime.now
        // Counted before the analysis throttle: delivery alone proves the
        // capture pipeline is alive, whether or not this frame gets analyzed.
        stateLock.lock()
        if firstFrame == nil { firstFrame = now }
        lastFrame = now
        let interval = self.interval
        let enrollmentMode = self.enrollmentMode
        stateLock.unlock()

        guard now - lastAnalysis >= interval else { return }
        lastAnalysis = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil else { return }
        let faces = faceRequest.results ?? []

        // The body pass is only a fallback presence signal for when no face is
        // visible at all (head fully turned away) — skip it when a face is in
        // frame, where it could never change the outcome.
        var bodyCount = 0
        if faces.isEmpty, (try? handler.perform([humanRequest])) != nil {
            bodyCount = humanRequest.results?.count ?? 0
        }

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
            if let largest, let embedding = recognizer.embedding(for: largest, in: pixelBuffer) {
                result.enrollmentSample = EnrollmentSample(
                    embedding: embedding,
                    yaw: largest.yaw?.floatValue ?? 0,
                    pitch: largest.pitch?.floatValue ?? 0
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
                    guard let embedding = recognizer.embedding(for: face, in: pixelBuffer),
                          let similarity = recognizer.similarityToOwner(embedding)
                    else { continue }
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

        onResult?(result)
    }
}

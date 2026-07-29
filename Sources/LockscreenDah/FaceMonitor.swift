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
    /// A near-frontal face was seen that didn't match the owner (similarity
    /// below `matchThreshold`) — not just a turned/ambiguous head.
    var strangerSeen: Bool
    /// Sample from the largest near-frontal face — only populated in enrollment mode.
    var enrollmentSample: EnrollmentSample?
    /// When the frame was delivered, captured before any analysis ran. The
    /// presence clock must be stamped with this rather than "now on the main
    /// thread": Vision + up to 4 Core ML embeddings + a main-thread hop sit in
    /// between, and counting that latency as absence made the countdown late.
    var capturedAt: Date
}

/// Low-footprint webcam face watcher: 640x480 capture capped at ~3 fps at the
/// sensor, with Vision analysis further throttled to `analysisInterval`. The
/// embedding model only runs on frames where a face was actually detected.
final class FaceMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on an internal queue for every analyzed frame.
    var onResult: ((DetectionResult) -> Void)?

    private let recognizer: FaceRecognizer
    /// Exposed for the enrollment preview layer only.
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.xavierloo.lockscreen-dah.camera", qos: .utility)
    private var configured = false
    private var lastAnalysis = Date.distantPast

    // Everything the main thread and the camera queue share, guarded by a lock
    // rather than `queue.sync`: the camera queue runs Vision + Core ML, so a
    // sync hop from main could stall the UI behind a whole frame analysis —
    // exactly the kind of stall that would blow the countdown's timing.
    private let stateLock = NSLock()
    private var framesSinceStart = 0
    private var firstFrame: Date?
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
    /// Only faces this frontal (~30°) are eligible to be declared a stranger —
    /// profile embeddings are too unreliable to accuse anyone.
    private let maxStrangerYaw: Float = 0.5
    /// At most this many faces get the (pricier) embedding pass per frame.
    private let maxFacesToMatch = 4

    init(recognizer: FaceRecognizer) {
        self.recognizer = recognizer
    }

    var analysisInterval: TimeInterval {
        get { stateLock.lock(); defer { stateLock.unlock() }; return interval }
        set { stateLock.lock(); interval = newValue; stateLock.unlock() }
    }

    var collectEnrollmentSamples: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return enrollmentMode }
        set { stateLock.lock(); enrollmentMode = newValue; stateLock.unlock() }
    }

    func start() {
        queue.async {
            self.configureIfNeeded()
            guard self.configured, !self.session.isRunning else { return }
            // Reset liveness only for a genuine (re)start, so an already-running
            // session's proven frame delivery isn't discarded by a no-op call.
            self.resetLiveness()
            self.session.startRunning()
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
        framesSinceStart = 0
        firstFrame = nil
        stateLock.unlock()
    }

    /// Whether the capture session has delivered at least one frame since the
    /// most recent `start()`. This is the real "the camera is working"
    /// invariant, and deliberately stronger than `session.isRunning`: a
    /// session can report running while delivering nothing (output never
    /// attached, device wedged), and frames keep arriving even with the lens
    /// covered — so this measures the pipeline, not whether anyone is visible.
    var hasDeliveredFrame: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framesSinceStart > 0
    }

    /// When this session delivered its first frame, or nil if it hasn't yet.
    /// The grace clock is anchored no earlier than this: a session that only
    /// just opened has had no opportunity to see anyone, so counting absence
    /// from before it would black out a seated user.
    var firstFrameAt: Date? {
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
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }

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

        // Cap the sensor frame rate — the capture pipeline dominates CPU cost.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
            let fps = min(max(3, range.minFrameRate), range.maxFrameRate)
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
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
        let now = Date()
        // Counted before the analysis throttle: delivery alone proves the
        // capture pipeline is alive, whether or not this frame gets analyzed.
        stateLock.lock()
        framesSinceStart += 1
        if firstFrame == nil { firstFrame = now }
        let interval = self.interval
        let enrollmentMode = self.enrollmentMode
        stateLock.unlock()

        guard now.timeIntervalSince(lastAnalysis) >= interval else { return }
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
                    yaw: largest.yaw?.floatValue ?? 0
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
                    // similarity < matchThreshold here (the branch above didn't
                    // fire) — no separate, laxer "clear stranger" bar below that:
                    // a gap between the two thresholds left anyone who scored
                    // between them neither matched nor flagged, and the presence
                    // chain's seat-continuity fallback (any face keeps it alive)
                    // then held the screen open for them indefinitely.
                    if let yaw = face.yaw, abs(yaw.floatValue) <= maxStrangerYaw {
                        result.strangerSeen = true
                    }
                }
            }
        }

        onResult?(result)
    }
}

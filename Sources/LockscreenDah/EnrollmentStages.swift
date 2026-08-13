import Foundation

/// One step of the enrollment flow: an instruction, how many samples it needs,
/// and the gate deciding whether a frame actually shows the pose asked for.
///
/// Pure by design — no camera, no AppKit — because every enrollment bug so far
/// has been a wrong number in one of these gates, and the only way to catch
/// those cheaply is to drive them from a test.
struct EnrollmentStage {
    let instruction: String
    let target: Int
    /// Decides whether `sample` shows this stage's pose.
    ///
    /// Rejecting is what stops the flow failing *silently in the useful
    /// direction*: a user who barely tips their head produces samples that land
    /// in the level buckets, no tilted template forms, enrollment passes, and
    /// the profile is no better than before — while appearing to cover the pose.
    ///
    /// The second argument is the samples of **completed stages only**, grouped
    /// by stage. A stage never sees its own in-progress samples, and that is
    /// structural rather than a convention it would be easy to break: when the
    /// gate was handed one flat array of everything collected so far, stage
    /// three's "turn the other way" check averaged in the samples it had just
    /// accepted. The reference direction drifted toward zero, flipped sign after
    /// two captures, and the stage then rejected the exact direction it had been
    /// accepting — a guaranteed stall at 50%, every time.
    let accepts: (EnrollmentSample, [[EnrollmentSample]]) -> Bool
    /// Shown when a sample is rejected, so the correction is obvious.
    let correction: String
}

enum EnrollmentStages {
    /// How far off-centre a head may be and still count as "straight ahead".
    /// Deliberately loose: Vision's yaw wanders by more than a tenth of a radian
    /// on a head that is holding still, so a tight gate here rejects people for
    /// sitting normally.
    static let maxRestingYaw: Float = 0.25

    static let all: [EnrollmentStage] = [
        EnrollmentStage(
            instruction: "Look straight ahead",
            target: 4,
            // No pitch condition: this stage *defines* the resting pose, so it
            // must not assume one. Measured resting pitch is ~0.2 rad on a
            // laptop and varies with screen height — an absolute gate here would
            // reject people for sitting low.
            accepts: { sample, _ in abs(sample.yaw) <= maxRestingYaw },
            correction: "Face the camera straight on"
        ),
        // Neither turn stage depends on which yaw sign means which direction.
        // The preview is mirrored (so it behaves like a mirror) while Vision
        // measures the unmirrored buffer, so "left" on screen and the sign of
        // yaw need not agree. All the profile needs is two *opposite* turns;
        // whichever way the user goes first defines the pair.
        EnrollmentStage(
            instruction: "Turn slightly left",
            target: 4,
            accepts: { sample, _ in abs(sample.yaw) >= FaceRecognizer.turnedYaw },
            correction: "Turn your head a little further"
        ),
        EnrollmentStage(
            instruction: "Now turn slightly right",
            target: 4,
            accepts: { sample, completed in
                guard abs(sample.yaw) >= FaceRecognizer.turnedYaw else { return false }
                // Compared against the previous turn stage's samples alone.
                // Not "every turned sample so far": the straight-ahead gate
                // admits yaw well past `turnedYaw`, so stage one's samples
                // would vote on a direction they never demonstrated.
                let firstTurn = completed.count > 1 ? completed[1] : []
                guard !firstTurn.isEmpty else { return true }
                let reference = firstTurn.reduce(0) { $0 + $1.yaw } / Float(firstTurn.count)
                return sample.yaw * reference < 0
            },
            correction: "Turn the other way instead"
        ),
        // The posture asked about most — typing while looking at the keyboard —
        // and the one the profile had no template for, which is what let the
        // owner's own face score as unrecognised.
        EnrollmentStage(
            instruction: "Now look down at your keyboard",
            target: 4,
            accepts: { sample, completed in
                // Relative to the resting pitch stage one captured, never to
                // zero: a laptop camera sits above the screen and reads ~0.2 rad
                // at rest, so an absolute gate measures desk geometry as much as
                // head movement.
                guard let resting = completed.first, !resting.isEmpty else { return false }
                let baseline = resting.reduce(0) { $0 + $1.pitch } / Float(resting.count)
                return abs(sample.pitch - baseline) > FaceRecognizer.tiltedPitch
            },
            correction: "Tip your head down a little further"
        ),
    ]
}

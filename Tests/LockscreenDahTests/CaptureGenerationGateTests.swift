import XCTest
@testable import LockscreenDah

final class CaptureGenerationGateTests: XCTestCase {
    func testReplacingAGenerationRejectsTheOldOne() {
        var gate = CaptureGenerationGate()
        gate.activate(1)
        XCTAssertTrue(gate.accepts(1))

        gate.activate(2)
        XCTAssertFalse(gate.accepts(1))
        XCTAssertTrue(gate.accepts(2))
    }

    func testInvalidationRejectsLateResultsBeforeReplacementExists() {
        var gate = CaptureGenerationGate()
        gate.activate(7)
        gate.invalidate()

        XCTAssertFalse(gate.accepts(7))
        XCTAssertNil(gate.activeID)
    }
}

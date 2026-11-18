import XCTest
@testable import LumaCamera

final class LockedCaptureValueTests: XCTestCase {
    private struct Pair { let first: Int; let second: Int }
    func testParallelLifecycleSlotAccessNeverPublishesATornPair() {
        let slot = LockedCaptureValue(Pair(first: 0, second: 0))
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<2500 {
                let value = worker*2500+index
                slot.value = Pair(first: value, second: value)
                let snapshot = slot.value
                XCTAssertEqual(snapshot.first, snapshot.second)
            }
        }
        print("CAPTURE-SLOT concurrentWorkers=8 writes=20000 reads=20000 seconds=\(ProcessInfo.processInfo.systemUptime-start); lock CPU cost only")
    }
}

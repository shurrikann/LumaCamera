import XCTest
import QuartzCore
@testable import LumaCamera

final class CameraResumeDiagnosticsTests: XCTestCase {
    func testBlockedProbeIsBoundedAndRecoveryAndStopInvalidateOldReplies() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=CameraResumeDiagnosticStore(directory:directory),clock=DiagnosticClock()
        let monitor=CameraResumeDiagnostics(store:store,clock:{clock.value},automaticSampling:false)
        let replies=DiagnosticReplies()
        monitor.start(context:["preset":"lightTrails"],probes:[
            "main":{reply in replies.capture(reply)},
            "session":{$0(["wantsRunning":"true"])},
            "preview":{$0(["frameAge":"0.1"])}
        ])
        for n in 0..<6 {
            clock.value=Double(n)
            await withCheckedContinuation { c in monitor.sampleForTesting {c.resume()} }
            await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        }
        XCTAssertEqual(replies.count,1,"被阻塞的队列只能有一个待执行探针")
        replies.reply()
        await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        clock.value=6
        await withCheckedContinuation { c in monitor.sampleForTesting {c.resume()} }
        await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        monitor.stop()
        await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        replies.reply() // 停止后的旧响应不能恢复旧观察窗口。
        await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        await withCheckedContinuation { c in store.flushForTesting {c.resume()} }
        let events=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:directory.appendingPathComponent("recent.json")))
        let stalled=try XCTUnwrap(events.first{$0["stage"] == "stalled"})
        XCTAssertEqual(stalled["unanswered"],"main")
        XCTAssertTrue(events.contains{$0["stage"] == "recovered"})
        XCTAssertEqual(events.last?["stage"],"stop")
        print("RESUME-DIAGNOSTIC blockedMainPendingMax=1 sampledTicks=7 recovered=true lateReplyIgnored=true")
    }

    func testMissingFramesWithResponsiveQueuesIsDistinguishedFromBlockedMain() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=CameraResumeDiagnosticStore(directory:directory),clock=DiagnosticClock()
        let monitor=CameraResumeDiagnostics(store:store,clock:{clock.value},automaticSampling:false)
        monitor.start(context:[:],probes:["main":{$0(["ready":"false"])},"session":{$0(["configured":"true"])},"preview":{$0(["frameAge":"unavailable"])}])
        for n in 0..<5 {
            clock.value=Double(n)
            await withCheckedContinuation { c in monitor.sampleForTesting {c.resume()} }
            await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        }
        clock.value=21
        await withCheckedContinuation { c in monitor.sampleForTesting {c.resume()} }
        await withCheckedContinuation { c in store.flushForTesting {c.resume()} }
        let events=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:directory.appendingPathComponent("recent.json")))
        let stalled=try XCTUnwrap(events.first{$0["stage"] == "stalled"})
        XCTAssertEqual(stalled["unanswered"],"");XCTAssertEqual(stalled["staleFrame"],"true")
        XCTAssertEqual(events.last?["stage"],"observation-ended")
        monitor.stop()
        await withCheckedContinuation { c in monitor.drainForTesting {c.resume()} }
        await withCheckedContinuation { c in store.flushForTesting {c.resume()} }
    }

    func testBoundedPersistenceAndEnqueuePerformance() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=CameraResumeDiagnosticStore(directory:directory)
        var times=[Double]();let began=CACurrentMediaTime()
        for n in 0..<100 {
            let start=CACurrentMediaTime()
            store.append(["stage":"test","sequence":String(n)])
            times.append((CACurrentMediaTime()-start)*1000)
        }
        await withCheckedContinuation { c in store.flushForTesting {c.resume()} }
        let data=try Data(contentsOf:directory.appendingPathComponent("recent.json"))
        let events=try JSONDecoder().decode([[String:String]].self,from:data)
        XCTAssertEqual(events.count,64);XCTAssertEqual(events.first?["sequence"],"36")
        XCTAssertEqual(events.last?["sequence"],"99")
        XCTAssertLessThan(data.count,65536)
        let reopened=CameraResumeDiagnosticStore(directory:directory)
        reopened.append(["stage":"reopened"])
        await withCheckedContinuation { c in reopened.flushForTesting {c.resume()} }
        let restored=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:directory.appendingPathComponent("recent.json")))
        XCTAssertEqual(restored.count,64);XCTAssertEqual(restored.last?["stage"],"reopened")
        times.sort()
        print("RESUME-DIAGNOSTIC-WRITE samples=100 enqueueMedianMS=\(times[50]) enqueueMaxMS=\(times.last!) wallWithDiskSeconds=\(CACurrentMediaTime()-began) bytes=\(data.count) retained=64 notFPS=true")
    }
}

private final class DiagnosticClock: @unchecked Sendable {
    private let lock=NSLock();private var time=0.0
    var value:Double {get {lock.lock();defer{lock.unlock()};return time} set{lock.lock();time=newValue;lock.unlock()}}
}
private final class DiagnosticReplies: @unchecked Sendable {
    private let lock=NSLock();private var callbacks=[([String:String])->Void]()
    var count:Int {lock.lock();defer{lock.unlock()};return callbacks.count}
    func capture(_ reply:@escaping ([String:String])->Void){lock.lock();callbacks.append(reply);lock.unlock()}
    func reply(){lock.lock();let callback=callbacks.last;lock.unlock();callback?(["ready":"true"])}
}

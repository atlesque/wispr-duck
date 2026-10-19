import Foundation
import XCTest

private final class TestAudioBackend: AudioBackend {
    var onStart: (() -> Void)?
    var onDuck: ((DuckingConfiguration) -> Bool)?
    var onRestore: ((Bool) -> Void)?
    var onPermission: (() -> String?)?
    var onShutdown: (() -> Void)?

    func startMonitoring(
        onAppsChanged: @escaping ([AudioApp], [AudioApp]) -> Void,
        onError: @escaping (String) -> Void
    ) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        onStart?()
        onAppsChanged([AudioApp(bundleID: "music", name: "Music")], [])
        onError("Test error")
    }

    func duck(bundleIDs: Set<String>, duckAll: Bool, duckLevel: Float) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return onDuck?(DuckingConfiguration(bundleIDs: bundleIDs, duckAll: duckAll, level: duckLevel)) ?? true
    }

    func restoreAll() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        onRestore?(false)
    }

    func restoreAllWithFade() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        onRestore?(true)
    }

    func requestSystemAudioPermissionPrompt() -> String? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return onPermission?()
    }

    func shutdown() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        onShutdown?()
    }
}

final class AudioCoordinatorTests: XCTestCase {
    private let initial = DuckingConfiguration(bundleIDs: ["music"], duckAll: false, level: 0.1)

    @objc func testSlowStartupDoesNotBlockUIAndCallbacksReturnOnMain() {
        let backend = TestAudioBackend()
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Startup blocked in audio server")
        let heartbeat = expectation(description: "UI handles event during startup")
        let apps = expectation(description: "App snapshot on main")
        let error = expectation(description: "Error on main")
        backend.onStart = {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        let coordinator = AudioCoordinator { _ in backend }
        coordinator.start { audioApps, _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(audioApps.map(\.bundleID), ["music"])
            apps.fulfill()
        } onError: { _ in
            XCTAssertTrue(Thread.isMainThread)
            error.fulfill()
        } onDuckingChanged: { _ in }
        DispatchQueue.main.async { heartbeat.fulfill() }
        wait(for: [entered, heartbeat], timeout: 1)
        gate.signal()
        wait(for: [apps, error], timeout: 1)
    }

    @objc func testBlockedDuckCoalescesRefreshesAndRejectsStaleResultAfterRestore() {
        let backend = TestAudioBackend()
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Ducking blocked")
        let heartbeat = expectation(description: "Tray clicks can be processed")
        let finished = expectation(description: "Latest request applied")
        let latest = DuckingConfiguration(bundleIDs: ["browser"], duckAll: true, level: 0.3)
        var calls: [DuckingConfiguration] = []
        var events: [String] = []
        var publishedStates: [Bool] = []
        backend.onDuck = { configuration in
            calls.append(configuration)
            events.append("duck")
            if calls.count == 1 {
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 3)
            }
            return true
        }
        backend.onRestore = { fade in events.append(fade ? "fade" : "restore") }
        let coordinator = AudioCoordinator { _ in backend }
        coordinator.start(onAppsChanged: { _, _ in }, onError: { _ in }) { state in
            XCTAssertTrue(Thread.isMainThread)
            publishedStates.append(state)
            if state { finished.fulfill() }
        }
        coordinator.updateDucking(initial)
        wait(for: [entered], timeout: 1)
        // Repeated timer ticks and setting changes must not build a backlog.
        for _ in 0..<100 { coordinator.updateDucking(initial) }
        coordinator.restore(fade: true)
        coordinator.updateDucking(latest)
        DispatchQueue.main.async { heartbeat.fulfill() }
        wait(for: [heartbeat], timeout: 1)
        gate.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(calls, [initial, latest])
        XCTAssertEqual(events, ["duck", "fade", "duck"])
        XCTAssertEqual(publishedStates, [false, true])
    }

    @objc func testSlowRestoreDoesNotBlockUI() {
        for fade in [false, true] {
            let backend = TestAudioBackend()
            let gate = DispatchSemaphore(value: 0)
            let entered = expectation(description: "Cleanup blocked")
            let heartbeat = expectation(description: "UI handles event during cleanup")
            let stopped = expectation(description: "Cleanup finishes in order")
            backend.onRestore = { actualFade in
                XCTAssertEqual(actualFade, fade)
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 3)
            }
            let coordinator = AudioCoordinator { _ in backend }
            coordinator.restore(fade: fade)
            DispatchQueue.main.async { heartbeat.fulfill() }
            wait(for: [entered, heartbeat], timeout: 1)
            gate.signal()
            coordinator.shutdown { stopped.fulfill() }
            wait(for: [stopped], timeout: 1)
        }
    }

    @objc func testShutdownSuppressesInFlightDuckingAndPendingRefreshes() {
        let backend = TestAudioBackend()
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Ducking blocked")
        let stopped = expectation(description: "Shutdown completed on main")
        var duckCount = 0
        var publishedStates: [Bool] = []
        backend.onDuck = { _ in
            duckCount += 1
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return true
        }
        let coordinator = AudioCoordinator { _ in backend }
        coordinator.start(onAppsChanged: { _, _ in }, onError: { _ in }) {
            publishedStates.append($0)
        }
        coordinator.updateDucking(initial)
        wait(for: [entered], timeout: 1)
        coordinator.updateDucking(initial)
        coordinator.shutdown {
            XCTAssertTrue(Thread.isMainThread)
            stopped.fulfill()
        }
        coordinator.updateDucking(initial)
        gate.signal()
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(duckCount, 1)
        XCTAssertEqual(publishedStates, [false])
    }

    @objc func testPermissionRequestDoesNotBlockUI() {
        let backend = TestAudioBackend()
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "Permission request blocked")
        let heartbeat = expectation(description: "UI handles event during permission request")
        let completed = expectation(description: "Permission result on main")
        backend.onPermission = {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return "Permission denied"
        }
        let coordinator = AudioCoordinator { _ in backend }
        coordinator.requestSystemAudioPermissionPrompt { message in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(message, "Permission denied")
            completed.fulfill()
        }
        DispatchQueue.main.async { heartbeat.fulfill() }
        wait(for: [entered, heartbeat], timeout: 1)
        gate.signal()
        wait(for: [completed], timeout: 1)
    }

    @objc func testDeinitializationCleansUpOnAudioQueue() {
        let backend = TestAudioBackend()
        let stopped = expectation(description: "Backend cleaned up off main")
        backend.onShutdown = { stopped.fulfill() }
        var coordinator: AudioCoordinator? = AudioCoordinator { _ in backend }
        XCTAssertNotNil(coordinator)
        coordinator = nil
        wait(for: [stopped], timeout: 1)
    }
}

@main
struct AudioCoordinatorTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: AudioCoordinatorTests.self)
        precondition(suite.testCaseCount == 6, "Expected six audio regression tests")
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import smbmounter

/// In-memory MounterProtocol for deterministic state-machine tests. Tracks an
/// internal `mounted` flag so currentMountInfo reflects reality the way the real
/// mounter (backed by getmntinfo) would.
final class MockMounter: MounterProtocol {
    private let lock = NSLock()
    private var mounted = false

    var shouldFailMount = false
    var failMountsRemaining = 0      // fail this many calls, then start succeeding
    var mountErrorToThrow: MounterError = .commandFailed(exit: 1, stderr: "mock failure")
    private(set) var mountCalls = 0
    private(set) var unmountCalls = 0
    private(set) var forceUnmountCalls = 0

    /// Pretend a mount already exists (for the "adopt existing" path).
    func presetMounted() { lock.lock(); mounted = true; lock.unlock() }

    func mount(_ config: MountConfig) throws -> MountInfo {
        lock.lock()
        mountCalls += 1
        let failNow = shouldFailMount || failMountsRemaining > 0
        if failMountsRemaining > 0 { failMountsRemaining -= 1 }
        let err = mountErrorToThrow
        lock.unlock()
        if failNow { throw err }
        lock.lock(); mounted = true; lock.unlock()
        return MountInfo(deviceID: 4242,
                         fromName: "//\(config.username)@\(config.server)/\(config.share)",
                         mountpoint: config.mountpoint)
    }

    func unmount(mountpoint: String, force: Bool) throws {
        lock.lock(); unmountCalls += 1; mounted = false; lock.unlock()
    }

    func forceUnmount(mountpoint: String) {
        lock.lock(); forceUnmountCalls += 1; mounted = false; lock.unlock()
    }

    func currentMountInfo(mountpoint: String) -> MountInfo? {
        lock.lock(); defer { lock.unlock() }
        return mounted ? MountInfo(deviceID: 4242, fromName: "//mock", mountpoint: mountpoint) : nil
    }
}

final class MountSupervisorTests: XCTestCase {
    /// Build a config that won't fire timers during the test (huge probe interval,
    /// idle disabled, no keepalive touch on a real filesystem).
    private func makeConfig(name: String = "test", mountAtStartup: Bool = true, failedRetrySec: Int = 0) -> MountConfig {
        MountConfig(
            name: name,
            server: "mammoth",
            share: "mammoth",
            mountpoint: "/tmp/smbmounter-test-\(name)",
            username: "floof",
            mountOptions: ["soft"],
            probeIntervalSec: 3600,
            probeTimeoutSec: 5,
            recoverBackoffSec: [1],
            idleUnmountMin: 0,
            mountAtStartup: mountAtStartup,
            createKeepalive: false,
            keepaliveFilename: ".smbmounter-keepalive",
            probeFailureThreshold: 3,
            failedRetrySec: failedRetrySec,
            localUser: nil
        )
    }

    func testMountSuccessReachesMounted() {
        let mock = MockMounter()
        let sup = MountSupervisor(config: makeConfig(), mounter: mock)
        let done = expectation(description: "mounted")
        sup.requestMount { result in
            if case .failure(let e) = result { XCTFail("operation failed: \(e)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Mounted")
        XCTAssertEqual(mock.mountCalls, 1)
    }

    func testMountFailureReachesFailed() {
        let mock = MockMounter()
        mock.shouldFailMount = true
        let sup = MountSupervisor(config: makeConfig(), mounter: mock)
        let done = expectation(description: "failed")
        sup.requestMount { result in
            if case .success = result { XCTFail("expected failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Failed")
        XCTAssertNotNil(sup.snapshot().lastError)
    }

    func testUnmountReturnsToUnmounted() {
        let mock = MockMounter()
        let sup = MountSupervisor(config: makeConfig(), mounter: mock)
        let mounted = expectation(description: "mounted")
        sup.requestMount { _ in mounted.fulfill() }
        wait(for: [mounted], timeout: 5)

        let unmounted = expectation(description: "unmounted")
        sup.requestUnmount(force: false) { result in
            if case .failure(let e) = result { XCTFail("operation failed: \(e)") }
            unmounted.fulfill()
        }
        wait(for: [unmounted], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Unmounted")
        XCTAssertEqual(mock.unmountCalls, 1)
    }

    func testAdoptsExistingMountWithoutCallingMount() {
        let mock = MockMounter()
        mock.presetMounted()   // already mounted out-of-band
        let sup = MountSupervisor(config: makeConfig(), mounter: mock)
        let done = expectation(description: "adopted")
        sup.requestMount { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Mounted")
        XCTAssertEqual(mock.mountCalls, 0, "should adopt the existing mount, not re-mount")
    }

    func testProbeNowFailsWhenNotMounted() {
        let mock = MockMounter()
        let sup = MountSupervisor(config: makeConfig(mountAtStartup: false), mounter: mock)
        let done = expectation(description: "probe")
        sup.requestProbeNow { outcome in
            XCTAssertFalse(outcome.isOK)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testStartWithMountAtStartupFalseStaysUnmounted() {
        let mock = MockMounter()
        let sup = MountSupervisor(config: makeConfig(mountAtStartup: false), mounter: mock)
        sup.start()
        // Give the async start a moment, then confirm nothing mounted.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(sup.snapshot().state, "Unmounted")
        XCTAssertEqual(mock.mountCalls, 0)
    }

    /// A transient failure (e.g. the cold-boot network race) should auto-retry on
    /// the failed-retry timer and recover once the mount starts succeeding.
    func testTransientFailureRetriesUntilSuccess() {
        let mock = MockMounter()
        mock.failMountsRemaining = 1          // first attempt fails transiently, then succeeds
        let sup = MountSupervisor(config: makeConfig(failedRetrySec: 1), mounter: mock)
        sup.start()                            // mounts at startup → fails → schedules retry (1s)
        let done = expectation(description: "recovered via retry")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Mounted")
        XCTAssertGreaterThanOrEqual(mock.mountCalls, 2)   // initial + at least one retry
    }

    /// An auth failure must NOT auto-retry (avoid hammering the server / lockout).
    func testAuthFailureDoesNotRetry() {
        let mock = MockMounter()
        mock.shouldFailMount = true
        mock.mountErrorToThrow = .netfs(rc: 80)   // EAUTH — non-transient
        let sup = MountSupervisor(config: makeConfig(failedRetrySec: 1), mounter: mock)
        sup.start()
        let done = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Failed")
        XCTAssertEqual(mock.mountCalls, 1, "auth failures must not be retried")
    }
}

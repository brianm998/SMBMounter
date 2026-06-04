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
    var forceUnmountSucceeds = true  // whether forceUnmount manages to clear the mount
    var pretendUnhealthy = false     // mounted, but currentMountInfo can't get a baseline (wedged)
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

    @discardableResult
    func forceUnmount(mountpoint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        forceUnmountCalls += 1
        if forceUnmountSucceeds { mounted = false }
        return forceUnmountSucceeds
    }

    func currentMountInfo(mountpoint: String) -> MountInfo? {
        lock.lock(); defer { lock.unlock() }
        if pretendUnhealthy { return nil }   // present, but no healthy baseline (wedged)
        return mounted ? MountInfo(deviceID: 4242, fromName: "//mock", mountpoint: mountpoint) : nil
    }

    func isMounted(mountpoint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mounted
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

    /// A mount timeout (the wedged-SMB watchdog firing) is transient: it must
    /// auto-retry and recover once the mount starts succeeding again.
    func testTimedOutMountRetriesUntilSuccess() {
        let mock = MockMounter()
        mock.failMountsRemaining = 1
        mock.mountErrorToThrow = .timedOut       // watchdog killed a wedged mount
        let sup = MountSupervisor(config: makeConfig(failedRetrySec: 1), mounter: mock)
        sup.start()
        let done = expectation(description: "recovered via retry")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Mounted")
        XCTAssertGreaterThanOrEqual(mock.mountCalls, 2)
    }

    /// A stale/wedged mount occupying the mountpoint must be force-cleared before a
    /// fresh mount is attempted (so we never mount onto an occupied, hanging path).
    func testStaleMountIsForceClearedBeforeRemount() {
        let mock = MockMounter()
        mock.presetMounted()           // a mount occupies the path...
        mock.pretendUnhealthy = true   // ...but it's wedged: no healthy baseline
        let sup = MountSupervisor(config: makeConfig(mountAtStartup: false), mounter: mock)
        let done = expectation(description: "remounted")
        sup.requestMount { result in
            if case .failure(let e) = result { XCTFail("operation failed: \(e)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Mounted")
        XCTAssertEqual(mock.forceUnmountCalls, 1, "the wedged mount should be force-cleared first")
        XCTAssertEqual(mock.mountCalls, 1, "then a fresh mount is performed")
    }

    /// If the wedged mount cannot be force-cleared, fail fast (don't launch a doomed
    /// mount) — and, since it's transient, keep retrying on the slow timer.
    func testUnclearableWedgedMountFailsFastWithoutMounting() {
        let mock = MockMounter()
        mock.presetMounted()
        mock.pretendUnhealthy = true
        mock.forceUnmountSucceeds = false       // kernel mount is wedged; can't clear
        let sup = MountSupervisor(config: makeConfig(mountAtStartup: false, failedRetrySec: 0), mounter: mock)
        let done = expectation(description: "failed fast")
        sup.requestMount { result in
            if case .success = result { XCTFail("expected failure while the mount is wedged") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(sup.snapshot().state, "Failed")
        XCTAssertEqual(mock.mountCalls, 0, "must not attempt a mount onto an uncleared, hanging path")
        XCTAssertGreaterThanOrEqual(mock.forceUnmountCalls, 1)
    }
}

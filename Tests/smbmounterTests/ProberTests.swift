// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Foundation
@testable import smbmounter

final class ProberTests: XCTestCase {
    func testStatWithTimeoutSucceedsForExistingPath() {
        switch Prober.statWithTimeout("/", timeout: 5) {
        case .success: break
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
    }

    func testStatWithTimeoutFailsForMissingPath() {
        switch Prober.statWithTimeout("/no/such/path/here-xyz", timeout: 5) {
        case .success: XCTFail("expected failure")
        case .failure(.errno(let e)): XCTAssertEqual(e, ENOENT)
        case .failure(.timedOut): XCTFail("unexpected timeout")
        }
    }

    func testProbeDetectsDeviceMismatch() {
        // Capture "/"'s real device, then claim we expected a different one.
        var st = stat()
        XCTAssertEqual(stat("/", &st), 0)
        let wrongDevice = st.st_dev &+ 1
        let outcome = Prober.probe(mountpoint: "/", expectedDevice: wrongDevice, keepalivePath: nil, timeout: 5)
        XCTAssertFalse(outcome.isOK)
    }

    func testProbeOKWhenDeviceMatches() {
        var st = stat()
        XCTAssertEqual(stat("/", &st), 0)
        let outcome = Prober.probe(mountpoint: "/", expectedDevice: st.st_dev, keepalivePath: nil, timeout: 5)
        XCTAssertTrue(outcome.isOK)
    }
}

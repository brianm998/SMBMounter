// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import smbmounter

final class MounterTests: XCTestCase {
    func testPercentEncodePassesThroughUnreserved() {
        XCTAssertEqual(Mounter.percentEncode("floof"), "floof")
        XCTAssertEqual(Mounter.percentEncode("a-b_c.d~e"), "a-b_c.d~e")
    }

    func testPercentEncodeEscapesSpacesAndReserved() {
        XCTAssertEqual(Mounter.percentEncode("My Share"), "My%20Share")
        XCTAssertEqual(Mounter.percentEncode("a/b"), "a%2Fb")
        XCTAssertEqual(Mounter.percentEncode("user@host"), "user%40host")
    }

    func testNetfsURLPlain() {
        XCTAssertEqual(Mounter.netfsURL(server: "mammoth.local", share: "mammoth")?.absoluteString,
                       "smb://mammoth.local/mammoth")
    }

    func testNetfsURLEncodesShare() {
        XCTAssertEqual(Mounter.netfsURL(server: "192.168.1.10", share: "My Share")?.absoluteString,
                       "smb://192.168.1.10/My%20Share")
    }
}

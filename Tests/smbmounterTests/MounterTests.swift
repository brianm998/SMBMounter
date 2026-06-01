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

    func testSMBURLPlain() {
        XCTAssertEqual(Mounter.smbURL(user: "floof", server: "mammoth", share: "mammoth"),
                       "//floof@mammoth/mammoth")
    }

    func testSMBURLEncodesUserAndShareButNotServer() {
        XCTAssertEqual(Mounter.smbURL(user: "floof", server: "192.168.1.10", share: "My Share"),
                       "//floof@192.168.1.10/My%20Share")
    }
}

import XCTest
@testable import Todo2Ink

final class Todo2InkTests: XCTestCase {
    func testAppIdIsStable() {
        XCTAssertEqual(
            Todo2InkPeer.appId.uuidString,
            "06601C50-AB2E-5C2E-97D2-25BAEED7FBF0",
            "Todo2Ink's appId must never change — see Todo2InkPeer.swift's doc comment."
        )
    }
}

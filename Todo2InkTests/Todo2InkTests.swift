import CompanionKit
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

    /// The firmware resolves every list-navigation button through this declared routing map with no
    /// default case, so a button we don't bind does nothing on the device. This asserts the routing
    /// the device actually reads off the wire (`encodedBody()`), not just the Swift model, since a
    /// correct-looking `ButtonMapEntry` array with a codec bug would still leave the reader inert.
    func testListButtonsRouteLocallyOnTheWire() {
        let expectedRouting: [CompanionButton: ButtonRouting] = [
            .left: .localListMoveUp,
            .right: .localListMoveDown,
            .up: .localListSwitchLeft,
            .down: .localListSwitchRight,
            .confirm: .localListToggleCheck,
            .back: .localBack,
        ]

        XCTAssertEqual(Set(Todo2InkPeer.uiDeclaration.buttons.map(\.button)), Set(expectedRouting.keys))
        for entry in Todo2InkPeer.uiDeclaration.buttons {
            XCTAssertEqual(entry.routing, expectedRouting[entry.button], "\(entry.button) is misrouted")
        }

        // Decode button entries back out of encodedBody() the way the device would: shape byte,
        // button count, then (button|flags, routing, labelLen, label) per entry.
        let body = [UInt8](Todo2InkPeer.uiDeclaration.encodedBody())
        var offset = 1 // skip shape byte
        let buttonCount = Int(body[offset]); offset += 1
        var decodedRouting: [UInt8: UInt8] = [:]
        for _ in 0..<buttonCount {
            let buttonByte = body[offset]; offset += 1
            let routingByte = body[offset]; offset += 1
            let labelLen = Int(body[offset]); offset += 1
            offset += labelLen
            decodedRouting[buttonByte] = routingByte
        }

        for (button, routing) in expectedRouting {
            XCTAssertEqual(
                decodedRouting[button.rawValue],
                routing.rawValue,
                "\(button) must encode routing 0x\(String(routing.rawValue, radix: 16)) on the wire"
            )
        }
    }
}

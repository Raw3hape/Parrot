import SwiftUI
import XCTest
@testable import Parrot

final class TypographyTests: XCTestCase {
    func testMeetingTitleUsesDefaultSystemDesign() {
        XCTAssertEqual(Theme.Typography.titleDesign, .default)
    }
}

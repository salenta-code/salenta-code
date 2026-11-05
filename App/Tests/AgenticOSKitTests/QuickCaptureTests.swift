import XCTest
@testable import AgenticOSKit

// Braucht Xcode (die Command Line Tools enthalten kein XCTest).
final class QuickCaptureTests: XCTestCase {
    func testTagsPriorityAgent() {
        let t = QuickCapture.parse("Theme-Bug Filter #arbeit @claude !")
        XCTAssertEqual(t.title, "Theme-Bug Filter")
        XCTAssertEqual(t.company.rawValue, "arbeit")
        XCTAssertEqual(t.agent, .claude)
        XCTAssertEqual(t.priority, .hoch)
        XCTAssertEqual(t.status, .heute)
    }

    func testTomorrowGoesToWeek() {
        let t = QuickCapture.parse("Angebot schreiben #arbeit morgen")
        XCTAssertEqual(t.company.rawValue, "arbeit")
        XCTAssertEqual(t.status, .woche)
        XCTAssertNotNil(t.due)
    }

    func testTolerantDecoding() throws {
        let json = #"[{"title":"Von Claude","company":"Arbeit","due":"2026-11-05","priority":"hoch"}]"#
        let file = try TaskFile.decode(Data(json.utf8))
        XCTAssertEqual(file.tasks.first?.company.rawValue, "arbeit")
        XCTAssertEqual(file.tasks.first?.priority, .hoch)
        XCTAssertNotNil(file.tasks.first?.due)
    }

    func testUnknownAreaIsKept() throws {
        let file = try TaskFile.decode(Data(#"[{"title":"Alt","company":"altefirma"}]"#.utf8))
        XCTAssertEqual(file.tasks.first?.company.rawValue, "altefirma")
    }

    func testAreaMatchByKeyword() {
        AreaRegistry.areas = AreaRegistry.fallback + [AreaDef(id: "shop", title: "Mein Shop", hex: 0, symbol: "cart", tags: ["shop"], keywords: ["storefront"])]
        XCTAssertEqual(Company.match(in: "/Users/x/Code/storefront-theme")?.rawValue, "shop")
        AreaRegistry.areas = AreaRegistry.fallback
    }
}

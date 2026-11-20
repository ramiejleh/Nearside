import NearsideCore
import XCTest

final class LauncherGridTests: XCTestCase {
    // Recents: 4 (one row), All: 10 (rows of 4: 0-3, 4-7, 8-9).
    let grid = LauncherGrid(sections: [4, 10], columns: 4)

    func testLeftRightRunThrough() {
        XCTAssertEqual(grid.moving(0, .left), 0)
        XCTAssertEqual(grid.moving(3, .right), 4)
        XCTAssertEqual(grid.moving(13, .right), 13)
    }

    func testDownKeepsColumnAcrossSections() {
        XCTAssertEqual(grid.moving(2, .down), 6)   // recents col 2 → all row 0 col 2
        XCTAssertEqual(grid.moving(6, .down), 10)  // row 1 → row 2
        XCTAssertEqual(grid.moving(11, .down), 13) // col 3 → short last row: its last
        XCTAssertEqual(grid.moving(12, .down), 12) // bottom stays
    }

    func testUpKeepsColumnAcrossSections() {
        XCTAssertEqual(grid.moving(6, .up), 2)
        XCTAssertEqual(grid.moving(13, .up), 9)
        XCTAssertEqual(grid.moving(1, .up), 1)
    }

    func testShortSectionAbove() {
        let g = LauncherGrid(sections: [2, 8], columns: 4)
        XCTAssertEqual(g.moving(5, .up), 1) // col 3 → recents has only 2
        XCTAssertEqual(g.moving(1, .down), 3)
    }

    func testEmptySectionsSkipped() {
        let g = LauncherGrid(sections: [3, 0, 5], columns: 4)
        XCTAssertEqual(g.moving(1, .down), 4)
        XCTAssertEqual(g.moving(4, .up), 1)
        XCTAssertEqual(LauncherGrid(sections: [], columns: 4).moving(0, .down), 0)
    }
}

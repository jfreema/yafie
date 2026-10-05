import CoreGraphics
import Testing
@testable import Yafie

/// A display with a 25-point menu bar across its top
private func display(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> SnapLayout.Display {
    SnapLayout.Display(frame: CGRect(x: x, y: y, width: width, height: height),
                       visible: CGRect(x: x, y: y, width: width, height: height - 25))
}

extension SnapLayout.Display {
    /// The same display in halves or thirds
    func split(_ columns: Int) -> Self {
        var display = self
        display.columns = columns
        return display
    }
}

private let main = display(0, 0, 1440, 900)
private let right = display(1440, 0, 1920, 1080)
private let aLeft = CGRect(x: 0, y: 0, width: 720, height: 875)
private let aRight = CGRect(x: 720, y: 0, width: 720, height: 875)
private let bLeft = CGRect(x: 1440, y: 0, width: 960, height: 1055)
private let bRight = CGRect(x: 2400, y: 0, width: 960, height: 1055)

private func halves(_ window: CGRect, _ displays: [SnapLayout.Display], _ direction: SnapLayout.Direction,
                    lastTarget: CGRect? = nil) -> CGRect? {
    SnapLayout.target(for: window, on: displays.map { $0.split(2) }, direction: direction, lastTarget: lastTarget)
}

private func thirds(_ window: CGRect, _ displays: [SnapLayout.Display], _ direction: SnapLayout.Direction,
                    lastTarget: CGRect? = nil) -> CGRect? {
    SnapLayout.target(for: window, on: displays.map { $0.split(3) }, direction: direction, lastTarget: lastTarget)
}

struct SnapLayoutTests {
    @Test func columnsSplitTheVisibleArea() {
        #expect(SnapLayout.columns(of: main.visible, count: 2) == [aLeft, aRight])
        #expect(SnapLayout.columns(of: main.visible, count: 3).map(\.width) == [480, 480, 480])
        let odd = SnapLayout.columns(of: CGRect(x: 100, y: 70, width: 1000, height: 600), count: 3)
        #expect(odd.map(\.minX) == [100, 433, 766])
        #expect(odd.map(\.width) == [333, 333, 334])
        #expect(odd.allSatisfy { $0.minY == 70 && $0.height == 600 })  // above the Dock, below the menu bar
    }

    @Test func firstPressSnapsIntoTheColumnItsMostlyIn() {
        let mostlyLeft = CGRect(x: 100, y: 100, width: 500, height: 400)
        #expect(halves(mostlyLeft, [main], .right) == aLeft)
        let mostlyRight = CGRect(x: 900, y: 100, width: 400, height: 400)
        #expect(halves(mostlyRight, [main], .left) == aRight)
    }

    @Test func anExactTieGoesThePressedWay() {
        let centered = CGRect(x: 520, y: 100, width: 400, height: 400)
        #expect(halves(centered, [main], .right) == aRight)
        #expect(halves(centered, [main], .left) == aLeft)
    }

    @Test func snappedWindowsStepAndStopAtTheEdge() {
        #expect(halves(aLeft, [main], .right) == aRight)
        #expect(halves(aRight, [main], .left) == aLeft)
        #expect(halves(aRight, [main], .right) == nil)
        #expect(halves(aLeft, [main], .left) == nil)
    }

    @Test func throwsAcrossDisplays() {
        #expect(halves(aRight, [main, right], .right) == bLeft)
        #expect(halves(bLeft, [main, right], .right) == bRight)
        #expect(halves(bRight, [main, right], .right) == nil)
        #expect(halves(bLeft, [main, right], .left) == aRight)
    }

    @Test func thirdsWalkThroughEveryColumn() {
        let displays = [main, right]
        var window = CGRect(x: 500, y: 200, width: 400, height: 400)  // mostly in the middle of the main display
        var walk: [CGRect] = []
        while let next = thirds(window, displays, .right) {
            walk.append(next)
            window = next
        }
        #expect(walk.map(\.minX) == [480, 960, 1440, 2080, 2720])
        var back: [CGRect] = []
        while let next = thirds(window, displays, .left) {
            back.append(next)
            window = next
        }
        #expect(back.map(\.minX) == [2080, 1440, 960, 480, 0])
    }

    @Test func terminalSizedWindowCountsAsSnapped() {
        // A few points short in each direction, keeping its top left corner
        let rounded = CGRect(x: 720, y: 15, width: 713, height: 860)
        #expect(halves(rounded, [main, right], .right) == bLeft)
    }

    @Test func remembersAWindowThatStayedWiderThanItsColumn() {
        let middle = CGRect(x: 480, y: 0, width: 480, height: 875)
        let tooWide = SnapLayout.place(CGSize(width: 600, height: 875), in: middle, on: main.visible)
        #expect(thirds(tooWide, [main], .right, lastTarget: middle) == CGRect(x: 960, y: 0, width: 480, height: 875))
        #expect(thirds(tooWide, [main], .right) == middle)  // without the memory it would only snap in place
    }

    @Test func neighborsOfDifferentSizesOffsetVertically() {
        let leftOfMain = display(-1920, -200, 1920, 1080)
        #expect(halves(aLeft, [main, leftOfMain], .left) == CGRect(x: -960, y: -200, width: 960, height: 1055))
    }

    @Test func threeDisplaysInARow() {
        let displays = [display(-1440, 0, 1440, 900), main, display(1440, 0, 1440, 900)]
        #expect(halves(aRight, displays, .right) == CGRect(x: 1440, y: 0, width: 720, height: 875))
        #expect(halves(aLeft, displays, .left) == CGRect(x: -720, y: 0, width: 720, height: 875))
    }

    @Test func stackedDisplaysArentNeighbors() {
        let above = display(0, 900, 1440, 900)
        #expect(halves(aRight, [main, above], .right) == nil)
        #expect(SnapLayout.neighbor(of: 0, in: [main, above], toward: .right) == nil)
    }

    @Test func aStraddlingWindowGoesByItsLargerOverlap() {
        let straddling = CGRect(x: 1300, y: 100, width: 400, height: 400)  // 140 on the main display, 260 on the other
        #expect(halves(straddling, [main, right], .right) == bLeft)
    }

    @Test func switchingToThirdsSnapsIntoAThird() {
        let rightThird = CGRect(x: 960, y: 0, width: 480, height: 875)
        #expect(thirds(aRight, [main], .left) == rightThird)
        #expect(thirds(aRight, [main], .right) == rightThird)
    }

    @Test func noDisplaysNoTarget() {
        #expect(halves(aLeft, [], .right) == nil)
    }

    @Test func upFillsTheDisplayWithHalves() {
        let full = main.visible
        #expect(SnapLayout.expanded(aLeft, on: [main]) == full)
        #expect(SnapLayout.expanded(aRight, on: [main]) == full)
        #expect(SnapLayout.expanded(CGRect(x: 100, y: 100, width: 500, height: 400), on: [main]) == full)
        #expect(SnapLayout.expanded(full, on: [main]) == nil)
    }

    @Test func upGoesThroughTwoThirdsWithThirds() {
        let full = main.visible
        let leftTwo = CGRect(x: 0, y: 0, width: 960, height: 875)
        let centerTwo = CGRect(x: 240, y: 0, width: 960, height: 875)
        let rightTwo = CGRect(x: 480, y: 0, width: 960, height: 875)
        #expect(SnapLayout.expanded(CGRect(x: 0, y: 0, width: 480, height: 875), on: [main.split(3)]) == leftTwo)
        #expect(SnapLayout.expanded(CGRect(x: 480, y: 0, width: 480, height: 875), on: [main.split(3)]) == centerTwo)
        #expect(SnapLayout.expanded(CGRect(x: 960, y: 0, width: 480, height: 875), on: [main.split(3)]) == rightTwo)
        for twoThirds in [leftTwo, centerTwo, rightTwo] {
            #expect(SnapLayout.expanded(twoThirds, on: [main.split(3)]) == full)
        }
        #expect(SnapLayout.expanded(full, on: [main.split(3)]) == nil)
    }

    @Test func upPicksTheTwoThirdsCoveringMostOfTheWindow() {
        // Straddling the left and middle thirds evenly: both the left and the centered two thirds cover it, and the
        // left ones are centered nearer
        let straddling = CGRect(x: 380, y: 100, width: 200, height: 300)
        #expect(SnapLayout.expanded(straddling, on: [main.split(3)]) == CGRect(x: 0, y: 0, width: 960, height: 875))
    }

    @Test func upRemembersAWindowThatStayedNarrower() {
        let leftTwo = CGRect(x: 0, y: 0, width: 960, height: 875)
        let narrower = CGRect(x: 0, y: 0, width: 900, height: 875)
        #expect(SnapLayout.expanded(narrower, on: [main.split(3)], lastTarget: leftTwo) == main.visible)
        #expect(SnapLayout.expanded(narrower, on: [main.split(3)]) == leftTwo)  // without the memory, it stays
    }

    @Test func upWorksOnEveryDisplay() {
        let bMiddle = CGRect(x: 2080, y: 0, width: 640, height: 1055)
        #expect(SnapLayout.expanded(bMiddle, on: [main.split(3), right.split(3)])
                == CGRect(x: 1760, y: 0, width: 1280, height: 1055))
        #expect(SnapLayout.expanded(bLeft, on: [main, right]) == right.visible)
    }

    @Test func twoThirdsOfAnOddWidth() {
        let thirds = SnapLayout.twoThirds(of: CGRect(x: 100, y: 70, width: 1000, height: 600))
        #expect(thirds.map(\.minX) == [100, 267, 433])
        #expect(thirds.map(\.maxX) == [766, 933, 1100])
    }

    @Test func sidewaysAfterUp() {
        // A full window counts as in every column, so the press decides
        #expect(halves(main.visible, [main], .right) == aRight)
        #expect(halves(main.visible, [main], .left) == aLeft)
        // From the left two thirds: into the middle third going right, the left third going left
        let leftTwo = CGRect(x: 0, y: 0, width: 960, height: 875)
        #expect(thirds(leftTwo, [main], .right) == CGRect(x: 480, y: 0, width: 480, height: 875))
        #expect(thirds(leftTwo, [main], .left) == CGRect(x: 0, y: 0, width: 480, height: 875))
    }

    // ⌃⌥↓. The main display's visible area is 875 points tall: a 437-point top row and a 438-point bottom one.

    private let topLeft = CGRect(x: 0, y: 438, width: 720, height: 437)
    private let topRight = CGRect(x: 720, y: 438, width: 720, height: 437)
    private let bottomRight = CGRect(x: 720, y: 0, width: 720, height: 438)
    private let bottomLeft = CGRect(x: 0, y: 0, width: 720, height: 438)

    @Test func cellsGoClockwiseFromTheTopLeft() {
        #expect(SnapLayout.cells(of: main.visible, columns: 2) == [topLeft, topRight, bottomRight, bottomLeft])
        let sixths = SnapLayout.cells(of: main.visible, columns: 3)
        #expect(sixths.map(\.minX) == [0, 480, 960, 960, 480, 0])
        #expect(sixths.map(\.minY) == [438, 438, 438, 0, 0, 0])
    }

    @Test func downCyclesQuarters() {
        // A left half is split evenly between two quarters, so it starts at the first in the cycle
        var window = aLeft
        var visited: [CGRect] = []
        for _ in 0..<5 {
            window = SnapLayout.cycled(window, on: [main])!
            visited.append(window)
        }
        #expect(visited == [topLeft, topRight, bottomRight, bottomLeft, topLeft])
    }

    @Test func downCyclesSixths() {
        var window = CGRect(x: 500, y: 50, width: 400, height: 300)  // inside the bottom middle sixth
        var visited: [CGFloat] = []
        for _ in 0..<7 {
            window = SnapLayout.cycled(window, on: [main.split(3)])!
            visited.append(window.minX + (window.minY > 0 ? 10_000 : 0))  // top row marked
        }
        // Bottom middle, bottom left, then the top row left to right, bottom right, back to bottom middle
        #expect(visited == [480, 0, 10_000, 10_480, 10_960, 960, 480])
    }

    @Test func downRecognizesNearlySnappedWindows() {
        let rounded = CGRect(x: 720, y: 445, width: 713, height: 430)  // Terminal-sized, top left corner kept
        #expect(SnapLayout.cycled(rounded, on: [main]) == bottomRight)
        let tooBig = CGRect(x: 0, y: 375, width: 800, height: 500)  // kept bigger than its quarter
        #expect(SnapLayout.cycled(tooBig, on: [main], lastTarget: topLeft) == topRight)
    }

    @Test func downStaysOnTheWindowsDisplay() {
        #expect(SnapLayout.cycled(bLeft, on: [main, right]) == CGRect(x: 1440, y: 528, width: 960, height: 527))
        #expect(SnapLayout.cycled(main.visible, on: [main, right]) == topLeft)  // evenly split: first
    }

    @Test func upFromACell() {
        #expect(SnapLayout.expanded(topRight, on: [main]) == main.visible)
        let topLeftSixth = CGRect(x: 0, y: 438, width: 480, height: 437)
        #expect(SnapLayout.expanded(topLeftSixth, on: [main.split(3)]) == CGRect(x: 0, y: 0, width: 960, height: 875))
    }

    @Test func nearlyEvenSplitsGoThePressedWay() {
        // Thirds of 1000 points are 333, 333 and 334, so the right two thirds overlap the last third a point more
        let small = display(0, 0, 1000, 625)
        let rightTwoThirds = CGRect(x: 333, y: 0, width: 667, height: 600)
        #expect(thirds(rightTwoThirds, [small], .left) == CGRect(x: 333, y: 0, width: 333, height: 600))
        #expect(thirds(rightTwoThirds, [small], .right) == CGRect(x: 666, y: 0, width: 334, height: 600))
    }

    @Test func eachDisplayKeepsItsOwnColumns() {
        // A MacBook's screen in halves, an external display in thirds (640 points each)
        let displays = [main, right.split(3)]
        let externalLeft = CGRect(x: 1440, y: 0, width: 640, height: 1055)
        #expect(SnapLayout.target(for: aRight, on: displays, direction: .right) == externalLeft)
        #expect(SnapLayout.target(for: externalLeft, on: displays, direction: .left) == aRight)
        #expect(SnapLayout.expanded(aLeft, on: displays) == main.visible)  // halves: straight to the whole display
        #expect(SnapLayout.expanded(CGRect(x: 2080, y: 0, width: 640, height: 1055), on: displays)
                == CGRect(x: 1760, y: 0, width: 1280, height: 1055))  // thirds: two thirds first
        #expect(SnapLayout.cycled(aLeft, on: displays) == topLeft)  // quarters
        #expect(SnapLayout.cycled(externalLeft, on: displays) == CGRect(x: 1440, y: 528, width: 640, height: 527))  // sixths
    }

    @Test func placesWindowsThatKeepTheirSize() {
        let area = main.visible
        #expect(SnapLayout.place(CGSize(width: 400, height: 300), in: aLeft, on: area)
                == CGRect(x: 160, y: 287.5, width: 400, height: 300))
        #expect(SnapLayout.place(CGSize(width: 900, height: 875), in: aLeft, on: area).minX == 0)
        #expect(SnapLayout.place(CGSize(width: 900, height: 875), in: aRight, on: area).maxX == 1440)
        #expect(SnapLayout.place(CGSize(width: 1600, height: 500), in: aRight, on: area).minX == 0)
        #expect(SnapLayout.place(CGSize(width: 500, height: 1000), in: aLeft, on: area).maxY == 875)  // title bar visible
    }

    @Test func flipsToAccessibilityCoordinates() {
        #expect(SnapLayout.flipped(aLeft, mainHeight: 900) == CGRect(x: 0, y: 25, width: 720, height: 875))
        let offset = CGRect(x: -1920, y: -200, width: 960, height: 1055)
        #expect(SnapLayout.flipped(offset, mainHeight: 900) == CGRect(x: -1920, y: 45, width: 960, height: 1055))
        #expect(SnapLayout.flipped(SnapLayout.flipped(offset, mainHeight: 900), mainHeight: 900) == offset)
    }
}

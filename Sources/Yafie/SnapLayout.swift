import CoreGraphics

/// Where window snapping puts a window. Pure geometry in AppKit coordinates: origin at the bottom left of the main
/// display, y up.
enum SnapLayout {
    enum Direction: Sendable { case left, right }

    struct Display: Equatable, Sendable {
        var frame: CGRect
        /// Without the menu bar and Dock
        var visible: CGRect
        /// 2 for halves, 3 for thirds
        var columns = 2
    }

    /// Where one press sends the window, or nil to leave it
    /// - Parameter lastTarget: the column Yafie last snapped this window to, if it hasn't moved since
    static func target(for window: CGRect, on displays: [Display], direction: Direction, lastTarget: CGRect? = nil) -> CGRect? {
        guard let here = display(for: window, in: displays) else { return nil }
        let columns = self.columns(of: displays[here])
        let current = lastTarget.flatMap { last in columns.firstIndex { $0.isClose(to: last, tolerance: 2) } }
            ?? columns.firstIndex { window.fills($0) }
        guard let current else { return mostlyIn(window, columns, toward: direction) }
        let next = direction == .right ? current + 1 : current - 1
        if columns.indices.contains(next) { return columns[next] }
        guard let there = neighbor(of: here, in: displays, toward: direction) else { return nil }
        let theirs = self.columns(of: displays[there])
        return direction == .right ? theirs.first : theirs.last
    }

    /// Where ⌃⌥↑ sends the window: the whole display, or on a display in thirds, two thirds first. Nil once it fills the
    /// display.
    /// - Parameter lastTarget: where Yafie last put this window, if it hasn't moved since
    static func expanded(_ window: CGRect, on displays: [Display], lastTarget: CGRect? = nil) -> CGRect? {
        guard let here = display(for: window, in: displays) else { return nil }
        let area = displays[here].visible
        func isAt(_ frame: CGRect) -> Bool { lastTarget?.isClose(to: frame, tolerance: 2) == true || window.fills(frame) }
        if isAt(area) { return nil }
        guard displays[here].columns == 3 else { return area }
        let candidates = twoThirds(of: area)
        if candidates.contains(where: isAt) { return area }
        // The two thirds covering most of the window; on a tie, the ones centered nearest it
        return candidates.max { a, b in
            let (overlapA, overlapB) = (window.overlapArea(with: a), window.overlapArea(with: b))
            return overlapA != overlapB ? overlapA < overlapB : abs(a.midX - window.midX) > abs(b.midX - window.midX)
        }
    }

    /// Where ⌃⌥↓ sends the window: around the display's quarters in halves, or its sixths in thirds, clockwise from the
    /// top left. The first press snaps it into the one it's mostly in.
    /// - Parameter lastTarget: where Yafie last put this window, if it hasn't moved since
    static func cycled(_ window: CGRect, on displays: [Display], lastTarget: CGRect? = nil) -> CGRect? {
        guard let here = display(for: window, in: displays) else { return nil }
        let cells = self.cells(of: displays[here].visible, columns: displays[here].columns)
        let current = lastTarget.flatMap { last in cells.firstIndex { $0.isClose(to: last, tolerance: 2) } }
            ?? cells.firstIndex { window.fills($0) }
        guard let current else {
            // Evenly split, it goes to the first in the cycle
            let most = cells.map { window.overlapArea(with: $0) }.max() ?? 0
            return cells.first { window.overlapArea(with: $0) >= most * 0.99 }
        }
        return cells[(current + 1) % cells.count]
    }

    /// The display's columns split into a top and a bottom row, clockwise from the top left
    static func cells(of area: CGRect, columns count: Int) -> [CGRect] {
        let topHeight = (area.height / 2).rounded(.down)
        let columns = self.columns(of: area, count: count)
        let top = columns.map { CGRect(x: $0.minX, y: area.maxY - topHeight, width: $0.width, height: topHeight) }
        let bottom = columns.map { CGRect(x: $0.minX, y: area.minY, width: $0.width, height: area.height - topHeight) }
        return top + bottom.reversed()
    }

    /// The left two thirds, two thirds centered on the display, and the right two thirds
    static func twoThirds(of area: CGRect) -> [CGRect] {
        let columns = self.columns(of: area, count: 3)
        let width = (area.width * 2 / 3).rounded(.down)
        let centered = CGRect(x: area.minX + ((area.width - width) / 2).rounded(.down), y: area.minY,
                              width: width, height: area.height)
        return [columns[0].union(columns[1]), centered, columns[1].union(columns[2])]
    }

    static func columns(of display: Display) -> [CGRect] { columns(of: display.visible, count: display.columns) }

    /// Equal columns across the area, in whole points, the last taking what's left
    static func columns(of area: CGRect, count: Int) -> [CGRect] {
        let width = (area.width / CGFloat(count)).rounded(.down)
        return (0..<count).map { index in
            let left = area.minX + width * CGFloat(index)
            let right = index == count - 1 ? area.maxX : left + width
            return CGRect(x: left, y: area.minY, width: right - left, height: area.height)
        }
    }

    /// For a window that can't take the column's size: centered on it, then kept on the display
    static func place(_ size: CGSize, in column: CGRect, on area: CGRect) -> CGRect {
        var x = min(max(column.midX - size.width / 2, area.minX), area.maxX - size.width)
        if size.width > area.width { x = area.minX }
        var y = min(max(column.midY - size.height / 2, area.minY), area.maxY - size.height)
        if size.height > area.height { y = area.maxY - size.height }  // title bar stays on screen
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Between AppKit's frames and Accessibility's, whose origin is the top left of the main display with y down.
    /// The same flip works both ways.
    static func flipped(_ rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display the window overlaps most, or else the nearest
    static func display(for window: CGRect, in displays: [Display]) -> Int? {
        func overlap(_ index: Int) -> CGFloat { window.overlapArea(with: displays[index].frame) }
        func distance(_ index: Int) -> CGFloat {
            hypot(window.midX - displays[index].frame.midX, window.midY - displays[index].frame.midY)
        }
        return displays.indices.max { a, b in
            overlap(a) != overlap(b) ? overlap(a) < overlap(b) : distance(a) > distance(b)
        }
    }

    /// The display that starts at or past this one's edge in that direction: the smallest gap, then the most
    /// vertical overlap. Displays stacked above each other aren't neighbors.
    static func neighbor(of index: Int, in displays: [Display], toward direction: Direction) -> Int? {
        let here = displays[index].frame
        let candidates = displays.indices.compactMap { other -> (index: Int, gap: CGFloat, overlap: CGFloat)? in
            guard other != index else { return nil }
            let there = displays[other].frame
            let gap = direction == .right ? there.minX - here.maxX : here.minX - there.maxX
            guard gap >= -1 else { return nil }
            return (other, gap, max(0, min(here.maxY, there.maxY) - max(here.minY, there.minY)))
        }
        return candidates.min { $0.gap != $1.gap ? $0.gap < $1.gap : $0.overlap > $1.overlap }?.index
    }

    /// A window that isn't snapped yet goes to the column it's mostly in. Evenly split, the press decides. Within 1%
    /// counts as even, since a column can be a point wider than the rest.
    private static func mostlyIn(_ window: CGRect, _ columns: [CGRect], toward direction: Direction) -> CGRect {
        let ordered = direction == .right ? columns : columns.reversed()
        let most = ordered.map { window.overlapArea(with: $0) }.max() ?? 0
        return ordered.last { window.overlapArea(with: $0) >= most * 0.99 } ?? ordered[0]
    }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(maxX - other.maxX) <= tolerance
            && abs(minY - other.minY) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }

    /// Within a few points or 2% of the column, which covers apps like Terminal that round sizes to whole characters
    func fills(_ column: CGRect) -> Bool {
        let dx = Swift.max(4, column.width * 0.02), dy = Swift.max(4, column.height * 0.02)
        return abs(minX - column.minX) <= dx && abs(maxX - column.maxX) <= dx
            && abs(minY - column.minY) <= dy && abs(maxY - column.maxY) <= dy
    }

    func overlapArea(with other: CGRect) -> CGFloat {
        let shared = intersection(other)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}

extension CGSize {
    /// The 2% rule, for a window that took nearly the size asked for
    func isClose(to other: CGSize) -> Bool {
        abs(width - other.width) <= Swift.max(4, other.width * 0.02)
            && abs(height - other.height) <= Swift.max(4, other.height * 0.02)
    }
}

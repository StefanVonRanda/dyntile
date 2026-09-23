import Foundation
import CoreGraphics

enum LayoutKind: String, CaseIterable {
    case tall       // main column on the left, stack on the right
    case wide       // main row across the top, stack underneath
    case columns    // equal vertical columns
    case rows       // equal horizontal rows
    case grid       // near-square grid
    case monocle    // every window fills the work area
    case bsp        // binary space partition, splits at the focused window
    case float      // nothing is tiled on this space

    static var allNames: String { allCases.map(\.rawValue).joined(separator: "|") }
    var tiles: Bool { self != .float }
}

/// Mutable per-space knobs a layout reads.
struct LayoutParams {
    var mainRatio: CGFloat
    var mainCount: Int
    var innerGap: CGFloat
    var outerGap: CGFloat
    /// Tile sizes for `columns`, `rows` and `grid`; equal until the user drags an edge.
    var weights = SplitWeights()
}

/// Relative tile sizes for the layouts that split into equal parts by default.
///
/// All three are the same shape underneath: a row of columns, each holding a stack of
/// tiles — `columns` is n columns of one, `rows` is one column of n, `grid` is in between.
/// `columns[c]` is column c's share of the width, `rows[c][r]` tile r's share of column c.
/// Weights are indexed by slot, not by window, so a swap exchanges windows and leaves the
/// tile sizes where they were, as it does in `tall`.
struct SplitWeights: Equatable {
    var columns: [CGFloat] = []
    var rows: [[CGFloat]] = []

    /// These weights reshaped for `shape` (tiles per column). Slots that already had a
    /// size keep it; new ones get the average, so an opened window takes a fair share
    /// rather than resetting what the user sized by hand.
    func fitted(to shape: [Int]) -> SplitWeights {
        func fit(_ weights: [CGFloat], _ n: Int) -> [CGFloat] {
            let kept = weights.prefix(n).map { $0 > 0 ? $0 : 1 }
            let fill = kept.isEmpty ? 1 : kept.reduce(0, +) / CGFloat(kept.count)
            return kept + Array(repeating: fill, count: n - kept.count)
        }
        return SplitWeights(
            columns: fit(columns, shape.count),
            rows: shape.indices.map { fit($0 < rows.count ? rows[$0] : [], shape[$0]) })
    }
}

enum Layout {
    /// Frames for `count` windows, in the same order as the window list.
    /// `bsp` is handled by `BSPTree`, not here.
    static func frames(kind: LayoutKind, count: Int, area: CGRect, params: LayoutParams) -> [CGRect] {
        guard count > 0 else { return [] }
        let rect = area.insetBy(dx: params.outerGap, dy: params.outerGap)
        guard rect.width > 1, rect.height > 1 else { return Array(repeating: area, count: count) }
        let gap = params.innerGap

        switch kind {
        case .monocle, .float:
            return Array(repeating: rect, count: count)

        case .columns, .rows, .grid:
            let shape = gridShape(kind: kind, count: count)
            let weights = params.weights.fitted(to: shape)
            let columnRects = split(rect, weights: weights.columns, gap: gap, vertical: true)
            return shape.indices.flatMap { c in
                split(columnRects[c], weights: weights.rows[c], gap: gap, vertical: false)
            }

        case .tall, .wide:
            let vertical = kind == .tall
            let mainCount = max(1, min(params.mainCount, count))
            if mainCount >= count {
                return split(rect, into: count, gap: gap, vertical: !vertical)
            }
            let ratio = min(max(params.mainRatio, 0.1), 0.9)
            let (mainArea, stackArea) = cut(rect, ratio: ratio, gap: gap, vertical: vertical)
            let main = split(mainArea, into: mainCount, gap: gap, vertical: !vertical)
            let stack = split(stackArea, into: count - mainCount, gap: gap, vertical: !vertical)
            return main + stack

        case .bsp:
            return Array(repeating: rect, count: count)
        }
    }

    /// Tiles per column for the split layouts, in window order.
    static func gridShape(kind: LayoutKind, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        switch kind {
        case .columns:
            return Array(repeating: 1, count: count)
        case .rows:
            return [count]
        default:
            // Near-square; the remainder goes to the leading columns so none is empty.
            let cols = Int(ceil(sqrt(Double(count))))
            let base = count / cols, extra = count % cols
            return (0..<cols).map { base + ($0 < extra ? 1 : 0) }
        }
    }

    /// Fold a hand-resized tile of `columns`, `rows` or `grid` back into its weights.
    ///
    /// Each edge that moved becomes the boundary between this tile and its neighbour on
    /// that side, and only those two trade size, so the rest of the layout stays put. An
    /// edge on the border of the work area has no neighbour and is ignored. `work` is the
    /// area inside the outer gap.
    static func resizeTile(kind: LayoutKind, count: Int, index: Int, from old: CGRect,
                           to new: CGRect, work: CGRect, gap: CGFloat,
                           weights: SplitWeights) -> SplitWeights {
        let shape = gridShape(kind: kind, count: count)
        var out = weights.fitted(to: shape)
        guard let (c, r) = slot(of: index, in: shape) else { return out }
        let tolerance: CGFloat = 4

        if abs(new.maxX - old.maxX) > tolerance, c + 1 < shape.count {
            moveBoundary(&out.columns, after: c, to: new.maxX, in: work, gap: gap, vertical: true)
        }
        if abs(new.minX - old.minX) > tolerance, c > 0 {
            moveBoundary(&out.columns, after: c - 1, to: new.minX - gap, in: work, gap: gap,
                         vertical: true)
        }
        // A tile's column spans the full height of the work area, so the rows inside it
        // can be placed against `work` without first laying out the columns.
        if abs(new.maxY - old.maxY) > tolerance, r + 1 < shape[c] {
            moveBoundary(&out.rows[c], after: r, to: new.maxY, in: work, gap: gap, vertical: false)
        }
        if abs(new.minY - old.minY) > tolerance, r > 0 {
            moveBoundary(&out.rows[c], after: r - 1, to: new.minY - gap, in: work, gap: gap,
                         vertical: false)
        }
        return out
    }

    /// Grow (or shrink, for a negative `delta`) tile `index` by `delta` of the work area
    /// along each axis it can grow on, taking the space evenly from the others.
    static func growTile(kind: LayoutKind, count: Int, index: Int, by delta: CGFloat,
                         weights: SplitWeights) -> SplitWeights {
        let shape = gridShape(kind: kind, count: count)
        var out = weights.fitted(to: shape)
        guard let (c, r) = slot(of: index, in: shape) else { return out }

        func grow(_ weights: inout [CGFloat], at i: Int) {
            guard weights.count > 1 else { return }
            let total = weights.reduce(0, +)
            let share = min(max(weights[i] / total + delta, 0.05), 0.95)
            let others = total - weights[i]
            // Solve for the weight that holds `share` of the new total.
            weights[i] = share * others / (1 - share)
        }
        grow(&out.columns, at: c)
        grow(&out.rows[c], at: r)
        return out
    }

    /// Column and row of the `index`th window in a grid of `shape`.
    private static func slot(of index: Int, in shape: [Int]) -> (column: Int, row: Int)? {
        var remaining = index
        for (c, n) in shape.enumerated() {
            if remaining < n { return (c, remaining) }
            remaining -= n
        }
        return nil
    }

    /// Put the boundary after slot `i` of a weighted split of `rect` at `boundary` (the
    /// far edge of slot `i`), trading size between slots `i` and `i + 1` only. Like the
    /// main ratio, neither may drop below a tenth of what the two share.
    private static func moveBoundary(_ weights: inout [CGFloat], after i: Int, to boundary: CGFloat,
                                     in rect: CGRect, gap: CGFloat, vertical: Bool) {
        guard i >= 0, i + 1 < weights.count else { return }
        let n = weights.count
        let usable = (vertical ? rect.width : rect.height) - gap * CGFloat(n - 1)
        let total = weights.reduce(0, +)
        guard usable > 1, total > 0 else { return }
        let unit = usable / total
        let start = (vertical ? rect.minX : rect.minY)
            + unit * weights[..<i].reduce(0, +) + gap * CGFloat(i)
        let pair = weights[i] + weights[i + 1]
        let first = min(max((boundary - start) / unit, pair * 0.1), pair * 0.9)
        weights[i] = first
        weights[i + 1] = pair - first
    }

    /// The main ratio that puts the main/stack boundary at `boundary`.
    /// Used when the user resizes a tile by hand and the layout has to keep that size.
    static func ratio(forBoundary boundary: CGFloat, work: CGRect,
                      gap: CGFloat, vertical: Bool) -> CGFloat {
        let span = (vertical ? work.width : work.height) - gap
        guard span > 1 else { return 0.5 }
        let origin = vertical ? work.minX : work.minY
        return min(max((boundary - origin) / span, 0.1), 0.9)
    }

    /// Cut `rect` in two along `ratio`, leaving `gap` between the halves.
    static func cut(_ rect: CGRect, ratio: CGFloat, gap: CGFloat, vertical: Bool) -> (CGRect, CGRect) {
        if vertical {
            let usable = max(0, rect.width - gap)
            let first = (usable * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height),
                    CGRect(x: rect.minX + first + gap, y: rect.minY,
                           width: usable - first, height: rect.height))
        } else {
            let usable = max(0, rect.height - gap)
            let first = (usable * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first),
                    CGRect(x: rect.minX, y: rect.minY + first + gap,
                           width: rect.width, height: usable - first))
        }
    }

    /// `n` equal slices of `rect`, gapped. `vertical` slices into columns.
    static func split(_ rect: CGRect, into n: Int, gap: CGFloat, vertical: Bool) -> [CGRect] {
        split(rect, weights: Array(repeating: 1, count: n), gap: gap, vertical: vertical)
    }

    /// Slices of `rect` sized in proportion to `weights`, gapped.
    static func split(_ rect: CGRect, weights: [CGFloat], gap: CGFloat, vertical: Bool) -> [CGRect] {
        let n = weights.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [rect] }
        let total = vertical ? rect.width : rect.height
        let usable = max(0, total - gap * CGFloat(n - 1))
        let sum = weights.reduce(0, +)
        let unit = sum > 0 ? usable / sum : 0
        var before: CGFloat = 0
        return weights.enumerated().map { i, weight in
            let offset = unit * before + gap * CGFloat(i)
            before += weight
            // Round outward so adjacent tiles never leave a 1px seam.
            let start = offset.rounded()
            let end = (offset + unit * weight).rounded()
            return vertical
                ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
        }
    }
}

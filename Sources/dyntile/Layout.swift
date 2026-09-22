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

        case .columns:
            return split(rect, into: count, gap: gap, vertical: true)

        case .rows:
            return split(rect, into: count, gap: gap, vertical: false)

        case .grid:
            let cols = Int(ceil(sqrt(Double(count))))
            let base = count / cols, extra = count % cols
            let columnRects = split(rect, into: cols, gap: gap, vertical: true)
            var out: [CGRect] = []
            for c in 0..<cols {
                // Spread the remainder over the leading columns so no column is empty.
                let inThis = base + (c < extra ? 1 : 0)
                guard inThis > 0 else { continue }
                out.append(contentsOf: split(columnRects[c], into: inThis, gap: gap, vertical: false))
            }
            return out

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
        guard n > 0 else { return [] }
        guard n > 1 else { return [rect] }
        let total = vertical ? rect.width : rect.height
        let usable = max(0, total - gap * CGFloat(n - 1))
        let each = usable / CGFloat(n)
        return (0..<n).map { i in
            let offset = (each + gap) * CGFloat(i)
            // Round outward so adjacent tiles never leave a 1px seam.
            let start = offset.rounded()
            let end = (offset + each).rounded()
            return vertical
                ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
        }
    }
}

import AppKit

/// The menu bar item's glyph: the same main-plus-stack motif as the app icon, drawn as a
/// template image so macOS tints it for light, dark and the accented menu bar.
enum StatusIcon {
    static func image(paused: Bool) -> NSImage {
        let size = NSSize(width: 17, height: 13)
        let image = NSImage(size: size, flipped: false) { bounds in
            let rect = bounds.insetBy(dx: 1, dy: 0.5)
            let gap: CGFloat = 1.5
            let mainWidth = ((rect.width - gap) * 0.55).rounded()
            let stackX = rect.minX + mainWidth + gap
            let stackWidth = rect.maxX - stackX
            let stackHeight = ((rect.height - gap) / 2).rounded()

            let tiles: [(NSRect, Bool)] = [
                (NSRect(x: rect.minX, y: rect.minY, width: mainWidth, height: rect.height), !paused),
                (NSRect(x: stackX, y: rect.maxY - stackHeight,
                        width: stackWidth, height: stackHeight), false),
                (NSRect(x: stackX, y: rect.minY, width: stackWidth, height: stackHeight), false),
            ]
            // Dimmed all-outline when paused, so the state is readable at a glance.
            NSColor.black.withAlphaComponent(paused ? 0.45 : 1).setFill()
            NSColor.black.withAlphaComponent(paused ? 0.45 : 1).setStroke()
            for (tile, filled) in tiles {
                let path = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: 1.5, yRadius: 1.5)
                if filled {
                    path.fill()
                } else {
                    path.lineWidth = 1
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

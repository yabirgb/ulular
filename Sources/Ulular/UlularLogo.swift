import AppKit

/// An 18-point pixel silhouette: a crescent above two curling gusts and a star.
/// Shared by the menu-bar renderer and the app-icon generator.
@MainActor
enum UlularLogo {
    static let pixels = [
        "..................",
        "...........MMMM...",
        "..........MMM.....",
        "..S.......MM......",
        ".SSS.....MMM......",
        "..S......MMM......",
        ".........MMM...M..",
        "..........MMMMMM..",
        "...........MMMM...",
        "..................",
        ".......WWW........",
        ".........WW.......",
        ".WWWWWWWWWW.......",
        "..................",
        "...WWWWWWWWWWWW...",
        "............WW....",
        "..........WWW.....",
        ".................."
    ]

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        // Explicit 1x and 2x bitmaps keep every pixel on the display's pixel grid.
        for scale in [1, 2] {
            image.addRepresentation(bitmap(size: 18 * scale, appIcon: false))
        }
        image.isTemplate = true
        image.accessibilityDescription = "ulular — Audio output and volume"
        return image
    }

    static func bitmap(size: Int, appIcon: Bool) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: appIcon ? size : 18, height: appIcon ? size : 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        let unit = CGFloat(size) / (appIcon ? 32 : 18)
        if appIcon {
            // Stepped corners, not a smoothed vector squircle.
            NSColor(srgbRed: 0.055, green: 0.09, blue: 0.20, alpha: 1).setFill()
            for rect in [NSRect(x: 4, y: 2, width: 24, height: 28),
                         NSRect(x: 2, y: 4, width: 28, height: 24)] {
                NSRect(x: rect.minX * unit, y: rect.minY * unit,
                       width: rect.width * unit, height: rect.height * unit).fill()
            }
        }
        for (y, row) in pixels.enumerated() {
            for (x, pixel) in row.enumerated() where pixel != "." {
                let color: NSColor
                if !appIcon {
                    color = .black
                } else if pixel == "W" {
                    color = NSColor(srgbRed: 0.48, green: 0.77, blue: 0.87, alpha: 1)
                } else {
                    color = NSColor(srgbRed: 1, green: 0.91, blue: 0.66, alpha: 1)
                }
                color.setFill()
                let inset = appIcon ? 7 : 0
                NSRect(x: CGFloat(x + inset) * unit,
                       y: CGFloat(17 - y + inset) * unit,
                       width: unit, height: unit).fill()
            }
        }
        return rep
    }
}

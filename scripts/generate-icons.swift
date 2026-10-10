import AppKit
import Foundation

/// Compile together with Sources/Ulular/UlularLogo.swift to keep all icons in sync.
@main
struct GenerateIcons {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let bitmap = UlularLogo.bitmap(size: points * scale, appIcon: true)
                let data = bitmap.representation(using: .png, properties: [:])!
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
    }
}

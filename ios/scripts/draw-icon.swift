import Foundation

// The canonical SVG also feeds documentation and promotion; no second drawing lives here.
let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = [iosRoot.deletingLastPathComponent(), iosRoot].map { $0.appendingPathComponent("branding/app-icon.svg") }
    .first { FileManager.default.fileExists(atPath: $0.path) }!
let output = CommandLine.arguments[1]
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["rsvg-convert", "-w", "1024", "-h", "1024", icon.path, "-o", output]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

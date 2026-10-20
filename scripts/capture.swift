// Captures one window to a PNG: capture.swift <pid> <window-id> <out.png> [--front]
// --front brings the app forward for the shot and gives focus back after: web views (MCP cards)
// don't draw while their window is hidden behind others. Used by scripts/screenshots.sh.
import AppKit

let args = CommandLine.arguments
let pid = Int32(args[1])!
let front = args.contains("--front")
let previous = NSWorkspace.shared.frontmostApplication
if front {
    NSRunningApplication(processIdentifier: pid)?.activate()
    Thread.sleep(forTimeInterval: 2.5)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l\(args[2])", args[3]]
try task.run()
task.waitUntilExit()
if front { previous?.activate() }

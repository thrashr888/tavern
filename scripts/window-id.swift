// Prints the window number of the first on-screen window owned by a process id, for
// `screencapture -l`. Used by scripts/screenshots.sh.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
    if let number = window[kCGWindowNumber as String] as? Int { print(number); exit(0) }
}
exit(1)

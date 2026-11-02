import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner == "ReelForge" else {
        continue
    }
    let number = window[kCGWindowNumber as String] ?? "?"
    let name = window[kCGWindowName as String] ?? ""
    let bounds = window[kCGWindowBounds as String] ?? [:]
    let layer = window[kCGWindowLayer as String] ?? "?"
    print("WINDOW id=\(number) layer=\(layer) name=\(name) bounds=\(bounds)")
}

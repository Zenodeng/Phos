import Foundation
import CoreGraphics
import ImageIO

// 按窗口截图工具 —— 供 V3 验收矩阵（三模式 × 两外观 × 三尺寸 = 18 组真实窗口截图）使用。
//
// 为什么不用 Xcode Previews：SwiftPM 可执行目标在 Xcode 26+ 下无法启用 Preview
// （需要 Xcode 专有的 ENABLE_DEBUG_DYLIB，Package.swift 里声明不了）。
// 真实窗口截图反而更可信：毛玻璃材质、标题栏、交通灯避让都能看到。
//
// 用法：
//   windowshot list [appName]                   列出窗口（appName 可选，做子串匹配）
//   windowshot shot <windowID> <outputPath>     用 screencapture 抓取指定窗口
//   windowshot find <appName>                   输出第一个匹配窗口的 ID（便于脚本取值）
//
// 依赖：屏幕录制权限（系统设置 → 隐私与安全性 → 屏幕录制）。

func windows() -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list
}

func describe(_ w: [String: Any]) -> String {
    let id = (w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
    let title = w[kCGWindowName as String] as? String ?? ""
    let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
    var size = "?"
    if let b = w[kCGWindowBounds as String] as? [String: Any],
       let width = b["Width"] as? Double, let height = b["Height"] as? Double {
        size = "\(Int(width))x\(Int(height))"
    }
    return "\(id)\t\(owner)\tpid=\(pid)\tlayer=\(layer)\t\(size)\t\(title)"
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    FileHandle.standardError.write(Data("usage: windowshot list [appName] | shot <id> <out> | find <appName>\n".utf8))
    exit(2)
}

let all = windows().filter { w in
    // layer 0 才是普通应用窗口；菜单栏 / Dock / 悬浮层都在其他 layer
    ((w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0
}

switch command {
case "list":
    let needle = args.count > 1 ? args[1].lowercased() : nil
    for w in all {
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        if let needle, !owner.contains(needle) { continue }
        print(describe(w))
    }

case "find":
    guard args.count > 1 else {
        FileHandle.standardError.write(Data("find needs an app name\n".utf8)); exit(2)
    }
    let needle = args[1].lowercased()
    let hits = all.filter {
        ((($0[kCGWindowOwnerName as String] as? String) ?? "").lowercased()).contains(needle)
    }
    guard let first = hits.first,
          let id = (first[kCGWindowNumber as String] as? NSNumber)?.intValue else {
        FileHandle.standardError.write(Data("no window found for \(args[1])\n".utf8)); exit(1)
    }
    print(id)

case "find-pid":
    guard args.count == 2, let pid = Int(args[1]), pid > 0,
          let hit = all.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid }),
          let id = hit[kCGWindowNumber as String] as? NSNumber else {
        FileHandle.standardError.write(Data("No visible window for the exact PID.\n".utf8)); exit(1)
    }
    print(id.intValue)

case "info":
    guard args.count == 2, let id = Int(args[1]), let hit = all.first(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == id
    }) else {
        FileHandle.standardError.write(Data("No matching visible window.\n".utf8)); exit(1)
    }
    let data = try JSONSerialization.data(withJSONObject: hit, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "shot":
    guard args.count > 2 else {
        FileHandle.standardError.write(Data("shot needs <windowID> <outputPath>\n".utf8)); exit(2)
    }
    guard args.count == 3, let number = Int(args[1]), number > 0,
          let hit = all.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number }) else {
        FileHandle.standardError.write(Data("Window ID must identify a visible normal window.\n".utf8)); exit(1)
    }
    let id = args[1]
    let out = args[2]
    let outputURL = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -l: 指定窗口；-x: 不播放快门声；-o: 去掉窗口阴影
    p.arguments = ["-l", id, "-x", "-o", out]
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        FileHandle.standardError.write(Data("screencapture failed (\(p.terminationStatus))\n".utf8))
        exit(1)
    }
    guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
        FileHandle.standardError.write(Data("Screenshot did not produce a readable image.\n".utf8)); exit(1)
    }
    let manifest: [String: Any] = [
        "capturedAt":ISO8601DateFormatter().string(from:Date()),
        "windowID":number,"processID":hit[kCGWindowOwnerPID as String] ?? -1,
        "ownerName":hit[kCGWindowOwnerName as String] ?? "",
        "windowTitle":hit[kCGWindowName as String] ?? "",
        "windowBoundsPt":hit[kCGWindowBounds as String] ?? [:],
        "screenshotPath":outputURL.path,
        "screenshotPixels":["width":width.intValue,"height":height.intValue],
        "backend":"screencapture window surface; no offscreen bitmap"
    ]
    try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
        .write(to:outputURL.appendingPathExtension("window.json"))
    print(out)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    exit(2)
}

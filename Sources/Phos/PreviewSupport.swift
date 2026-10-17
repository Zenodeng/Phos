import SwiftUI

// SwiftUI Previews 支持 —— 目前**无法在当前工程结构下生效**，保留备用。
//
// ⚠️ 已实测结论（2026-10-11，Xcode 27.0 / macOS 27.0.1）：
//   Canvas 打开后会直接报
//     "Cannot use previews in this file —
//      The executable target "Phos" needs the build setting ENABLE_DEBUG_DYLIB"
//   Apple 框架工程师在开发者论坛（thread/812649）明确说明：
//     · Xcode 26+ 起，可执行目标的 Preview 需要 `ENABLE_DEBUG_DYLIB = YES`；
//     · **SwiftPM 完全不继承 Xcode 的构建设置，manifest 里也无法声明任何 Xcode 构建设置**；
//     · 官方建议的解法是把视图/预览代码拆到**独立的 library target**，
//       可执行目标只保留 `@main` 入口 —— 那个 library 里 Preview 即可正常工作。
//
// 也就是说：这不是配置错误，是 SwiftPM 可执行目标的固有限制。想真正启用 Previews，
// 二选一（都需要改动构建链，见 Phos-V3-分期实施方案）：
//   A. 拆模块：新增 `Sources/PhosCore`（library）+ `Sources/Phos` 只留 @main。
//      代价：build.sh / CI 要改成两段编译（-emit-module + 链接），
//      且跨模块访问需要把大量声明提升为 `public`。
//   B. 建开发用 .xcodeproj（app target，用 Xcode 16+ 的同步文件夹引用 Sources/Phos）。
//      代价：出现第二条构建链，有与 build.sh 漂移的风险。
//
// 本文件里的 #Preview 块保留，是为了方案 A/B 落地时可直接使用，无需重写。
// 对正式构建零影响：build.sh 用 `swiftc -O` 且**不传** `-D DEBUG`，
// 整个文件被预处理掉（已验证：release 产物大小与加此文件前完全一致）。
// Xcode 的 Debug 配置自带 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`，
// 所以条件满足时这些预览会自动可见。

#if DEBUG

// MARK: - 主窗口

#Preview("StudioMainWindow · 浅色") {
    StudioMainWindow()
        .environmentObject(AppState())
        .frame(width: 1200, height: 800)
}

#Preview("StudioMainWindow · 深色") {
    StudioMainWindow()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
        .frame(width: 1200, height: 800)
}

// MARK: - 单个面板（改动检查器 / 素材区时最常用）

#Preview("素材区 StudioBrowser") {
    StudioBrowser()
        .environmentObject(AppState())
        .frame(width: 300, height: 700)
}

#Preview("检查器 InspectorPane · 明暗") {
    InspectorPane(initialCategory: .light)
        .environmentObject(AppState())
        .frame(width: 340, height: 800)
}

// MARK: - 设计令牌（改 Theme / StudioStyle 时用它一眼比对）

#Preview("设计令牌 StudioStyle") {
    VStack(alignment: .leading, spacing: 0) {
        ForEach([("panel", StudioStyle.panel),
                 ("surface", StudioStyle.surface),
                 ("canvas", StudioStyle.canvas),
                 ("accent", StudioStyle.accent)], id: \.0) { name, color in
            HStack {
                Text(name).font(.system(size: 12, design: .monospaced))
                    .frame(width: 70, alignment: .leading)
                Rectangle().fill(color).frame(height: 36)
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            .padding(.horizontal, 12)
        }
    }
    .frame(width: 360)
}

#endif

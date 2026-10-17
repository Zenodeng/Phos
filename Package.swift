// swift-tools-version: 6.2
// 注意：本文件只服务于 Xcode（打开包、SwiftUI Previews）。
// 正式构建与 CI 走 build.sh / Scripts/package_app.sh 的 swiftc 直编，不依赖 SwiftPM。
// .macOS(.v26) 需要 PackageDescription 6.2；与正式 App 的 macOS 26 最低版本一致。
import PackageDescription

let package = Package(
    name: "Phos",
    // V4 工作区以 macOS 26 原生界面为平台基线。
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Phos", targets: ["Phos"])
    ],
    targets: [
        .executableTarget(name: "Phos", path: "Sources/Phos",
                          swiftSettings: [.define("PHOS_NATIVE_GLASS")])
    ]
)

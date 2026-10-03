// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Phos",
    // 最低 macOS 15：人物分割等 Vision 能力需要 15+；不要下调到 14，否则 CI 会报 API 不可用
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Phos", targets: ["Phos"])
    ],
    targets: [
        .executableTarget(name: "Phos", path: "Sources/Phos")
    ]
)

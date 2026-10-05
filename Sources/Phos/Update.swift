import Foundation

/// 一次版本检查的结果，对应官网根目录的 `update.json`。
struct UpdateInfo: Decodable, Sendable {
    /// 线上最新版本号，例如 "3.2.0"
    let version: String
    /// 官网上的下载页，点击提示图标时打开它
    let page: String?
    /// 直接下载 zip 的地址（当前只展示，不做应用内替换）
    let url: String?
    let notes: String?
    let released: String?
}

/// 版本更新检查。
///
/// 这是 Phos **唯一的联网行为**：启动时向官网取一次 `update.json`，只为了比较版本号。
/// 请求里不带任何用户标识、不做统计、不发送本机信息。想关掉：
///
///     defaults write com.zeno.phos updateCheckDisabled -bool true
enum UpdateChecker {
    /// 官网的版本清单。按顺序尝试，第一个能取到的为准；换域名时改这里即可。
    static let manifests = [
        "https://zenophos.dpdns.org/update.json",
        "https://zenodeng.github.io/Phos/update.json"
    ]

    static let disabledKey = "updateCheckDisabled"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var isDisabled: Bool { UserDefaults.standard.bool(forKey: disabledKey) }

    /// 有更新时返回新版本信息；已是最新、被关掉、或网络不通都返回 nil（静默失败）。
    static func check() async -> UpdateInfo? {
        guard !isDisabled else { return nil }
        for address in manifests {
            // 加时间戳绕开 Cloudflare 的边缘缓存，否则刚发布的版本可能取到旧清单
            let stamped = "\(address)?t=\(Int(Date().timeIntervalSince1970))"
            guard let url = URL(string: stamped),
                  let info = try? await fetch(url) else { continue }
            // 清单取到了就以它为准：不比当前版本新，就没必要再试备用地址
            return compare(info.version, currentVersion) > 0 ? info : nil
        }
        return nil
    }

    private static func fetch(_ url: URL) async throws -> UpdateInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    /// 逐段按数字比较，保证 3.10.0 > 3.9.0 —— 直接比字符串会得出相反结论。
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

import Foundation
import Combine

/// UI-only preference; never stored in a photo sidecar or written to AppleLanguages.
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    static let defaultsKey = "phos.ui.language"
    static let didChange = Notification.Name("PhosInterfaceLanguageChanged")
    @Published private(set) var choice: String
    private var observer: NSObjectProtocol?
    init() {
        choice = Self.valid(UserDefaults.standard.string(forKey: Self.defaultsKey))
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let next = Self.valid(UserDefaults.standard.string(forKey: Self.defaultsKey))
            if self.choice != next { self.choice = next; NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }
    static func valid(_ value: String?) -> String { ["system","zh-Hans","en"].contains(value ?? "") ? value! : "system" }
    static func resolved(_ choice: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if choice != "system" { return choice == "en" ? "en" : "zh-Hans" }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    var code: String { Self.resolved(choice) }
    var locale: Locale { Locale(identifier: code) }
    func select(_ value: String) {
        let next = Self.valid(value)
        guard choice != next else { return }
        choice = next
        UserDefaults.standard.set(next, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

enum L10n {
    static var isEnglish: Bool { AppLanguage.resolved(AppLanguage.valid(UserDefaults.standard.string(forKey: AppLanguage.defaultsKey))) == "en" }
    /// Only call at presentation boundaries. File names, user names, prompts,
    /// enum raw values and persisted parameter/group identifiers stay untouched.
    static func tr(_ source: String) -> String { translate(source, english: isEnglish) }
    private struct Template {
        let source: String
        let regex: NSRegularExpression
        let output: String
        let slots: [String]
    }
    private static let templates: [Template] = LocalizationCatalog.english.filter { $0.key.contains("{0}") }.sorted { $0.key.count > $1.key.count }.compactMap { key,value in
        let expression = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        let ns = key as NSString
        let matches = expression.matches(in:key,range:NSRange(location:0,length:ns.length))
        var pattern = "^", last = 0, slots:[String] = []
        for match in matches {
            pattern += NSRegularExpression.escapedPattern(for:ns.substring(with:NSRange(location:last,length:match.range.location-last))) + "([\\s\\S]*?)"
            slots.append(ns.substring(with:match.range)); last = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for:ns.substring(from:last)) + "$"
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return nil }
        return Template(source:key,regex:regex,output:value,slots:slots)
    }
    static func translate(_ source: String, english: Bool) -> String {
        guard english else { return source }
        if let exact = LocalizationCatalog.english[source] { return exact }
        guard source.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else { return source }
        let ns = source as NSString
        for template in templates {
            if let match = template.regex.firstMatch(in:source,range:NSRange(location:0,length:ns.length)) {
                var output = template.output
                // Replace placeholders in one pass so literal braces in user text stay literal.
                let semanticFirst = template.source.hasPrefix("曲线 · ") || template.source.hasPrefix("颜色分级 · ") || template.source.hasPrefix("在画布上拖动绘制") || template.source.hasPrefix("已绘制") || template.source.hasPrefix("识别为") || template.source.hasPrefix("已按「")
                let slots = Dictionary(uniqueKeysWithValues: template.slots.enumerated().map { index,slot in
                    let raw = ns.substring(with:match.range(at:index+1))
                    let errorDetail = (template.source.hasPrefix("导出失败") && index == 0) || (template.source.contains("失败：") && index > 0) || (template.source.hasPrefix("无法读取") && index > 0)
                    return (slot, (semanticFirst && index == 0) || errorDetail ? (LocalizationCatalog.english[raw] ?? raw) : raw)
                })
                let expression = try! NSRegularExpression(pattern:#"\{\d+\}"#)
                for token in expression.matches(in:output,range:NSRange(output.startIndex...,in:output)).reversed() {
                    let key = (output as NSString).substring(with:token.range)
                    if let value = slots[key], let range = Range(token.range,in:output) { output.replaceSubrange(range,with:value) }
                }
                return output
            }
        }
        // Controlled UI composites (accessibility labels and section reset actions).
        for prefix in ["复位","启用蒙版："] where source.hasPrefix(prefix) {
            let rest = String(source.dropFirst(prefix.count))
            if let text = LocalizationCatalog.english[rest] { return (prefix == "复位" ? "Reset " : "Enable mask: ") + text }
        }
        for (suffix,translation) in [("数值"," value"),("滑杆"," slider"),("分组"," group")] where source.hasSuffix(suffix) {
            let rest = String(source.dropLast(suffix.count))
            if let text = LocalizationCatalog.english[rest] { return text + translation }
        }
        return source
    }
}

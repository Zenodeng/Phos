import AppKit

@MainActor
final class SystemAppIcon {
    private var observation: NSKeyValueObservation?
    private var distributedObservation: NSObjectProtocol?
    private let light: NSImage
    private let dark: NSImage
    private let hasNativeCatalog: Bool
    private var followSystemCatalog = false
    private var didOverrideIcon = false
    private(set) var currentVariant = "unresolved"

    init?(bundle: Bundle = .main) {
        guard let lightURL = bundle.url(forResource: "icon-light-1024", withExtension: "png"),
              let darkURL = bundle.url(forResource: "icon-dark-1024", withExtension: "png"),
              let light = NSImage(contentsOf: lightURL),
              let dark = NSImage(contentsOf: darkURL) else { return nil }
        self.light = light
        self.dark = dark
        self.hasNativeCatalog = bundle.url(forResource: "Assets", withExtension: "car") != nil
    }

    func start(application: NSApplication, followSystemCatalog: Bool = false) {
        self.followSystemCatalog = followSystemCatalog
        update(application)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            Task { @MainActor [weak self] in self?.update(app) }
        }
        if followSystemCatalog && distributedObservation == nil {
            distributedObservation = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self, weak application] _ in
                Task { @MainActor [weak self, weak application] in
                    if let self, let application { self.update(application) }
                }
            }
        }
    }

    private static func isSystemDarkMode() -> Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let theme = (global?["AppleIconAppearanceTheme"] as? String ?? "").lowercased()
        if theme.contains("dark") { return true }
        if theme.contains("light") || theme.contains("regularlight") { return false }
        let style = global?["AppleInterfaceStyle"] as? String
        return style?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func update(_ application: NSApplication) {
        if followSystemCatalog {
            let isSystemDark = Self.isSystemDarkMode()
            currentVariant = isSystemDark ? "dark" : "light"
            if hasNativeCatalog {
                // 交由 macOS 原生渲染 Assets.car（AppIcon.icon），使其随系统深浅与图标风格自动切换
                if didOverrideIcon {
                    application.applicationIconImage = nil
                    didOverrideIcon = false
                }
                application.dockTile.display()
            } else {
                application.applicationIconImage = isSystemDark ? dark : light
                didOverrideIcon = true
            }
        } else {
            let isDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            currentVariant = isDark ? "dark" : "light"
            application.applicationIconImage = isDark ? dark : light
            didOverrideIcon = true
        }
    }

    deinit {
        if let distributedObservation {
            DistributedNotificationCenter.default().removeObserver(distributedObservation)
        }
    }
}

/// One preference drives both windows and the running Dock icon, including manual overrides.
@MainActor
final class ApplicationAppearanceController {
    private var observation: NSObjectProtocol?
    func start(application: NSApplication) {
        apply(application)
        observation = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object:nil,queue:.main) { [weak self, weak application] _ in
                Task { @MainActor in if let application { self?.apply(application) } }
            }
    }
    private func apply(_ application: NSApplication) {
        let preference = UserDefaults.standard.string(forKey:"rf.appearance") ?? "system"
        application.appearance = preference == "dark" ? NSAppearance(named:.darkAqua)
            : preference == "light" ? NSAppearance(named:.aqua) : nil
    }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
}

@MainActor
final class PhosAppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceController: ApplicationAppearanceController?
    private(set) var systemIcon: SystemAppIcon?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the running Dock icon in sync independently of IconServices caching.
        appearanceController = ApplicationAppearanceController()
        appearanceController?.start(application:.shared)
        systemIcon = SystemAppIcon()
        systemIcon?.start(application: .shared, followSystemCatalog: true)
        #if PHOS_QA
        QAPlatformBaselineController.shared.start(delegate:self)
        #endif
    }
}

import AppKit

@MainActor
final class SystemAppIcon {
    private var observation: NSKeyValueObservation?
    private let light: NSImage
    private let dark: NSImage
    private(set) var currentVariant = "unresolved"

    init?(bundle: Bundle = .main) {
        guard let lightURL = bundle.url(forResource: "icon-light-1024", withExtension: "png"),
              let darkURL = bundle.url(forResource: "icon-dark-1024", withExtension: "png"),
              let light = NSImage(contentsOf: lightURL),
              let dark = NSImage(contentsOf: darkURL) else { return nil }
        self.light = light
        self.dark = dark
    }

    func start(application: NSApplication) {
        update(application)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            Task { @MainActor [weak self] in self?.update(app) }
        }
    }

    private func update(_ application: NSApplication) {
        let isDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        currentVariant = isDark ? "dark" : "light"
        application.applicationIconImage = isDark ? dark : light
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
        systemIcon?.start(application: .shared)
        #if PHOS_QA
        QAPlatformBaselineController.shared.start(delegate:self)
        #endif
    }
}

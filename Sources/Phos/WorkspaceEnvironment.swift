import AppKit
import Combine
import SwiftUI

private struct WorkspaceAccessibilityKey: EnvironmentKey {
    static let defaultValue = WorkspaceAccessibilityOptions()
}
private struct WorkspaceInputResetKey: EnvironmentKey {
    static let defaultValue: UInt = 0
}
extension EnvironmentValues {
    var workspaceAccessibility: WorkspaceAccessibilityOptions {
        get { self[WorkspaceAccessibilityKey.self] }
        set { self[WorkspaceAccessibilityKey.self] = newValue }
    }
    var workspaceInputResetGeneration: UInt {
        get { self[WorkspaceInputResetKey.self] }
        set { self[WorkspaceInputResetKey.self] = newValue }
    }
}

struct WorkspaceAccessibilityOptions: Equatable {
    var reduceTransparency = false
    var increaseContrast = false
    var reduceMotion = false

    @MainActor static var current: Self {
        let workspace = NSWorkspace.shared
        return Self(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                    increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                    reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
    }
}

/// A per-window observer; accessibility changes update the running workspace.
@MainActor
final class WorkspaceEnvironment: ObservableObject {
    @Published private(set) var accessibility = WorkspaceAccessibilityOptions.current
    @Published private(set) var disableNativeGlass = false
    let forcedAccessibility: String
    private let forceFallback: Bool
    #if PHOS_QA
    private var qaAccessibilityMode = "system"
    func setQAAccessibilityMode(_ mode:String) { qaAccessibilityMode = mode; refresh() }
    #endif
    private var observations: [AnyCancellable] = []

    init(forcedAccessibility: String = "system", forceFallback: Bool = false) {
        self.forcedAccessibility = forcedAccessibility
        self.forceFallback = forceFallback
        refresh()
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
    }

    func refresh() {
        var next = WorkspaceAccessibilityOptions.current
        if forcedAccessibility == "reduceTransparency" { next.reduceTransparency = true }
        if forcedAccessibility == "increaseContrast" { next.increaseContrast = true }
        if forcedAccessibility == "reduceMotion" { next.reduceMotion = true }
        #if PHOS_QA
        if qaAccessibilityMode == "reduceTransparency" { next.reduceTransparency = true }
        if qaAccessibilityMode == "increaseContrast" { next.increaseContrast = true }
        if qaAccessibilityMode == "reduceMotion" { next.reduceMotion = true }
        #endif
        if next != accessibility { accessibility = next }
        let disabled = forceFallback || UserDefaults.standard.bool(forKey: "phos.ui.disableNativeGlass")
        if disabled != disableNativeGlass { disableNativeGlass = disabled }
    }
}

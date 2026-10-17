import AppKit
import SwiftUI

@main
struct AppearanceTest {
    static func brightness(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        return Double((rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3)
    }

    @MainActor
    static func iconBitmap(_ icon: NSImage, appearance: NSAppearance) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }

    static func iconBrightness(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0.0
        for y in stride(from: 100, to: 412, by: 8) {
            for x in stride(from: 100, to: 412, by: 8) {
                let color = bitmap.colorAt(x: x, y: y)!
                guard color.alphaComponent > 0.9 else { continue }
                total += brightness(color)
                count += 1
            }
        }
        precondition(count > 100, "Icon is blank")
        return total / count
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String, output: URL) throws {
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(name + ".png"))
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: appearance-test <app-bundle> <output-directory> <catalog-json>")
        }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bundle = Bundle(url: appURL)!
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let originalAppearance = application.appearance
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["rf.appearance": "system"],
                                                forName: UserDefaults.argumentDomain)
        defer {
            application.appearance = originalAppearance
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        }

        let state = AppState()
        state.params.exposure = 0.5
        let host = NSHostingView(rootView: StudioMainWindow().environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        var panelValues: [Double] = []
        for (index, name) in [NSAppearance.Name.aqua, .darkAqua, .aqua].enumerated() {
            let appearance = NSAppearance(named: name)!
            application.appearance = appearance
            try await Task.sleep(nanoseconds: 350_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            panelValues.append(brightness(bitmap.colorAt(x: 4, y: 4)!))
            precondition(host.fittingSize.width <= 1101 && host.fittingSize.height <= 701)
            precondition(state.params.exposure == 0.5, "Appearance switch changed photo edits")
            try save(bitmap, name: "window-\(index)", output: output)
        }
        print("Window brightness: \(panelValues)")
        precondition(panelValues[0] > 0.7 && panelValues[1] < 0.3 && panelValues[2] > 0.7,
                     "The same window did not follow appearance changes")
        print("PASS: same window follows light -> dark -> light without changing photo edits")

        let catalogData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [[String: Any]]
        for (appearance, visible, hidden) in [
            ("NSAppearanceNameAqua", "AppIcon_Assets/light", "AppIcon_Assets/dark"),
            ("NSAppearanceNameDarkAqua", "AppIcon_Assets/dark", "AppIcon_Assets/light")
        ] {
            precondition(catalog.contains {
                $0["AssetType"] as? String == "IconImageStack"
                    && $0["Appearance"] as? String == appearance
                    && $0["Name"] as? String == "AppIcon"
            }, "Missing native app icon appearance: \(appearance)")
            let group = catalog.first {
                $0["AssetType"] as? String == "IconGroup"
                    && $0["Appearance"] as? String == appearance
            }!
            let layers = group["Layers"] as! [[String: Any]]
            precondition(layers.first { $0["Name"] as? String == visible }?["LayerOpacity"] as? Double == 1)
            precondition(layers.first { $0["Name"] as? String == hidden }?["LayerOpacity"] as? Double == 0)
        }
        print("PASS: compiled native icon contains correctly selected Aqua and DarkAqua images")

        application.appearance = NSAppearance(named: .aqua)
        let fallback = SystemAppIcon(bundle: bundle)!
        fallback.start(application: application)
        var fallbackValues: [Double] = []
        for (index, name) in [NSAppearance.Name.aqua, .darkAqua, .aqua].enumerated() {
            application.appearance = NSAppearance(named: name)
            try await Task.sleep(nanoseconds: 100_000_000)
            let bitmap = iconBitmap(application.applicationIconImage,
                                    appearance: application.effectiveAppearance)
            fallbackValues.append(iconBrightness(bitmap))
            try save(bitmap, name: "dock-icon-\(index)", output: output)
        }
        precondition(fallbackValues[0] - fallbackValues[1] > 0.15
                     && abs(fallbackValues[0] - fallbackValues[2]) < 0.02)
        print("Dock icon brightness: \(fallbackValues)")
        print("PASS: running Dock icon follows light -> dark -> light without restarting")
        window.contentView = nil
    }
}

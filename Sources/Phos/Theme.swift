import SwiftUI

// MARK: - 自适应调色板
extension NSColor {
    /// 按系统外观自动取色：浅色模式用 light，深色模式用 dark
    static func rfDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 参数分组卡片底色
    static let rfCard = rfDynamic(light: NSColor(white: 1.0, alpha: 1),
                                  dark: NSColor(white: 0.10, alpha: 1))
    /// 卡片发丝边框
    static let rfCardBorder = rfDynamic(light: NSColor(white: 0, alpha: 0.07),
                                        dark: NSColor(white: 1, alpha: 0.09))
    /// 数值胶囊 / 小标签底色
    static let rfPill = rfDynamic(light: NSColor(white: 0, alpha: 0.05),
                                  dark: NSColor(white: 1, alpha: 0.12))
    /// 工具条悬停底色
    static let rfHover = rfDynamic(light: NSColor(white: 0, alpha: 0.06),
                                   dark: NSColor(white: 1, alpha: 0.08))
    /// 编辑画布底色，避免画布和窗口背景融在一起
    static let rfCanvas = rfDynamic(light: NSColor(white: 0.18, alpha: 1),
                                   dark: NSColor(white: 0.055, alpha: 1))
    /// 分栏边界色
    static let rfDivider = rfDynamic(light: NSColor(white: 0, alpha: 0.12),
                                     dark: NSColor(white: 1, alpha: 0.12))
}

enum RF {
    static let corner: CGFloat = 8
    static let cornerSm: CGFloat = 5
}

// MARK: - 卡片修饰
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .rfCard))
            .overlay(
                RoundedRectangle(cornerRadius: RF.corner, style: .continuous)
                    .stroke(Color(nsColor: .rfCardBorder), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: RF.corner, style: .continuous))
    }
}

extension View {
    func rfCard() -> some View { modifier(CardBackground()) }
}

// MARK: - 顶栏图标按钮
struct ToolButton: View {
    let systemImage: String
    let title: String
    var active: Bool = false
    var disabled: Bool = false
    var shortcut: KeyEquivalent? = nil
    var modifiers: EventModifiers = .command
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4)
                                 : (active ? Color.accentColor : Color.primary))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16)
                                : (hover ? Color(nsColor: .rfHover) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
        .onHover { hover = $0 && !disabled }
        .modifier(ShortcutModifier(shortcut: shortcut, modifiers: modifiers))
    }
}

private struct ShortcutModifier: ViewModifier {
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            content
        }
    }
}

// MARK: - 顶栏分组分隔线
struct ToolDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .rfCardBorder))
            .frame(width: 1, height: 18)
    }
}

// MARK: - 胶囊开关（全像素）
struct PillToggle: View {
    let title: String
    @Binding var isOn: Bool
    var helpText: String = ""
    @State private var hover = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? Color.accentColor
                               : (hover ? Color(nsColor: .rfHover) : .clear))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .rfCardBorder), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hover = $0 }
    }
}

// MARK: - 胶囊按钮（1:1 这类有独立激活态的）
struct PillButton: View {
    let title: String
    let active: Bool
    var helpText: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(
                    Capsule(style: .continuous)
                        .fill(active ? Color.accentColor
                               : (hover ? Color(nsColor: .rfHover) : .clear))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .rfCardBorder), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hover = $0 }
    }
}

import SwiftUI

struct WorkspaceButtonStyle: ButtonStyle {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    var selected = false
    var previewPressed = false
    var prominent = false
    var chrome = true
    @Environment(\.controlActiveState) private var active
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceAccessibility) private var options
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? WorkspaceTokens.error : WorkspaceTokens.primaryText)
            .padding(chrome ? 6 : 0)
            .background {
                if chrome { Color.clear.modifier(WorkspaceGlassDecoration(selected: selected || prominent)) }
            }
            .scaleEffect(!enabled || reduceMotion || options.reduceMotion ? 1 : configuration.isPressed || previewPressed ? 0.96 : hover ? 1.035 : 1)
            .animation(reduceMotion || options.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: configuration.isPressed || previewPressed)
            .animation(reduceMotion || options.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: hover)
            .contentShape(RoundedRectangle(cornerRadius:8))
            .opacity(!enabled ? 0.38 : active == .inactive ? 0.80 : 1)
            .onHover { hover = $0 }
    }
}

struct WorkspaceIconButton: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    let symbol: String
    let title: String
    var selected = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false
    @FocusState private var keyboardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceAccessibility) private var accessibility
    var body: some View {
        Button(action:action) {
            Image(systemName:symbol).symbolRenderingMode(.hierarchical)
                .font(.system(size:14,weight:.medium))
                .frame(width:WorkspaceTokens.symbolBox,height:WorkspaceTokens.symbolBox)
        }
        .buttonStyle(WorkspaceButtonStyle(selected:selected))
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .background(RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(hover && !disabled ? 0.06 : 0)))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(keyboardFocused ? WorkspaceTokens.accent : .clear,lineWidth:2).padding(1).allowsHitTesting(false))
        .opacity(disabled ? 0.35 : 1).disabled(disabled)
        .onHover { hover = $0 }.help(L10n.tr(title)).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion || accessibility.reduceMotion ? nil : .easeOut(duration:0.14),value:hover)
    }
}

/// Draft text remains local; only a valid commit updates the image and history.
struct WorkspaceParameterRow: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var decimals = 0
    var onCommit: () -> Void
    @State private var draft = ""
    @State private var didCommit = false
    @State private var invalid = false
    @State private var editStartText = ""
    @State private var beganEditing = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceInputResetGeneration) private var resetGeneration
    private var formatted: String { String(format:"%.*f",decimals,value) }
    private var modified: Bool { abs(value) > 0.00001 }
    var body: some View {
        VStack(spacing:5) {
            HStack {
                Text(L10n.tr(label)).font(.system(size:WorkspaceTokens.TypeSize.parameter)).foregroundStyle(WorkspaceTokens.primaryText)
                    .fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:8)
                TextField(label,text:$draft)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size:WorkspaceTokens.TypeSize.metadata,design:.monospaced))
                    .foregroundStyle(invalid ? WorkspaceTokens.error : modified ? WorkspaceTokens.accent : WorkspaceTokens.secondaryText)
                    .padding(.horizontal,8)
                    .frame(width:WorkspaceTokens.readout.width,height:WorkspaceTokens.readout.height)
                    .background(RoundedRectangle(cornerRadius:WorkspaceTokens.controlRadius)
                        .fill(LinearGradient(colors:[WorkspaceTokens.readoutTop,WorkspaceTokens.readoutBottom],startPoint:.top,endPoint:.bottom)
                            .shadow(.inner(color:.white.opacity(colorScheme == .dark ? 0.03 : 0.65),radius:0.5,x:0,y:1)))
                        .shadow(color:.black.opacity(colorScheme == .dark ? 0.10 : 0.04),radius:0.5,x:0,y:1))
                    .overlay(RoundedRectangle(cornerRadius:WorkspaceTokens.controlRadius).stroke(invalid ? WorkspaceTokens.error : focused ? WorkspaceTokens.accent : WorkspaceTokens.hairline,lineWidth:focused ? 1.5 : 0.5).allowsHitTesting(false))
                    .focused($focused).onSubmit { commit(); if !invalid { focused = false } }
                    .onExitCommand { didCommit = true; invalid = false; draft = formatted; focused = false }
                    .onChange(of:focused) { _, active in
                        if active {
                            didCommit = false; invalid = false; beganEditing = true
                            draft = String(format:"%.2f",value)
                            editStartText = draft
                        }
                        else { commit(); draft = formatted; invalid = false }
                    }
                    .accessibilityLabel(label+"数值").help(L10n.tr("输入数值，Enter 确认，Esc 取消"))
            }
            ZStack {
                Slider(value:$value,in:range,onEditingChanged:{ editing in if !editing { onCommit() } })
                    .controlSize(.small).tint(WorkspaceTokens.accent).accessibilityLabel(label+"滑杆")
                if range.lowerBound < 0 && range.upperBound > 0 {
                    Rectangle().fill(Color.primary.opacity(0.20)).frame(width:1,height:5).allowsHitTesting(false)
                }
            }.frame(height:20)
        }
        .padding(.vertical,4)
        .onAppear { draft = formatted }
        .onChange(of:value) { _, _ in
            if focused {
                draft = String(format:"%.2f",value); editStartText = draft
                invalid = false
            } else { draft = formatted }
        }
        .onChange(of:resetGeneration) { _, _ in
            didCommit = true; invalid = false; beganEditing = false
            draft = formatted; focused = false
        }
        .onDisappear { if beganEditing { commit() } }
    }
    private func commit() {
        guard !didCommit else { return }
        if beganEditing && draft == editStartText { didCommit = true; return }
        guard let next = ParameterInputPolicy.value(draft,in:range) else { invalid = true; return }
        didCommit = true; invalid = false
        if next != value { value = next; onCommit() }
        draft = formatted
    }
}

struct WorkspaceAdjustmentGroup<Content:View>: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    let title: String
    var modified = false
    var initiallyExpanded = true
    var reset: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool
    @State private var localResetGeneration: UInt = 0
    @Environment(\.workspaceInputResetGeneration) private var parentResetGeneration
    init(title:String,modified:Bool = false,expanded:Bool = true,reset:@escaping () -> Void,@ViewBuilder content:@escaping () -> Content) {
        self.title = title; self.modified = modified; self.initiallyExpanded = expanded
        self.reset = reset; self.content = content; _expanded = State(initialValue:expanded)
    }
    var body: some View {
        VStack(spacing:8) {
            HStack(spacing:8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing:8) {
                        Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary).frame(width:12)
                        Text(L10n.tr(title)).font(.system(size:WorkspaceTokens.TypeSize.group,weight:.semibold)).foregroundStyle(WorkspaceTokens.primaryText)
                        if modified { Circle().fill(WorkspaceTokens.accent).frame(width:4,height:4).accessibilityLabel(L10n.tr("已修改")) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title.hasSuffix("分组") ? title : title+"分组")
                Button { localResetGeneration &+= 1; reset() } label: { Image(systemName:"arrow.counterclockwise").symbolRenderingMode(.hierarchical).font(.system(size:12)).frame(width:24,height:24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!modified).opacity(modified ? 1 : 0.4).help(L10n.tr("复位")+title)
            }.frame(minHeight:36)
            if expanded { content().environment(\.workspaceInputResetGeneration,(parentResetGeneration &* 131) &+ localResetGeneration) }
        }.padding(.vertical,8)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func colorLabelSwiftUI(_ l: ColorLabel) -> Color {
    switch l {
    case .none: return .clear
    case .red: return .red
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    }
}

/// 网格看片视图（G）：含快速筛选条、缩略图缩放滑杆、多选（Cmd/Shift）、色标与右键菜单。
struct GridCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var thumbSize: Double = 168
    @State private var anchorID: UUID?
    @State private var renamingVCID: UUID?
    @State private var renameVCText: String = ""
    @State private var showRenameVC = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(thumbSize), maximum: CGFloat(thumbSize + 64)), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(L10n.tr("网格看片"))
                        .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(L10n.tr("\(s.visiblePhotoIndices.count) 张"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary).lineLimit(1)

                    Divider().frame(height: 14)

                    Menu {
                        Button(L10n.tr("所有星级")) { s.filterRating = 0 }
                        ForEach(1...5, id: \.self) { r in
                            Button(L10n.tr("至少\(r)星")) { s.filterRating = r }
                        }
                    } label: {
                        Text(L10n.tr(s.filterRating == 0 ? "星级" : "≥ \(s.filterRating) ★"))
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.mini)

                    Button {
                        s.filterPicked.toggle()
                    } label: {
                        Label(L10n.tr("已标"), systemImage: s.filterPicked ? "flag.fill" : "flag")
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .buttonStyle(WorkspaceButtonStyle(selected: s.filterPicked))
                    .controlSize(.mini)

                    Button {
                        s.hideRejected.toggle()
                    } label: {
                        Label(L10n.tr("隐淘汰"), systemImage: "eye.slash")
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .buttonStyle(WorkspaceButtonStyle(selected: s.hideRejected))
                    .controlSize(.mini)

                    HStack(spacing: 4) {
                        ForEach([ColorLabel.red, .yellow, .green, .blue, .purple], id: \.self) { lbl in
                            let active = s.filterColorLabel == lbl
                            Button {
                                s.filterColorLabel = active ? nil : lbl
                            } label: {
                                Circle()
                                    .fill(colorLabelSwiftUI(lbl))
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(active ? Color.primary : Color.primary.opacity(0.25),
                                                             lineWidth: active ? 1.8 : 0.6))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr(lbl.label))
                        }
                    }

                    Menu {
                        if s.cullingRunning {
                            Button(L10n.tr("取消智能挑片")) { s.cancelSmartCulling() }
                        } else {
                            Button(L10n.tr("开始智能挑片分析")) { s.runSmartCulling() }
                        }
                        Button(L10n.tr("一键精选最佳照片")) { s.applyCullBestPicks() }
                            .disabled(s.cullMetrics.isEmpty)
                        Button(L10n.tr("一键淘汰闭眼/跑焦")) { s.rejectCullDefects() }
                            .disabled(s.cullMetrics.isEmpty)
                        Divider()
                        ForEach(CullingFilter.allCases, id: \.self) { cf in
                            Button {
                                s.cullingFilter = cf
                            } label: {
                                if s.cullingFilter == cf {
                                    Label(L10n.tr(cf.label), systemImage: "checkmark")
                                } else {
                                    Text(L10n.tr(cf.label))
                                }
                            }
                        }
                    } label: {
                        Label(L10n.tr(s.cullingRunning ? "挑片中…" : (s.cullingFilter == .all ? "智能挑片" : s.cullingFilter.label)),
                              systemImage: "sparkles.rectangle.stack")
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.mini)

                    if s.similarPhotoTargetID != nil {
                        Button(L10n.tr("清除相似排序")) { s.clearSimilarFilter() }
                            .controlSize(.mini).lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "photo.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $thumbSize, in: 130...250)
                        .frame(width: 82)
                        .controlSize(.mini)

                    Button(L10n.tr("双图对比")) {
                        s.compareSubMode = .sideBySide
                        s.canvasDisplayMode = .compare
                    }
                    .controlSize(.mini).lineLimit(1)
                    .disabled(s.items.isEmpty)

                    Button(L10n.tr("多图同屏")) {
                        s.compareSubMode = .survey
                        s.canvasDisplayMode = .compare
                    }
                    .controlSize(.mini).lineLimit(1)
                    .disabled(s.items.isEmpty)

                    Button(L10n.tr("返回单张")) { s.canvasDisplayMode = .single }
                        .controlSize(.mini).lineLimit(1)
                }
                .frame(minWidth: 600)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.bar)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(s.visiblePhotoIndices, id: \.self) { idx in
                        let item = s.items[idx]
                        let isCurrent = idx == s.currentIndex
                        let isMulti = s.selectedPhotos.contains(item.id)
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let cg = item.thumb {
                                        Image(decorative: cg, scale: 1)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Rectangle()
                                            .fill(.quaternary)
                                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                                    }
                                }
                                .frame(height: CGFloat(thumbSize * 0.74))
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .cornerRadius(6)
                                .opacity(item.rejected ? 0.42 : 1.0)

                                HStack(spacing: 4) {
                                    if item.colorLabel != .none {
                                        Circle()
                                            .fill(colorLabelSwiftUI(item.colorLabel))
                                            .frame(width: 9, height: 9)
                                            .overlay(Circle().stroke(.white, lineWidth: 1))
                                    }
                                    if item.picked {
                                        Image(systemName: "flag.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.green)
                                            .padding(3)
                                            .background(.black.opacity(0.55), in: Circle())
                                    } else if item.rejected {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                            .padding(2)
                                            .background(.black.opacity(0.55), in: Circle())
                                    }
                                }
                                .padding(6)

                                if isMulti {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(WorkspaceTokens.accent)
                                            .padding(6)
                                        Spacer()
                                    }
                                } else if let cm = s.cullMetrics[item.id] {
                                    VStack {
                                        HStack {
                                            if cm.eyesClosed {
                                                Text(L10n.tr("闭眼"))
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(.red.opacity(0.85), in: Capsule())
                                                    .foregroundStyle(.white)
                                            } else if cm.isBlurry {
                                                Text(L10n.tr("模糊"))
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(.orange.opacity(0.85), in: Capsule())
                                                    .foregroundStyle(.white)
                                            } else if cm.isBurstBest {
                                                Text(L10n.tr("最佳"))
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(.green.opacity(0.85), in: Capsule())
                                                    .foregroundStyle(.white)
                                            }
                                            Spacer()
                                        }
                                        Spacer()
                                    }
                                    .padding(6)
                                }
                            }

                            HStack(spacing: 4) {
                                Text(item.displayName)
                                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if item.isVirtualCopy {
                                    Text("VC")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(WorkspaceTokens.accent.opacity(0.2), in: Capsule())
                                }
                            }

                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Button {
                                        s.setRating(item.rating == star ? 0 : star, for: item.id)
                                    } label: {
                                        Image(systemName: star <= item.rating ? "star.fill" : "star")
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(star <= item.rating ? .yellow : .secondary.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                                Text(item.url.pathExtension.uppercased())
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isCurrent ? WorkspaceTokens.accent.opacity(0.14)
                                      : isMulti ? WorkspaceTokens.accent.opacity(0.08)
                                      : Color(nsColor: .controlBackgroundColor).opacity(0.45))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isCurrent ? WorkspaceTokens.accent
                                        : isMulti ? WorkspaceTokens.accent.opacity(0.6)
                                        : WorkspaceTokens.hairline,
                                        lineWidth: isCurrent ? 1.5 : (isMulti ? 1.1 : 0.6))
                        )
                        .onAppear {
                            s.requestThumbnails(Set([item.id]))
                        }
                        .onTapGesture(count: 2) {
                            s.select(idx)
                            s.canvasDisplayMode = .single
                        }
                        .onTapGesture(count: 1) {
                            handleTap(index: idx, item: item)
                        }
                        .contextMenu { cardMenu(index: idx, item: item) }
                    }
                }
                .padding(16)
            }
            .background(StudioStyle.canvas)
        }
        .alert(L10n.tr("重命名虚拟副本"), isPresented: $showRenameVC) {
            TextField(L10n.tr("副本名称"), text: $renameVCText)
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("保存")) {
                if let vcID = renamingVCID {
                    s.renameVirtualCopy(vcID, name: renameVCText)
                }
            }
            .disabled(renameVCText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func handleTap(index: Int, item: PhotoItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if s.selectedPhotos.contains(item.id) { s.selectedPhotos.remove(item.id) }
            else { s.selectedPhotos.insert(item.id) }
            anchorID = item.id
            return
        }
        let visible = s.visiblePhotoIndices
        if mods.contains(.shift), let end = visible.firstIndex(of: index) {
            let aid = anchorID ?? s.current?.id
            let start = visible.firstIndex { s.items[$0].id == aid } ?? end
            let range = min(start, end)...max(start, end)
            s.selectedPhotos = Set(range.map { s.items[visible[$0]].id })
        } else {
            s.selectedPhotos = []
            anchorID = item.id
        }
        s.select(index)
    }

    @ViewBuilder
    private func cardMenu(index: Int, item: PhotoItem) -> some View {
        Button(L10n.tr("单张编辑")) {
            s.select(index)
            s.canvasDisplayMode = .single
        }
        Button(L10n.tr("设为双图对比基准")) {
            s.comparePrimaryID = item.id
            s.compareSubMode = .sideBySide
            s.canvasDisplayMode = .compare
        }
        Button(L10n.tr("设为参考图")) {
            s.setReferencePhoto(item.url)
            s.canvasDisplayMode = .reference
        }
        Button(L10n.tr("找相似照片")) {
            s.findSimilarPhotos(to: item.id)
        }
        .disabled(item.isVirtualCopy)
        Divider()
        Button(L10n.tr(item.picked ? "取消标记" : "标记为精选")) {
            s.togglePick(for: item.id)
        }
        Button(L10n.tr(item.rejected ? "取消淘汰" : "淘汰照片")) {
            s.toggleReject(for: item.id)
        }
        Menu(L10n.tr("颜色标签")) {
            ForEach(ColorLabel.allCases, id: \.self) { lbl in
                Button(L10n.tr(lbl.label)) {
                    if lbl == .none {
                        s.setColorLabel(item.colorLabel, for: item.id)
                    } else {
                        if item.colorLabel != lbl { s.setColorLabel(lbl, for: item.id) }
                    }
                }
            }
        }
        Divider()
        Button(L10n.tr("创建虚拟副本")) {
            s.select(index)
            s.createVirtualCopy()
        }
        if item.isVirtualCopy {
            Button(L10n.tr("重命名虚拟副本…")) {
                renamingVCID = item.id
                renameVCText = item.virtualCopyName ?? "副本"
                showRenameVC = true
            }
            Button(L10n.tr("删除虚拟副本"), role: .destructive) {
                s.select(index)
                s.deleteVirtualCopy()
            }
        }
        Divider()
        Button(L10n.tr("导出 XMP 旁档")) {
            s.select(index)
            s.exportCurrentXMP()
        }
    }
}

/// 多图对比 / 同屏选片 / 修改前后视图（C / N）：支持双图锁定对比、2~4 张同屏选片（Survey）、捏合缩放与同步平移。
struct CompareCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var syncScale: CGFloat = 1.0
    @State private var gestureScaleBase: CGFloat?
    @State private var syncOffset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var syncPanZoom: Bool = true

    private var primaryCandidateItem: PhotoItem? {
        if let pid = s.comparePrimaryID, let hit = s.items.first(where: { $0.id == pid }) {
            return hit
        }
        if let prev = s.previousVisiblePhotoIndex, s.items.indices.contains(prev) {
            return s.items[prev]
        }
        if let firstVis = s.visiblePhotoIndices.first(where: { $0 != s.currentIndex }) {
            return s.items[firstVis]
        }
        return s.current
    }

    private var surveyItems: [PhotoItem] {
        let visible = s.visiblePhotoIndices
        guard !visible.isEmpty else { return [] }
        let selectedVisible = visible.filter { s.selectedPhotos.contains(s.items[$0].id) }
        if selectedVisible.count >= 2 {
            return Array(selectedVisible.prefix(4).map { s.items[$0] })
        }
        let pos = visible.firstIndex(of: s.currentIndex) ?? 0
        let count = min(4, visible.count)
        let start = max(0, min(pos, visible.count - count))
        return visible[start..<(start + count)].map { s.items[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Picker("", selection: $s.compareSubMode) {
                        ForEach(CompareSubMode.allCases, id: \.self) { m in
                            Text(L10n.tr(m.label)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 240)

                    if s.compareSubMode == .sideBySide {
                        Button(L10n.tr("左右交换")) {
                            let left = primaryCandidateItem
                            let right = s.current
                            if let r = right { s.comparePrimaryID = r.id }
                            if let l = left, let idx = s.items.firstIndex(where: { $0.id == l.id }) {
                                s.select(idx)
                            }
                        }
                        .controlSize(.mini).lineLimit(1)
                        .disabled(s.current == nil)

                        Button(L10n.tr("下一候选")) {
                            if let next = s.nextVisiblePhotoIndex { s.select(next) }
                        }
                        .controlSize(.mini).lineLimit(1)
                        .disabled(s.nextVisiblePhotoIndex == nil)
                    }

                    Spacer(minLength: 8)

                    Toggle(L10n.tr("同步缩放"), isOn: $syncPanZoom)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5)).lineLimit(1)

                    Button(L10n.tr("适合")) { syncScale = 1.0; syncOffset = .zero; dragStart = .zero }.controlSize(.mini).lineLimit(1)
                    Button("1x") { syncScale = 1.0 }.controlSize(.mini)
                    Button("2x") { syncScale = 2.0 }.controlSize(.mini)
                    Button("4x") { syncScale = 4.0 }.controlSize(.mini)
                    Button(L10n.tr("返回单张")) { s.canvasDisplayMode = .single }.controlSize(.mini).lineLimit(1)
                }
                .frame(minWidth: 560)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.bar)

            GeometryReader { geo in
                Group {
                    switch s.compareSubMode {
                    case .beforeAfter:
                        beforeAfterBody(size: geo.size)
                    case .sideBySide:
                        sideBySideBody(size: geo.size)
                    case .survey:
                        surveyBody(size: geo.size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            guard syncPanZoom else { return }
                            syncOffset = CGSize(width: dragStart.width + v.translation.width,
                                                height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = syncOffset }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            guard syncPanZoom else { return }
                            let base = gestureScaleBase ?? syncScale
                            if gestureScaleBase == nil { gestureScaleBase = syncScale }
                            syncScale = min(max(base * value, 0.5), 8.0)
                        }
                        .onEnded { _ in gestureScaleBase = nil }
                )
            }
            .background(StudioStyle.canvas)
            .onAppear {
                s.refreshBefore()
                prefetchCompareFrames()
            }
            .onChange(of: s.current?.id) { _, _ in prefetchCompareFrames() }
            .onChange(of: s.comparePrimaryID) { _, _ in prefetchCompareFrames() }
            .onChange(of: s.compareSubMode) { _, _ in prefetchCompareFrames() }
            .onChange(of: s.selectedPhotos) { _, _ in prefetchCompareFrames() }
        }
    }

    private func prefetchCompareFrames() {
        switch s.compareSubMode {
        case .beforeAfter:
            s.refreshBefore()
        case .sideBySide:
            if let p = primaryCandidateItem { s.ensureMultiViewFrame(for: p) }
            if let c = s.current { s.ensureMultiViewFrame(for: c) }
        case .survey:
            for item in surveyItems { s.ensureMultiViewFrame(for: item) }
        }
    }

    private func liveFrame(for item: PhotoItem) -> PreviewFrame? {
        if item.id == s.current?.id { return s.previewFrame }
        return s.multiViewFrames[item.id]
    }

    @ViewBuilder
    private func beforeAfterBody(size: CGSize) -> some View {
        let halfW = max(1, (size.width - 2) / 2)
        let h = max(1, size.height)
        HStack(spacing: 2) {
            rawFramePane(title: s.beforeFrame != nil ? L10n.tr("修改前原图") : L10n.tr("参考图"),
                         frame: s.beforeFrame ?? s.referenceFrame,
                         size: CGSize(width: halfW, height: h),
                         isLiveMetal: false)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
            rawFramePane(title: L10n.tr("当前调整"),
                         frame: s.previewFrame,
                         size: CGSize(width: halfW, height: h),
                         isLiveMetal: true)
        }
    }

    @ViewBuilder
    private func sideBySideBody(size: CGSize) -> some View {
        let halfW = max(1, (size.width - 2) / 2)
        let h = max(1, size.height)
        let left = primaryCandidateItem
        let right = s.current
        HStack(spacing: 2) {
            if let left {
                itemPane(item: left, badge: L10n.tr("对比基准"), size: CGSize(width: halfW, height: h), isPrimary: true)
            } else {
                Spacer().frame(width: halfW, height: h)
            }
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
            if let right {
                itemPane(item: right, badge: L10n.tr("候选当前"), size: CGSize(width: halfW, height: h), isPrimary: false)
            } else {
                Spacer().frame(width: halfW, height: h)
            }
        }
    }

    @ViewBuilder
    private func surveyBody(size: CGSize) -> some View {
        let list = surveyItems
        if list.count <= 2 {
            let colW = max(1, (size.width - 2) / CGFloat(max(1, list.count)))
            HStack(spacing: 2) {
                ForEach(list) { item in
                    itemPane(item: item, badge: item.id == s.current?.id ? L10n.tr("当前") : nil,
                             size: CGSize(width: colW, height: max(1, size.height)),
                             isPrimary: s.comparePrimaryID == item.id)
                }
            }
        } else {
            let colW = max(1, (size.width - 2) / 2)
            let rowH = max(1, (size.height - 2) / 2)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    itemPane(item: list[0], badge: list[0].id == s.current?.id ? L10n.tr("当前") : nil,
                             size: CGSize(width: colW, height: rowH), isPrimary: s.comparePrimaryID == list[0].id)
                    itemPane(item: list[1], badge: list[1].id == s.current?.id ? L10n.tr("当前") : nil,
                             size: CGSize(width: colW, height: rowH), isPrimary: s.comparePrimaryID == list[1].id)
                }
                HStack(spacing: 2) {
                    itemPane(item: list[2], badge: list[2].id == s.current?.id ? L10n.tr("当前") : nil,
                             size: CGSize(width: colW, height: rowH), isPrimary: s.comparePrimaryID == list[2].id)
                    if list.count > 3 {
                        itemPane(item: list[3], badge: list[3].id == s.current?.id ? L10n.tr("当前") : nil,
                                 size: CGSize(width: colW, height: rowH), isPrimary: s.comparePrimaryID == list[3].id)
                    } else {
                        StudioStyle.canvas.frame(width: colW, height: rowH)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemPane(item: PhotoItem, badge: String?, size: CGSize, isPrimary: Bool) -> some View {
        let isCur = item.id == s.current?.id
        let frame = liveFrame(for: item)
        let imgH = max(1, size.height - 30)
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                StudioStyle.canvas
                if let frame {
                    let fit = DisplayTransform.rect(bitmap: frame.bitmapSize,
                                                    in: CGRect(origin: .zero, size: CGSize(width: size.width, height: imgH)),
                                                    fill: false)
                    let effScale = syncPanZoom ? syncScale : 1.0
                    let effOffset = syncPanZoom ? syncOffset : .zero
                    let scaledRect = CGRect(
                        x: size.width / 2 - (fit.width * effScale) / 2 + effOffset.width,
                        y: imgH / 2 - (fit.height * effScale) / 2 + effOffset.height,
                        width: fit.width * effScale,
                        height: fit.height * effScale
                    )
                    MetalCanvasView(
                        metalImage: frame.metalImage,
                        fallbackCG: frame.image,
                        viewportSize: CGSize(width: size.width, height: imgH),
                        imageRect: scaledRect,
                        edrEnabled: s.edrEnabled,
                        clippingWarning: s.showClippingWarning
                    )
                } else {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(item.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: size.width, height: imgH)
                }

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .frame(width: size.width, height: imgH)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                if let idx = s.items.firstIndex(where: { $0.id == item.id }) {
                    s.select(idx)
                }
            }
            .onAppear { s.ensureMultiViewFrame(for: item) }

            HStack(spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 10.5, weight: isCur ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                ForEach(1...5, id: \.self) { star in
                    Button {
                        s.setRating(item.rating == star ? 0 : star, for: item.id)
                    } label: {
                        Image(systemName: star <= item.rating ? "star.fill" : "star")
                            .font(.system(size: 9))
                            .foregroundStyle(star <= item.rating ? .yellow : .secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
                Button { s.togglePick(for: item.id) } label: {
                    Image(systemName: item.picked ? "flag.fill" : "flag")
                        .font(.system(size: 10))
                        .foregroundStyle(item.picked ? .green : .secondary)
                }.buttonStyle(.plain)
                Button { s.toggleReject(for: item.id) } label: {
                    Image(systemName: item.rejected ? "xmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(item.rejected ? .red : .secondary)
                }.buttonStyle(.plain)
                if !isPrimary {
                    Button(L10n.tr("设为基准")) { s.comparePrimaryID = item.id }
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: size.width, height: 30)
            .background(.bar)
        }
        .overlay(
            Rectangle().stroke(isCur ? WorkspaceTokens.accent.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func rawFramePane(title: String, frame: PreviewFrame?, size: CGSize, isLiveMetal: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            StudioStyle.canvas
            if let frame {
                let fit = DisplayTransform.rect(bitmap: frame.bitmapSize,
                                                in: CGRect(origin: .zero, size: size), fill: false)
                let scaledRect = CGRect(
                    x: size.width / 2 - (fit.width * syncScale) / 2 + syncOffset.width,
                    y: size.height / 2 - (fit.height * syncScale) / 2 + syncOffset.height,
                    width: fit.width * syncScale,
                    height: fit.height * syncScale
                )
                if isLiveMetal {
                    MetalCanvasView(
                        metalImage: frame.metalImage,
                        fallbackCG: frame.image,
                        viewportSize: size,
                        imageRect: scaledRect,
                        edrEnabled: s.edrEnabled,
                        clippingWarning: s.showClippingWarning
                    )
                } else {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .frame(width: scaledRect.width, height: scaledRect.height)
                        .position(x: scaledRect.midX, y: scaledRect.midY)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }
            } else {
                ProgressView().frame(width: size.width, height: size.height)
            }
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// 锁定参考图（Shift+R）与当前活跃图实时并排/上下调色对齐视图。
struct ReferenceCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var verticalSplit = false
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.tr("参考视图"))
                    .font(.system(size: 11.5, weight: .semibold))
                Menu {
                    Button(L10n.tr("将当前设为参考")) { s.setReferencePhoto(s.current?.url) }
                        .disabled(s.current == nil)
                    Button(L10n.tr("从文件选取外部参考图…")) { pickExternalReference() }
                    if !s.items.isEmpty {
                        Divider()
                        ForEach(Array(s.items.filter { !$0.isVirtualCopy }.prefix(40))) { it in
                            Button(it.displayName) { s.setReferencePhoto(it.url) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(s.referencePhotoURL?.lastPathComponent ?? L10n.tr("尚未锁定参考图"))
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button { verticalSplit.toggle() } label: {
                    Image(systemName: verticalSplit ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.system(size: 11))
                }
                .buttonStyle(WorkspaceButtonStyle())
                .controlSize(.mini)
                .help(L10n.tr("切换左右/上下对照布局"))

                Button(L10n.tr("适合")) { scale = 1.0; offset = .zero; dragStart = .zero }.controlSize(.mini)
                Button("2x") { scale = 2.0 }.controlSize(.mini)
                Button(L10n.tr("匹配参考色调")) {
                    _ = s.runColorMatch(referenceURL: s.referencePhotoURL)
                }
                .controlSize(.mini)
                .disabled(s.source == nil || s.referencePhotoURL == nil)
                Button(L10n.tr("将当前设为参考")) { s.setReferencePhoto(s.current?.url) }
                    .controlSize(.mini)
                    .disabled(s.current == nil)
                Button(L10n.tr("返回单张")) { s.canvasDisplayMode = .single }
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)

            GeometryReader { geo in
                let paneSize = verticalSplit
                    ? CGSize(width: max(1, geo.size.width), height: max(1, (geo.size.height - 2) / 2))
                    : CGSize(width: max(1, (geo.size.width - 2) / 2), height: max(1, geo.size.height))
                Group {
                    if verticalSplit {
                        VStack(spacing: 2) {
                            refPane(size: paneSize)
                            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 2)
                            curPane(size: paneSize)
                        }
                    } else {
                        HStack(spacing: 2) {
                            refPane(size: paneSize)
                            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
                            curPane(size: paneSize)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: dragStart.width + v.translation.width,
                                            height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = offset }
                )
            }
            .background(StudioStyle.canvas)
            .onAppear {
                if s.referencePhotoURL == nil { s.setReferencePhoto(s.current?.url) }
            }
        }
    }

    private func pickExternalReference() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url {
            s.setReferencePhoto(u)
        }
    }

    @ViewBuilder
    private func refPane(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            StudioStyle.canvas
            if let ref = s.referenceFrame {
                let fit = DisplayTransform.rect(bitmap: ref.bitmapSize, in: CGRect(origin: .zero, size: size), fill: false)
                let rect = CGRect(x: size.width / 2 - (fit.width * scale) / 2 + offset.width,
                                  y: size.height / 2 - (fit.height * scale) / 2 + offset.height,
                                  width: fit.width * scale, height: fit.height * scale)
                MetalCanvasView(
                    metalImage: ref.metalImage,
                    fallbackCG: ref.image,
                    viewportSize: size,
                    imageRect: rect,
                    edrEnabled: s.edrEnabled,
                    clippingWarning: false
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.checkmark").font(.system(size: 26))
                    Text(L10n.tr("点上方按钮或右键照片「设为参考图」，即可跨片对照色彩与影调"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }.frame(width: size.width, height: size.height)
            }
            Text(L10n.tr("参考锁定"))
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func curPane(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            StudioStyle.canvas
            if let cur = s.previewFrame {
                let fit = DisplayTransform.rect(bitmap: cur.bitmapSize, in: CGRect(origin: .zero, size: size), fill: false)
                let rect = CGRect(x: size.width / 2 - (fit.width * scale) / 2 + offset.width,
                                  y: size.height / 2 - (fit.height * scale) / 2 + offset.height,
                                  width: fit.width * scale, height: fit.height * scale)
                MetalCanvasView(
                    metalImage: cur.metalImage,
                    fallbackCG: cur.image,
                    viewportSize: size,
                    imageRect: rect,
                    edrEnabled: s.edrEnabled,
                    clippingWarning: s.showClippingWarning
                )
            }
            Text(L10n.tr("当前正在编辑"))
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// 污点修复画布矢量与可交互叠加层（显示目标圈、连接线，支持点击选中、直接拖移目标或黄色采样源点）。
struct RetouchOverlay: View {
    let spots: [RetouchSpot]
    let selectedSpotID: UUID?
    let frameSize: CGSize
    var onSelect: ((UUID) -> Void)? = nil
    var onBeginDrag: (() -> Void)? = nil
    var onLiveUpdate: ((RetouchSpot) -> Void)? = nil
    var onEndDrag: (() -> Void)? = nil

    @State private var dragBaseSpot: RetouchSpot?
    @State private var dragStartPt: CGPoint?
    @State private var srcDragID: UUID?
    @State private var srcStartPt: CGPoint?

    var body: some View {
        let shortEdge = min(frameSize.width, frameSize.height)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let se = min(size.width, size.height)
                for spot in spots where spot.enabled {
                    let isSel = spot.id == selectedSpotID
                    let r = max(4, CGFloat(spot.radius) * se)
                    let viewPts = spot.points.compactMap { pair -> CGPoint? in
                        guard pair.count >= 2 else { return nil }
                        return CGPoint(x: CGFloat(pair[0]) * size.width, y: (1 - CGFloat(pair[1])) * size.height)
                    }
                    guard let firstPt = viewPts.first else { continue }
                    let strokeColor: Color = isSel ? WorkspaceTokens.accent : .white.opacity(0.75)

                    for pt in viewPts {
                        let circle = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                        ctx.stroke(circle, with: .color(strokeColor), lineWidth: isSel ? 1.6 : 1.0)
                    }

                    if let sx = spot.sourceX, let sy = spot.sourceY, isSel {
                        let srcPt = CGPoint(x: CGFloat(sx) * size.width, y: (1 - CGFloat(sy)) * size.height)
                        var link = Path()
                        link.move(to: srcPt)
                        link.addLine(to: firstPt)
                        ctx.stroke(link, with: .color(.yellow.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        let srcRing = Path(ellipseIn: CGRect(x: srcPt.x - r, y: srcPt.y - r, width: r * 2, height: r * 2))
                        ctx.stroke(srcRing, with: .color(.yellow), lineWidth: 1.4)
                    }
                }
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .allowsHitTesting(false)

            // 对已落盘污点提供命中点选与中心拖动；对选中且带采样源点的提供直接黄色源点拖动
            ForEach(spots.filter { $0.enabled && !$0.points.isEmpty }) { spot in
                let isSel = spot.id == selectedSpotID
                let firstPt = CGPoint(x: CGFloat(spot.points[0][0]) * frameSize.width,
                                      y: (1 - CGFloat(spot.points[0][1])) * frameSize.height)
                let handleR = max(12, CGFloat(spot.radius) * shortEdge * 0.45)

                Circle()
                    .fill(Color.white.opacity(0.001))
                    .overlay {
                        if isSel {
                            Circle()
                                .fill(WorkspaceTokens.accent)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.white, lineWidth: 1.2))
                        }
                    }
                    .frame(width: handleR * 2, height: handleR * 2)
                    .position(firstPt)
                    .onTapGesture {
                        onSelect?(spot.id)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .local)
                            .onChanged { v in
                                guard onLiveUpdate != nil else { return }
                                if dragBaseSpot == nil || dragStartPt != v.startLocation {
                                    dragStartPt = v.startLocation
                                    dragBaseSpot = spot
                                    onSelect?(spot.id)
                                    onBeginDrag?()
                                }
                                guard let base = dragBaseSpot else { return }
                                let dnx = Double((v.location.x - v.startLocation.x) / max(frameSize.width, 1))
                                let dny = -Double((v.location.y - v.startLocation.y) / max(frameSize.height, 1))
                                var next = base
                                next.points = base.points.map { pair in
                                    [min(max(pair[0] + dnx, 0), 1), min(max(pair[1] + dny, 0), 1)]
                                }
                                onLiveUpdate?(next)
                            }
                            .onEnded { _ in
                                dragBaseSpot = nil
                                dragStartPt = nil
                                onEndDrag?()
                            }
                    )

                if isSel, let sx = spot.sourceX, let sy = spot.sourceY {
                    let srcPt = CGPoint(x: CGFloat(sx) * frameSize.width,
                                        y: (1 - CGFloat(sy)) * frameSize.height)
                    Circle()
                        .fill(Color.yellow.opacity(0.22))
                        .overlay(Circle().stroke(.yellow, lineWidth: 1.4))
                        .frame(width: 14, height: 14)
                        .position(srcPt)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { v in
                                    guard onLiveUpdate != nil else { return }
                                    if srcDragID != spot.id || srcStartPt != v.startLocation {
                                        srcDragID = spot.id
                                        srcStartPt = v.startLocation
                                        onBeginDrag?()
                                    }
                                    var next = spot
                                    next.sourceX = min(max(Double(v.location.x / max(frameSize.width, 1)), 0), 1)
                                    next.sourceY = min(max(Double(1 - v.location.y / max(frameSize.height, 1)), 0), 1)
                                    onLiveUpdate?(next)
                                }
                                .onEnded { _ in
                                    srcDragID = nil
                                    srcStartPt = nil
                                    onEndDrag?()
                                }
                        )
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }
}

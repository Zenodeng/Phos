import SwiftUI

/// 多图视图（网格看片 G / 双图同步缩放对比 C / 参考视图 Shift+R）以及画布污点修复交互叠加层。
struct GridCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(s.visiblePhotoIndices, id: \.self) { idx in
                    let item = s.items[idx]
                    let isCurrent = idx == s.currentIndex
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
                            .frame(height: 126)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .cornerRadius(6)
                            .opacity(item.rejected ? 0.42 : 1.0)

                            HStack(spacing: 4) {
                                if item.colorLabel != .none {
                                    Circle()
                                        .fill(labelColor(item.colorLabel))
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
                                Image(systemName: star <= item.rating ? "star.fill" : "star")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(star <= item.rating ? .yellow : .secondary.opacity(0.4))
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
                            .fill(isCurrent ? WorkspaceTokens.accent.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isCurrent ? WorkspaceTokens.accent : WorkspaceTokens.hairline, lineWidth: isCurrent ? 1.5 : 0.6)
                    )
                    .onAppear {
                        s.requestThumbnails(Set([item.id]))
                    }
                    .onTapGesture(count: 2) {
                        s.select(idx)
                        s.canvasDisplayMode = .single
                    }
                    .onTapGesture(count: 1) {
                        s.select(idx)
                    }
                }
            }
            .padding(16)
        }
        .background(StudioStyle.canvas)
    }

    private func labelColor(_ l: ColorLabel) -> Color {
        switch l {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

/// 并排同步缩放/平移对比视图（C）：左 = 原片或参考帧，右 = 当前 Metal HDR 渲染。
struct CompareCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState
    @State private var syncScale: CGFloat = 1.0
    @State private var syncOffset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.tr("双图同步对比"))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button("1x") { syncScale = 1.0; syncOffset = .zero }.controlSize(.mini)
                Button("2x") { syncScale = 2.0 }.controlSize(.mini)
                Button("4x") { syncScale = 4.0 }.controlSize(.mini)
                Button(L10n.tr("退出")) { s.canvasDisplayMode = .single }.controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)

            GeometryReader { geo in
                let halfW = max(1, (geo.size.width - 2) / 2)
                let h = max(1, geo.size.height)
                HStack(spacing: 2) {
                    pane(title: s.beforeFrame != nil ? L10n.tr("修改前原图") : L10n.tr("参考图"),
                         frame: s.beforeFrame ?? s.referenceFrame,
                         size: CGSize(width: halfW, height: h),
                         isLiveMetal: false)
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
                    pane(title: L10n.tr("当前调整"),
                         frame: s.previewFrame,
                         size: CGSize(width: halfW, height: h),
                         isLiveMetal: true)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            syncOffset = CGSize(width: dragStart.width + v.translation.width,
                                                height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = syncOffset }
                )
            }
            .background(StudioStyle.canvas)
            .onAppear { s.refreshBefore() }
        }
    }

    @ViewBuilder
    private func pane(title: String, frame: PreviewFrame?, size: CGSize, isLiveMetal: Bool) -> some View {
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

/// 锁定参考图（Shift+R）与当前活跃图实时并排调色对齐视图。
struct ReferenceCanvasView: View {
    @ObservedObject private var interfaceLanguage = AppLanguage.shared
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.tr("参考视图"))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(s.referencePhotoURL?.lastPathComponent ?? L10n.tr("尚未锁定参考图"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L10n.tr("将当前设为参考")) { s.setReferencePhoto(s.current?.url) }
                    .controlSize(.mini)
                    .disabled(s.current == nil)
                Button(L10n.tr("返回单张")) { s.canvasDisplayMode = .single }
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)

            GeometryReader { geo in
                let halfW = max(1, (geo.size.width - 2) / 2)
                let h = max(1, geo.size.height)
                HStack(spacing: 2) {
                    ZStack(alignment: .topLeading) {
                        StudioStyle.canvas
                        if let ref = s.referenceFrame {
                            let rect = DisplayTransform.rect(bitmap: ref.bitmapSize,
                                                             in: CGRect(origin: .zero, size: CGSize(width: halfW, height: h)), fill: false)
                            Image(decorative: ref.image, scale: 1)
                                .resizable()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.checkmark").font(.system(size: 26))
                                Text(L10n.tr("点上方按钮或右键照片「设为参考图」，即可跨片对照色彩与影调"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 20)
                            }.frame(width: halfW, height: h)
                        }
                        Text(L10n.tr("参考锁定"))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                    .frame(width: halfW, height: h)

                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)

                    ZStack(alignment: .topLeading) {
                        StudioStyle.canvas
                        if let cur = s.previewFrame {
                            let rect = DisplayTransform.rect(bitmap: cur.bitmapSize,
                                                             in: CGRect(origin: .zero, size: CGSize(width: halfW, height: h)), fill: false)
                            MetalCanvasView(
                                metalImage: cur.metalImage,
                                fallbackCG: cur.image,
                                viewportSize: CGSize(width: halfW, height: h),
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
                    .frame(width: halfW, height: h)
                }
            }
            .background(StudioStyle.canvas)
            .onAppear {
                if s.referencePhotoURL == nil { s.setReferencePhoto(s.current?.url) }
            }
        }
    }
}

/// 污点修复画布矢量叠加层（显示目标范围圈与修复/仿制采样源连接线）。
struct RetouchOverlay: View {
    let spots: [RetouchSpot]
    let selectedSpotID: UUID?
    let frameSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            let shortEdge = min(size.width, size.height)
            for spot in spots where spot.enabled {
                let isSel = spot.id == selectedSpotID
                let r = max(4, CGFloat(spot.radius) * shortEdge)
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
    }
}

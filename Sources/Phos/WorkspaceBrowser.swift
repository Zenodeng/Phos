import AppKit
import Combine
import SwiftUI

/// Both browser layouts and every navigation command share this single selection policy.
@MainActor
final class PhotoSelectionController {
    let state: AppState
    weak var window: NSWindow?
    private var anchor: UUID?
    init(state: AppState) { self.state = state }
    func finishEditing() {
        let finish = state.finishPendingPhotoEdit
        state.finishPendingPhotoEdit = nil; state.pendingPhotoEditID = nil; finish?()
        window?.makeFirstResponder(nil)
    }
    func activate(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard state.items.indices.contains(index), !state.syncRunning else { return }
        let item = state.items[index]
        if modifiers.contains(.command) {
            if state.selectedPhotos.contains(item.id) { state.selectedPhotos.remove(item.id) }
            else { state.selectedPhotos.insert(item.id) }
            anchor = item.id
            return
        }
        let visible = state.visiblePhotoIndices
        if modifiers.contains(.shift), let end = visible.firstIndex(of: index) {
            let anchorID = anchor ?? state.current?.id
            let start = visible.firstIndex { state.items[$0].id == anchorID } ?? end
            let range = min(start, end)...max(start, end)
            state.selectedPhotos = Set(range.map { state.items[visible[$0]].id })
        } else {
            state.selectedPhotos = []
            anchor = item.id
        }
        finishEditing()
        state.select(index)
    }
    func navigate(_ delta: Int, extending: Bool = false) {
        let target = delta < 0 ? state.previousVisiblePhotoIndex : state.nextVisiblePhotoIndex
        if let target { activate(target, modifiers: extending ? [.shift] : []) }
    }
    func selectAllVisible() { state.selectedPhotos = Set(state.visiblePhotoIndices.map { state.items[$0].id }) }
    /// Native text fields consume arrows and rating digits themselves.
    @discardableResult func handleKey(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard state.pendingPhotoEditID == nil, !(firstResponder is NSTextView), !(firstResponder is NSTextField), !(firstResponder is WorkspaceModeSegmentButton), !state.syncRunning,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123, 126: navigate(-1, extending: event.modifierFlags.contains(.shift)); return true
        case 124, 125: navigate(1, extending: event.modifierFlags.contains(.shift)); return true
        default:
            if let text = event.charactersIgnoringModifiers, let rating = Int(text), (0...5).contains(rating), state.current != nil {
                finishEditing(); state.setRating(rating); return true
            }
            return false
        }
    }
}

struct WorkspaceBrowser: NSViewRepresentable {
    let model: WorkspaceWindowModel
    func makeNSView(context: Context) -> WorkspaceBrowserView { WorkspaceBrowserView(model: model) }
    func updateNSView(_ view: WorkspaceBrowserView, context: Context) {}
}

@MainActor
final class WorkspacePhotoCell: NSButton {
    let thumbnail = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let currentMark = NSImageView(), multiMark = NSImageView()
    var perform: () -> Void = {}
    let film: Bool
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(film: Bool) {
        self.film = film
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        wantsLayer = true; layer?.cornerRadius = 7
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 4; thumbnail.layer?.masksToBounds = true
        name.font = .systemFont(ofSize: 11, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        currentMark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "当前照片")
        multiMark.image = NSImage(systemSymbolName: "checkmark.square.fill", accessibilityDescription: "已加入多选")
        for view in [thumbnail, name, detail, currentMark, multiMark] { addSubview(view) }
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func activate() { perform() }
    func configure(_ item: PhotoItem, current: Bool, multi: Bool, failed: Bool) {
        let title = item.url.lastPathComponent
        name.stringValue = item.url.deletingPathExtension().lastPathComponent
        detail.stringValue = item.url.pathExtension.uppercased() + (item.picked ? " · 已标记" : "") + (failed ? " · 无法预览" : "")
        thumbnail.image = item.thumb.map { NSImage(cgImage: $0, size: .zero) }
            ?? NSImage(systemSymbolName: failed ? "exclamationmark.triangle" : "photo", accessibilityDescription: failed ? "缩略图加载失败" : "缩略图加载中")
        thumbnail.contentTintColor = .tertiaryLabelColor
        currentMark.isHidden = !current; multiMark.isHidden = !multi
        currentMark.contentTintColor = .rfGold; multiMark.contentTintColor = .rfGold
        layer?.backgroundColor = (current ? NSColor.rfGold.withAlphaComponent(0.14) : multi ? NSColor.rfGold.withAlphaComponent(0.08) : .clear).cgColor
        layer?.borderColor = (current ? NSColor.rfGold.withAlphaComponent(0.55) : .clear).cgColor
        layer?.borderWidth = current ? 1 : 0
        toolTip = item.url.path
        setAccessibilityLabel(title + (current ? "，当前照片" : "") + (multi ? "，已多选" : ""))
        setAccessibilityHelp("\(item.url.pathExtension.uppercased())，\(item.rating)星\(item.picked ? "，已标记" : "")。Command切换多选，Shift选择范围。")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        if film {
            thumbnail.frame = CGRect(x: 7, y: 4, width: bounds.width - 14, height: 50)
            name.alignment = .center; name.frame = CGRect(x: 4, y: 59, width: bounds.width - 8, height: 15)
            detail.isHidden = true
            currentMark.frame = CGRect(x: bounds.width - 19, y: 6, width: 12, height: 12)
        } else {
            thumbnail.frame = CGRect(x: 6, y: 5, width: 46, height: 36)
            name.frame = CGRect(x: 62, y: 7, width: max(20, bounds.width - 84), height: 16)
            detail.frame = CGRect(x: 62, y: 25, width: max(20, bounds.width - 70), height: 14)
            currentMark.frame = CGRect(x: bounds.width - 20, y: 16, width: 12, height: 12)
        }
        multiMark.frame = CGRect(x: 6, y: 5, width: 14, height: 14)
    }
}

@MainActor
private final class WorkspacePhotoTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private final class WorkspaceFilmDocument: NSView {
    weak var browser: WorkspaceBrowserView?
    private var cells: [Int: WorkspacePhotoCell] = [:]
    private var pool: [WorkspacePhotoCell] = []
    override var isFlipped: Bool { true }
    func refresh() {
        guard let browser else { return }
        let indices = browser.indices
        let visible = enclosingScrollView?.contentView.bounds ?? .zero
        let lo = max(0, Int(floor(visible.minX / 90)) - 1), hi = min(indices.count, Int(ceil(visible.maxX / 90)) + 1)
        let wanted = Set(lo..<max(lo, hi))
        for index in Array(cells.keys) where !wanted.contains(index) {
            if let cell = cells.removeValue(forKey: index) { cell.removeFromSuperview(); pool.append(cell) }
        }
        for row in wanted.sorted() {
            let cell: WorkspacePhotoCell
            if let existing = cells[row] { cell = existing }
            else { cell = pool.popLast() ?? WorkspacePhotoCell(film: true); cells[row] = cell; addSubview(cell) }
            cell.frame = CGRect(x: CGFloat(row) * 90 + 4, y: 2, width: 84, height: 80)
            browser.configure(cell, row: row)
        }
    }
    func clear() { for cell in cells.values { cell.removeFromSuperview(); pool.append(cell) }; cells.removeAll() }
}

@MainActor
final class WorkspaceBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: WorkspaceWindowModel
    private let heading = NSTextField(labelWithString: "照片")
    private let folder = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let filter = NSPopUpButton(frame: .zero, pullsDown: true)
    private let listScroll = NSScrollView(), filmScroll = NSScrollView()
    private let table = WorkspacePhotoTable()
    private let film = WorkspaceFilmDocument()
    private let empty = NSTextField(wrappingLabelWithString: "打开文件夹开始选片")
    private let footer = NSTextField(labelWithString: "")
    private var stars: [NSButton] = []
    private let pick = WorkspaceToolButton("flag", "标记当前照片", action: {}), sync = WorkspaceToolButton("arrow.triangle.2.circlepath", "同步所选照片", action: {})
    private var observations: [AnyCancellable] = []
    private var scrollObservations: [NSObjectProtocol] = []
    private(set) var indices: [Int] = []
    private var lastCurrent: UUID?
    private var lastMode: WorkspaceMode?
    private var lastDemand: Set<UUID> = []
    private var lastFilterState: String?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: WorkspaceWindowModel) {
        self.model = model
        super.init(frame: .zero)
        film.browser = self
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        folder.font = .systemFont(ofSize: 11); folder.textColor = .secondaryLabelColor; folder.lineBreakMode = .byTruncatingMiddle
        search.placeholderString = "搜索照片"; search.font = .systemFont(ofSize: 11); search.controlSize = .small; search.delegate = self
        search.setAccessibilityLabel("搜索照片")
        filter.isBordered = false; filter.imagePosition = .imageOnly; (filter.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        filter.setAccessibilityLabel("筛选与选择操作")
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 46; table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photo")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("照片列表")
        for scroll in [listScroll, filmScroll] {
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObservations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisible() }
            })
        }
        listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.documentView = table
        filmScroll.hasHorizontalScroller = true; filmScroll.autohidesScrollers = true; filmScroll.documentView = film
        filmScroll.setAccessibilityLabel("胶片条")
        empty.alignment = .center; empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        footer.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); footer.textColor = .secondaryLabelColor
        for value in 1...5 {
            let button = WorkspaceToolButton("star", "评分\(value)星", action: {})
            button.target = self; button.action = #selector(rate(_:))
            button.isBordered = false; button.tag = value; button.toolTip = "\(value)星，再点一次清除"; button.setAccessibilityLabel("评分\(value)星")
            stars.append(button); addSubview(button)
        }
        pick.image = NSImage(systemSymbolName: "flag", accessibilityDescription: "标记当前照片")
        pick.isBordered = false; pick.target = self; pick.action = #selector(togglePick); pick.toolTip = "标记当前照片"; pick.setAccessibilityLabel("标记当前照片")
        sync.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "同步所选照片")
        sync.isBordered = false; sync.target = self; sync.action = #selector(synchronize); sync.toolTip = "同步所选照片"; sync.setAccessibilityLabel("同步所选照片")
        for view in [heading, folder, search, filter, listScroll, filmScroll, empty, footer, pick, sync] { addSubview(view) }
        model.state.objectWillChange.debounce(for: .milliseconds(1), scheduler: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        model.session.objectWillChange.debounce(for: .milliseconds(1), scheduler: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        model.environment.objectWillChange.debounce(for: .milliseconds(1), scheduler: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { for observer in scrollObservations { NotificationCenter.default.removeObserver(observer) } }
    func numberOfRows(in tableView: NSTableView) -> Int { indices.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("photo-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? WorkspacePhotoCell) ?? WorkspacePhotoCell(film: false)
        cell.identifier = id; configure(cell, row: row); return cell
    }
    fileprivate func configure(_ cell: WorkspacePhotoCell, row: Int) {
        guard indices.indices.contains(row), model.state.items.indices.contains(indices[row]) else { return }
        let index = indices[row], s = model.state, item = s.items[index]
        cell.configure(item, current: index == s.currentIndex, multi: s.selectedPhotos.contains(item.id), failed: s.thumbnailFailures.contains(item.id))
        cell.perform = { [weak self] in
            guard let self, let index = model.state.items.firstIndex(where: { $0.id == item.id }) else { return }
            model.selection.activate(index, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            window?.makeFirstResponder(self)
        }
    }
    func refresh() {
        for button in (stars + [pick, sync]).compactMap({ $0 as? WorkspaceToolButton }) {
            button.motionReduced = model.environment.accessibility.reduceMotion
        }
        let s = model.state, isFilm = model.session.mode == .filmstrip
        let next = s.visiblePhotoIndices
        let membershipChanged = next != indices
        if membershipChanged {
            indices = next; table.reloadData(); film.clear(); lastDemand = []
        } else {
            table.enumerateAvailableRowViews { [weak self] _, row in
                guard let self, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspacePhotoCell else { return }
                configure(cell, row: row)
            }
        }
        heading.stringValue = isFilm ? (s.folder?.lastPathComponent ?? "照片") : "照片"
        folder.stringValue = "\(s.folder?.lastPathComponent ?? "尚未打开文件夹") · \(indices.count)张"
        folder.toolTip = s.folder?.path; heading.toolTip = s.folder?.path
        if search.stringValue != s.searchText { search.stringValue = s.searchText }
        let position = s.visiblePhotoPosition.map { "\($0) / \(indices.count)" } ?? (s.current == nil ? "\(indices.count)张" : "当前照片已被筛选隐藏")
        footer.stringValue = s.selectedPhotos.isEmpty ? position : "已选 \(s.selectedPhotos.count) · \(position)"
        empty.stringValue = s.folderLoading ? "正在读取文件夹…" : s.folderFailure ?? (s.items.isEmpty ? (s.folder == nil ? "打开文件夹开始选片" : "文件夹里没有支持的图像") : "没有符合筛选条件的照片")
        empty.isHidden = !indices.isEmpty
        for button in stars {
            button.isEnabled = s.current != nil && !s.syncRunning
            button.image = NSImage(systemSymbolName: (s.current?.rating ?? 0) >= button.tag ? "star.fill" : "star", accessibilityDescription: "评分\(button.tag)星")
            button.contentTintColor = (s.current?.rating ?? 0) >= button.tag ? .rfGold : .secondaryLabelColor
        }
        pick.isEnabled = s.current != nil && !s.syncRunning; pick.contentTintColor = s.current?.picked == true ? .rfGold : .secondaryLabelColor
        pick.image = NSImage(systemSymbolName: s.current?.picked == true ? "flag.fill" : "flag", accessibilityDescription: "标记当前照片")
        sync.isEnabled = model.enabled(.sync)
        listScroll.isHidden = isFilm; filmScroll.isHidden = !isFilm
        let changed = membershipChanged || lastCurrent != s.current?.id || lastMode != model.session.mode
        lastCurrent = s.current?.id; lastMode = model.session.mode
        updateFilter()
        if membershipChanged || changed { needsLayout = true; layoutSubtreeIfNeeded() }
        if changed, let row = indices.firstIndex(of: s.currentIndex) {
            if isFilm { film.scrollToVisible(CGRect(x: CGFloat(row) * 90, y: 0, width: 90, height: 80)) }
            else { table.scrollRowToVisible(row) }
        }
        refreshVisible()
    }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, isFilm = model.session.mode == .filmstrip
        if isFilm {
            heading.frame = CGRect(x: 12, y: 8, width: min(140, w * 0.2), height: 16)
            folder.isHidden = true; footer.isHidden = true
            search.frame = CGRect(x: min(160, w * 0.22), y: 6, width: min(200, w * 0.28), height: 22)
            filter.frame = CGRect(x: w - 198, y: 4, width: 28, height: 26)
            for (i, button) in stars.enumerated() { button.frame = CGRect(x: w - 166 + CGFloat(i) * 22, y: 4, width: 22, height: 26) }
            pick.frame = CGRect(x: w - 54, y: 4, width: 22, height: 26); sync.frame = CGRect(x: w - 30, y: 4, width: 22, height: 26)
            filmScroll.frame = CGRect(x: 6, y: 32, width: max(1, w - 12), height: h - 36)
            film.frame = CGRect(x: 0, y: 0, width: max(filmScroll.contentSize.width, CGFloat(indices.count) * 90 + 8), height: 84)
        } else {
            heading.frame = CGRect(x: 12, y: 12, width: w - 48, height: 18)
            folder.isHidden = false; footer.isHidden = false
            folder.frame = CGRect(x: 12, y: 35, width: w - 24, height: 16)
            search.frame = CGRect(x: 10, y: 60, width: w - 20, height: 23)
            filter.frame = CGRect(x: w - 36, y: 7, width: 28, height: 28)
            listScroll.frame = CGRect(x: 5, y: 93, width: w - 10, height: max(40, h - 155))
            for (i, button) in stars.enumerated() { button.frame = CGRect(x: 10 + CGFloat(i) * 25, y: h - 53, width: 24, height: 25) }
            pick.frame = CGRect(x: w - 59, y: h - 53, width: 24, height: 25); sync.frame = CGRect(x: w - 31, y: h - 53, width: 24, height: 25)
            footer.frame = CGRect(x: 12, y: h - 23, width: w - 24, height: 15)
        }
        empty.frame = CGRect(x: 12, y: isFilm ? 55 : max(110, h / 2 - 30), width: max(40, w - 24), height: 42)
        refreshVisible()
    }
    private func refreshVisible() {
        guard bounds.width > 0, !isHidden, model.session.browserVisible else { return }
        let rows: [Int]
        if model.session.mode == .filmstrip {
            film.refresh()
            let rect = filmScroll.contentView.bounds
            let lo = max(0, Int(rect.minX / 90) - 2), hi = min(indices.count, Int(ceil(rect.maxX / 90)) + 3)
            rows = Array(lo..<max(lo, hi))
        } else {
            let range = table.rows(in: listScroll.contentView.bounds)
            if range.location == NSNotFound { rows = [] }
            else {
                let lo = max(0, range.location - 3), hi = min(indices.count, NSMaxRange(range) + 3)
                rows = Array(lo..<max(lo, hi))
            }
        }
        let ids = Set(rows.filter { indices.indices.contains($0) }.map { model.state.items[indices[$0]].id })
        guard ids != lastDemand else { return }; lastDemand = ids
        model.state.requestThumbnails(ids)
    }
    func controlTextDidChange(_ notification: Notification) { model.state.searchText = search.stringValue }
    override func keyDown(with event: NSEvent) {
        if !model.selection.handleKey(event, firstResponder: self) { super.keyDown(with: event) }
    }
    @objc private func rate(_ sender: NSButton) { model.selection.finishEditing(); model.state.setRating(model.state.current?.rating == sender.tag ? 0 : sender.tag) }
    @objc private func togglePick() { model.selection.finishEditing(); model.state.togglePick() }
    @objc private func synchronize() { model.perform(.sync) }
    private func updateFilter() {
        let s = model.state
        let filterState = "\(s.filterRating)-\(s.filterPicked)"
        guard lastFilterState != filterState else { return }
        lastFilterState = filterState
        let menu = NSMenu()
        let title = NSMenuItem(title: "筛选", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "筛选")
        menu.addItem(title)
        for value in 0...5 {
            let item = NSMenuItem(title: value == 0 ? "所有星级" : "至少\(value)星", action: #selector(filterRating(_:)), keyEquivalent: "")
            item.tag = value; item.target = self; item.state = s.filterRating == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let picked = NSMenuItem(title: "仅已标记", action: #selector(filterPicked), keyEquivalent: ""); picked.target = self; picked.state = s.filterPicked ? .on : .off; menu.addItem(picked)
        menu.addItem(.separator())
        for (title, action) in [("全选筛选结果", #selector(selectAllPhotos)), ("清除多选", #selector(clearSelection))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        filter.menu = menu
        filter.contentTintColor = s.filterRating > 0 || s.filterPicked ? .rfGold : .secondaryLabelColor
    }
    @objc private func filterRating(_ item: NSMenuItem) { model.state.filterRating = item.tag }
    @objc private func filterPicked() { model.state.filterPicked.toggle() }
    @objc private func selectAllPhotos() { model.selection.selectAllVisible() }
    @objc private func clearSelection() { model.state.selectedPhotos = [] }
}

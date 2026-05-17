import AppKit
import SwiftUI

struct PickerView: View {
    @ObservedObject var viewModel: PickerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Always present so the NSSearchField stays first responder and
            // the IME pipeline is alive — collapsed to 0 height when there's
            // no query so the picker looks identical to the pre-search UI.
            // First keystroke commits → query becomes non-empty → expands.
            searchBar
                .frame(height: searchBarVisible ? 28 : 0)
                .opacity(searchBarVisible ? 1 : 0)
                .padding(.horizontal, searchBarVisible ? 6 : 0)
                .padding(.top, searchBarVisible ? 6 : 0)
                .padding(.bottom, searchBarVisible ? 2 : 0)
                .clipped()
            list
            Divider().opacity(0.4)
            filterBar
            footer
        }
        .frame(width: 360, height: 422)
    }

    // Always-visible chip row. Empty buckets are dropped in the view model,
    // so the only time this collapses is when the user has *no* clips at all
    // — in which case `availableFilters` is `[.all]` and we hide the row
    // entirely (showing a lone "All" chip is just noise).
    @ViewBuilder
    private var filterBar: some View {
        if viewModel.availableFilters.count > 1 {
            // Horizontal scroll — chip count grows as new detectors land
            // (Personal, Command, future address-of-its-own, …). At a
            // 360pt picker width even the current 7 chips overflow, so we
            // never trust the row to fit. Hidden scrollbar matches the
            // Raycast / Spotlight chip-strip aesthetic. ScrollViewReader
            // keeps the active chip in view when the user cycles past the
            // visible window with ←/→.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(viewModel.availableFilters, id: \.self) { f in
                            filterChip(f).id(f)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.kindFilter) { newFilter in
                    // `.center` keeps the chip centered when possible and
                    // pinned at the closest edge near the ends — the macOS
                    // standard for category strips (Spotlight, Raycast).
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newFilter, anchor: .center)
                    }
                }
            }
        }
    }

    private func filterChip(_ f: KindFilter) -> some View {
        let selected = viewModel.kindFilter == f
        return Button(action: { viewModel.setKindFilter(f) }) {
            HStack(spacing: 3) {
                Image(systemName: f.symbol)
                    .font(.system(size: 9))
                Text(f.label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(selected
                               ? Color.accentColor.opacity(0.25)
                               : Color.secondary.opacity(0.10))
            )
            .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var searchBarVisible: Bool { viewModel.searchActive }

    private var searchBar: some View {
        SearchField(viewModel: viewModel)
    }

    @ViewBuilder
    private var list: some View {
        if viewModel.items.isEmpty {
            VStack(spacing: 4) {
                Spacer()
                if !viewModel.query.isEmpty {
                    Text("No matches for \u{201C}\(viewModel.query)\u{201D}")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Press Esc to clear")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                } else {
                    Text("No clipboard history yet.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Copy something, then press ⌘⇧V.")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { idx, item in
                            ClipRowView(
                                item: item,
                                selected: idx == viewModel.selectedIndex,
                                style: viewModel.viewStyle,
                                sortOrder: viewModel.sortOrder
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                // Mouse-follow selection (Raycast / Spotlight style).
                                // Keyboard nav stays usable; mouse just wins on motion.
                                if hovering {
                                    viewModel.selectedIndex = idx
                                }
                            }
                            .onTapGesture {
                                viewModel.selectedIndex = idx
                                viewModel.pickCurrent()
                            }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: viewModel.scrollTick) { _ in
                    let idx = viewModel.selectedIndex
                    if viewModel.items.indices.contains(idx) {
                        withAnimation(.linear(duration: 0.05)) {
                            proxy.scrollTo(viewModel.items[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        // ↑↓⏎ and Esc are universal picker affordances — every macOS user
        // already knows them, so spelling them out just steals room from the
        // hints that aren't obvious (←→ filter, ⌫ delete, type-to-search).
        HStack(spacing: 6) {
            // ←→ only acts on the filter while there's nothing to edit in
            // the search field. Showing the hint only in that mode mirrors
            // the actual key behavior — no misleading "always available" UI.
            if viewModel.query.isEmpty && viewModel.availableFilters.count > 1 {
                Text("←→ filter")
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            if viewModel.query.isEmpty && !viewModel.items.isEmpty {
                Text("⌫ delete")
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            if !viewModel.searchActive {
                Text("type to search")
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .foregroundStyle(.tertiary)
            }
            sortBadge
            Spacer(minLength: 0)
            settingsMenu
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // Tap to flip between recency / frequency. The same toggle is exposed in
    // the ⚙ menu — both write Settings.sortOrder, and we also refresh the
    // menubar status item's menu so its checkmark doesn't go stale.
    private var sortBadge: some View {
        Button(action: {
            viewModel.toggleSortOrder()
            (NSApp.delegate as? AppDelegate)?.refreshMenubarMenu()
        }) {
            HStack(spacing: 2) {
                Image(systemName: viewModel.sortOrder == .recency
                      ? "clock"
                      : "chart.bar.fill")
                    .font(.system(size: 9))
                Text(viewModel.sortOrder == .recency ? "recent" : "frequent")
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to switch sort order")
    }

    // Pops up the same NSMenu that the menubar status item uses, so checkmarks
    // can never drift between the two surfaces — they're literally the same
    // menu, rebuilt fresh on every open.
    private var settingsMenu: some View {
        SharedMenuButton()
            .frame(width: 22, height: 14)
    }
}

private struct SharedMenuButton: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuPopButton {
        let b = MenuPopButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: "gearshape",
                          accessibilityDescription: "Settings")
        b.image?.isTemplate = true
        b.imagePosition = .imageOnly
        return b
    }
    func updateNSView(_ nsView: MenuPopButton, context: Context) {}
}

final class MenuPopButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let menu = delegate.buildSharedMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: bounds.height + 2),
                   in: self)
    }
}

private struct ClipRowView: View {
    let item: ClipItem
    let selected: Bool
    let style: ViewStyle
    let sortOrder: SortOrder

    /// Use-count is only relevant under frequency sort. Under recency, the
    /// number is noise — what matters is "when". Same idea for the compact
    /// "×N" badge.
    private var showsUseCount: Bool {
        sortOrder == .frequency && item.useCount > 1
    }

    var body: some View {
        switch style {
        case .compact:   compactRow
        case .detailed:  detailedRow
        }
    }

    private var compactRow: some View {
        HStack(spacing: 6) {
            icon(size: 16)
                .frame(width: 16, height: 16)
            Text(compactTitle)
                .lineLimit(1)
                .font(.system(size: 12))
            Spacer()
            if showsUseCount {
                Text("×\(item.useCount)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
    }

    @ViewBuilder
    private var detailedRow: some View {
        switch item.card {
        case .image:   imageDetailRow
        case .fileURL: fileDetailRow
        case .color:   colorDetailRow
        case .url:     urlDetailRow
        case .text, .phone, .email, .creditCard, .ssn, .address, .command:
            // Personal + Command cards reuse the text layout — `icon(size:)`
            // and `displayPreview` already specialize per card, so a
            // dedicated row builder would just duplicate the same HStack.
            textDetailRow
        }
    }

    // All detail rows use the same 36×36 leading icon/thumbnail box so the
    // text baselines line up across rows. Hover preview surfaces the larger
    // version on demand — the row itself just needs a glanceable token.
    private static let detailIconSize: CGFloat = 36

    private var textDetailRow: some View {
        HStack(spacing: 8) {
            icon(size: Self.detailIconSize)
                .frame(width: Self.detailIconSize, height: Self.detailIconSize)
                .background(Color.black.opacity(0.05))
                .cornerRadius(3)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayPreview)
                    .lineLimit(2)
                    .font(.system(size: 13))
                meta
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    private var imageDetailRow: some View {
        HStack(spacing: 8) {
            Group {
                if let data = item.thumbnail, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.detailIconSize, height: Self.detailIconSize)
            .background(Color.black.opacity(0.05))
            .cornerRadius(3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Image · \(dimensionsFromPreview)")
                    .font(.system(size: 13))
                meta
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    @ViewBuilder
    private var colorDetailRow: some View {
        if let raw = item.text, let parsed = parseColor(raw) {
            let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: parsed.color))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                    )
                    .frame(width: Self.detailIconSize, height: Self.detailIconSize)
                VStack(alignment: .leading, spacing: 1) {
                    // Primary line is whatever the user actually copied —
                    // don't replace `hsl(...)` with `#...` behind their back.
                    Text(trimmedRaw)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Secondary surfaces the "other" canonical form for quick
                    // mental conversion. Skipped when raw is already HEX-ish
                    // to avoid a near-duplicate line.
                    if let alt = alternateColorEncoding(raw: trimmedRaw, parsed: parsed) {
                        Text(alt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    meta
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(rowBackground)
        } else {
            textDetailRow
        }
    }

    /// Pick a single alt-encoding to show under the user's raw color string.
    /// If raw is hex → show RGB; if rgb/hsl → show HEX. Returns nil when the
    /// would-be-alt is identical to the raw (case-insensitively).
    private func alternateColorEncoding(raw: String, parsed: ParsedColor) -> String? {
        let lowerRaw = raw.lowercased()
        let alt = lowerRaw.hasPrefix("#") ? parsed.rgb : parsed.hex
        return alt.lowercased() == lowerRaw ? nil : alt
    }

    @ViewBuilder
    private var urlDetailRow: some View {
        if let raw = item.text {
            let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.detailIconSize, height: Self.detailIconSize)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(3)
                VStack(alignment: .leading, spacing: 1) {
                    // Show the URL exactly as copied — scheme included, path
                    // included. The globe icon is enough of a visual hint
                    // without us rewriting the string.
                    Text(trimmedRaw)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    meta
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(rowBackground)
        } else {
            textDetailRow
        }
    }

    private var fileDetailRow: some View {
        HStack(spacing: 8) {
            workspaceIcon(size: Self.detailIconSize)
                .frame(width: Self.detailIconSize, height: Self.detailIconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(primaryFileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let extra = extraFilesSuffix {
                        Text(extra)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let parent = parentDirDisplay {
                    Text(parent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                meta
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(Self.coarseRelative(item.createdAt))
            if showsUseCount {
                Text("·")
                Text("used \(item.useCount)×")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    // MARK: - Title resolution

    private var compactTitle: String {
        switch item.card {
        case .text:    return item.preview
        case .image:   return "Image · \(dimensionsFromPreview)"
        case .fileURL:
            if let extra = extraFilesSuffix {
                return "\(primaryFileName) \(extra)"
            }
            return primaryFileName
        case .color, .url, .phone, .email, .address, .command:
            // Compact title preserves what the user copied — the leading
            // icon (color swatch / globe / phone / envelope / pin /
            // terminal) is enough of a type hint.
            return item.preview
        case .creditCard, .ssn:
            // Masked even in compact view. The real value is still copied
            // verbatim on Enter — masking is a display concern only, so a
            // shoulder-surfer glancing at the picker can't read a SSN off
            // the screen.
            return displayPreview
        }
    }

    /// Preview text adjusted for sensitive card types. CC and SSN get
    /// masked so the picker never displays a full number on screen — the
    /// last 4 digits are kept so the user can still tell two cards apart.
    /// Copy-back is untouched (the pasteboard write uses `item.text`).
    private var displayPreview: String {
        switch item.card {
        case .creditCard: return SensitiveMask.creditCard(item.preview)
        case .ssn:        return SensitiveMask.ssn(item.preview)
        default:          return item.preview
        }
    }

    /// `item.preview` for images is "📷 1920×1080" — strip the emoji.
    private var dimensionsFromPreview: String {
        item.preview
            .replacingOccurrences(of: "📷 ", with: "")
            .replacingOccurrences(of: "📷", with: "")
    }

    private var firstFileURL: URL? {
        guard let urls = item.fileURLs, let first = urls.first else { return nil }
        return URL(string: first)
    }

    private var primaryFileName: String {
        firstFileURL?.lastPathComponent ?? item.preview
    }

    private var extraFilesSuffix: String? {
        guard let urls = item.fileURLs, urls.count > 1 else { return nil }
        return "+\(urls.count - 1) more"
    }

    private var parentDirDisplay: String? {
        guard let url = firstFileURL else { return nil }
        let parent = url.deletingLastPathComponent().path
        // Replace $HOME with ~ for compactness.
        let home = NSHomeDirectory()
        if parent.hasPrefix(home) {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    // MARK: - Icons

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        switch item.card {
        case .text:
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let data = item.thumbnail, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .fileURL:
            workspaceIcon(size: size)
        case .color:
            if let raw = item.text, let parsed = parseColor(raw) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: parsed.color))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondary)
            }
        case .url:
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .phone:
            Image(systemName: "phone")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .email:
            Image(systemName: "envelope")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .creditCard:
            Image(systemName: "creditcard")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ssn:
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .address:
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .command:
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Real Finder icon for the file behind this clip (PDF → PDF icon,
    /// .app → app icon, image file → image preview). Falls back to a
    /// generic doc symbol when the file is gone or no URL is stored.
    @ViewBuilder
    private func workspaceIcon(size: CGFloat) -> some View {
        if let url = firstFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Coarse relative time — minute-grain at finest. Seconds-precision in
    /// a clipboard list is noise: knowing "5 min ago" vs "5 min 12 s ago"
    /// changes nothing the user does next.
    static func coarseRelative(_ d: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(d))
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60)) min ago" }
        if delta < 86_400 { return "\(Int(delta / 3600)) hr ago" }
        if delta < 604_800 { return "\(Int(delta / 86_400)) d ago" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: d)
    }
}

// AppKit-backed search field. Using NSSearchField (not a manual keyDown
// hook) buys us full IME support — Zhuyin/Pinyin marked-text composition,
// candidate windows, dead keys — plus the standard editing shortcuts
// (⌘A select-all, ⌘C/⌘V/⌘X, ⌥←/→, etc.) for free.
//
// We intercept only the four navigation selectors via doCommandBy and
// route them to the view model; everything else falls through to the
// text field so AppKit's text editing pipeline stays intact.
private struct SearchField: NSViewRepresentable {
    @ObservedObject var viewModel: PickerViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 13)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        // NSSearchField ships with a built-in × clear button — keep it.
        if let cell = field.cell as? NSSearchFieldCell {
            cell.cancelButtonCell?.target = context.coordinator
            cell.cancelButtonCell?.action = #selector(Coordinator.clearTapped)
        }
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        // Mirror external query mutations (e.g. Esc → clearQuery, or a fresh
        // reload on re-open) back into the field without breaking IME.
        if field.stringValue != viewModel.query {
            field.stringValue = viewModel.query
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let viewModel: PickerViewModel
        init(viewModel: PickerViewModel) { self.viewModel = viewModel }

        @objc func clearTapped() {
            viewModel.clearQuery()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            viewModel.setQuery(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                viewModel.moveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                viewModel.moveDown(); return true
            case #selector(NSResponder.moveLeft(_:)):
                return viewModel.handleArrowKey(left: true)
            case #selector(NSResponder.moveRight(_:)):
                return viewModel.handleArrowKey(left: false)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                viewModel.pickCurrent(); return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                // While the user is editing the query, ⌫ must keep editing
                // the text. Only when the field is empty do we repurpose it
                // as "delete the selected clip" — that matches what the
                // user expects from Finder / Mail row deletion.
                if viewModel.query.isEmpty {
                    viewModel.deleteSelected()
                    return true
                }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                // Two-stage Esc: first press clears the filter + collapses
                // the bar back to the default look; second press closes the
                // picker. clearQuery is a no-op for both when already empty
                // & inactive, so we just check those flags directly.
                if viewModel.query.isEmpty && !viewModel.searchActive {
                    viewModel.cancel()
                } else {
                    viewModel.clearQuery()
                }
                return true
            default:
                return false
            }
        }
    }
}

// Subclass exists so we can hold focus across panel show/hide cycles.
// IME activation lives in PickerPanel's local NSEvent monitor (the field
// editor — not this class — receives keyDown when focus is here).
final class SearchTextField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusSelf),
            name: NSWindow.didBecomeKeyNotification,
            object: w
        )
        DispatchQueue.main.async { [weak self] in self?.focusSelf() }
    }

    @objc private func focusSelf() {
        window?.makeFirstResponder(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

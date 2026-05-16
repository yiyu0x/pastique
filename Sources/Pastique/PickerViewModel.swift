import Foundation
import Combine

/// Orthogonal-to-sort/query dimension: which card kinds to show. `all` lets
/// every row through; the rest narrow by `ClipItem.card`. Resets to `.all`
/// on every picker re-open — it's a *current-session* filter, not a setting.
enum KindFilter: String, CaseIterable {
    case all, text, link, command, image, file, color, personal

    var label: String {
        switch self {
        case .all:      return "All"
        case .text:     return "Text"
        case .link:     return "Link"
        case .command:  return "Command"
        case .image:    return "Image"
        case .file:     return "File"
        case .color:    return "Color"
        case .personal: return "Personal"
        }
    }

    var symbol: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .text:     return "doc.text"
        case .link:     return "globe"
        case .command:  return "terminal"
        case .image:    return "photo"
        case .file:     return "doc"
        case .color:    return "paintpalette"
        case .personal: return "person.text.rectangle"
        }
    }

    /// Does an item match this filter? `.all` always passes. `.personal`
    /// is the umbrella for every detected PII/financial card type (phone,
    /// email, CC, SSN, address) — we roll them up so the chip row stays
    /// bounded even as new detectors land later.
    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all:      return true
        case .text:     return item.card == .text
        case .link:     return item.card == .url
        case .command:  return item.card == .command
        case .image:    return item.card == .image
        case .file:     return item.card == .fileURL
        case .color:    return item.card == .color
        case .personal: return item.isPersonal
        }
    }
}

@MainActor
final class PickerViewModel: ObservableObject {
    // Items currently shown (after filter). Bound directly by the view.
    @Published var items: [ClipItem] = []
    @Published var selectedIndex: Int = 0
    @Published var sortOrder: SortOrder = Settings.sortOrder
    @Published var viewStyle: ViewStyle = Settings.viewStyle
    @Published var query: String = ""
    /// Active kind filter. Always reset to `.all` on reload so the picker
    /// opens unfiltered — the previous filter is a stale intent by the next
    /// hotkey press.
    @Published var kindFilter: KindFilter = .all
    /// Kinds with at least one item in the current unfiltered set. Used by
    /// the UI to hide chips for empty buckets — no point offering "Image"
    /// when the user has never copied one.
    @Published var availableFilters: [KindFilter] = [.all]
    // True once the user has started typing (or the query is non-empty).
    // Drives the search-bar's visibility — the bar lives in the view tree
    // even when collapsed (height 0), so IME composition has a real text
    // widget to attach to. Flipping this to true *synchronously* on the
    // first printable keystroke lets the bar expand before the candidate
    // window appears, so marked text never renders inside the collapsed
    // (invisible) region.
    @Published var searchActive: Bool = false
    // Bumped only when selection moves via keyboard (or reload). Hover changes
    // selectedIndex but NOT this — so the mouse can re-highlight rows without
    // the list scrolling itself out from under the cursor.
    @Published var scrollTick: Int = 0

    private let store: ClipStore
    // Full unfiltered set from the last fetch. `items` is derived from this.
    private var allItems: [ClipItem] = []

    var onPick: (ClipItem) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(store: ClipStore) {
        self.store = store
    }

    func reload() {
        // Pick up any setting changes made via the menubar between shows.
        sortOrder = Settings.sortOrder
        viewStyle = Settings.viewStyle
        query = ""
        searchActive = false
        kindFilter = .all
        allItems = (try? store.fetch(sortBy: sortOrder)) ?? []
        recomputeAvailableFilters()
        applyFilter()
    }

    func setSortOrder(_ s: SortOrder) {
        Settings.sortOrder = s
        sortOrder = s
        allItems = (try? store.fetch(sortBy: s)) ?? []
        recomputeAvailableFilters()
        applyFilter()
    }

    func toggleSortOrder() {
        setSortOrder(sortOrder == .recency ? .frequency : .recency)
    }

    func setViewStyle(_ v: ViewStyle) {
        Settings.viewStyle = v
        viewStyle = v
    }

    // MARK: - Search

    /// Single setter — the search field is the source of truth for the text;
    /// this just mirrors it and reapplies the filter.
    func setQuery(_ s: String) {
        guard query != s else { return }
        query = s
        if !s.isEmpty { searchActive = true }
        applyFilter()
    }

    /// Called by the search field on the first printable keystroke. Expands
    /// the bar before IME composition begins so marked text is visible.
    func activateSearch() {
        if !searchActive { searchActive = true }
    }

    /// Clear filter AND collapse the search bar back to the picker's
    /// default look. One Esc clears + collapses; a second Esc closes.
    func clearQuery() {
        let wasEmpty = query.isEmpty
        if !wasEmpty {
            query = ""
            applyFilter()
        }
        searchActive = false
    }

    /// Route a horizontal arrow keystroke. Returns `true` if we consumed it
    /// (filter cycled), `false` if the caller should let it fall through to
    /// the text field's caret movement. The "empty query == browse mode"
    /// rule lives here so the AppKit Coordinator stays a thin delegator and
    /// the rule itself is unit-testable.
    func handleArrowKey(left: Bool) -> Bool {
        guard query.isEmpty else { return false }
        cycleKindFilter(forward: !left)
        return true
    }

    /// Cycle the active filter chip. Only iterates over `availableFilters`
    /// so empty buckets never appear in the rotation — `←/→` lands on
    /// something that will actually narrow results.
    func cycleKindFilter(forward: Bool) {
        guard availableFilters.count > 1 else { return }
        let idx = availableFilters.firstIndex(of: kindFilter) ?? 0
        let next = forward
            ? (idx + 1) % availableFilters.count
            : (idx - 1 + availableFilters.count) % availableFilters.count
        setKindFilter(availableFilters[next])
    }

    func setKindFilter(_ f: KindFilter) {
        guard kindFilter != f else { return }
        kindFilter = f
        applyFilter()
    }

    private func recomputeAvailableFilters() {
        var present: Set<KindFilter> = [.all]
        for item in allItems {
            switch item.card {
            case .text:    present.insert(.text)
            case .url:     present.insert(.link)
            case .image:   present.insert(.image)
            case .fileURL: present.insert(.file)
            case .color:   present.insert(.color)
            case .command: present.insert(.command)
            case .phone, .email, .creditCard, .ssn, .address:
                present.insert(.personal)
            }
        }
        // Preserve the canonical order from KindFilter.allCases.
        availableFilters = KindFilter.allCases.filter { present.contains($0) }
        // Selected bucket may have just disappeared (e.g. after sort refetch).
        if !availableFilters.contains(kindFilter) {
            kindFilter = .all
        }
    }

    private func applyFilter() {
        let q = query.lowercased()
        items = allItems.filter { item in
            kindFilter.matches(item) && (q.isEmpty || Self.matches(item, q))
        }
        selectedIndex = 0
        scrollTick &+= 1
    }

    /// Substring match. Text → body. Files → decoded path (so users can search
    /// by filename or parent dir). Images aren't indexed — there's nothing
    /// textual to match against until we add OCR.
    private static func matches(_ item: ClipItem, _ q: String) -> Bool {
        switch item.kind {
        case .text:
            return (item.text ?? "").lowercased().contains(q)
        case .fileURL:
            return (item.fileURLs ?? []).contains { urlStr in
                if let url = URL(string: urlStr) {
                    return url.path.lowercased().contains(q)
                }
                return urlStr.lowercased().contains(q)
            }
        case .image:
            return false
        }
    }

    // MARK: - Navigation

    func moveUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        scrollTick &+= 1
    }

    func moveDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        scrollTick &+= 1
    }

    func pickCurrent() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        store.recordUse(id: item.id)
        onPick(item)
    }

    func pick(_ item: ClipItem) {
        store.recordUse(id: item.id)
        onPick(item)
    }

    func cancel() {
        onCancel()
    }
}

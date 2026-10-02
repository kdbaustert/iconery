import AppKit
import CryptoKit
import Observation
import UniformTypeIdentifiers

/// The icon library on disk, and the state of the one window that browses it.
@MainActor
@Observable
final class Library {
    private(set) var sets: [IconSet] = []
    private(set) var icons: [Icon] = []
    private(set) var licenses = License.starters

    // MARK: Window state
    // One window, so what it shows lives here rather than in a second object that the menu
    // commands would also have to reach.

    var sidebar: SidebarItem? = .all {
        didSet { preferences.sidebarItem = sidebar?.stored }
    }
    var expandedSets: Set<UUID> = [] {
        didSet { preferences.expandedSetIDs = expandedSets.map(\.uuidString).sorted() }
    }
    var selection: Set<UUID> = []
    var searchText = ""
    var export = ExportOptions.load() {
        didSet { export.save() }
    }
    /// The user's own export presets; the built-in ones are ExportPreset.builtIn.
    private(set) var presets = ExportPreset.loadSaved() {
        didSet { ExportPreset.save(presets) }
    }
    var naming: Naming?
    var draftName = ""
    /// Set after an edit that can re-sort the grid, like a rename under name sorting, so the
    /// grid scrolls to keep the icon in view. The grid clears it once it has scrolled.
    var revealed: UUID?
    var pendingDeletion: Deletion?

    /// Alerts waiting their turn, oldest first. Two IconJar libraries dropped together, or a
    /// scheduled backup failing while another alert is up, each get shown rather than the last one
    /// replacing the rest.
    private var notices: [Notice] = []

    /// The alert showing now. Setting one queues it behind any already waiting; setting nil, as
    /// dismissing the alert does, moves on to the next.
    var notice: Notice? {
        get { notices.first }
        set {
            if let newValue {
                notices.append(newValue)
                return
            }
            guard !notices.isEmpty else { return }
            let waiting = notices.dropFirst()
            notices = []
            // A turn of the run loop later, so the closing alert has gone before the next opens.
            guard !waiting.isEmpty else { return }
            Task { notices.insert(contentsOf: waiting, at: min(1, notices.count)) }
        }
    }

    @ObservationIgnored private var anchor: UUID?
    @ObservationIgnored private var draggingIDs: Set<UUID>?
    /// Each dragged icon's Recently Used date from before the drag stamped it, so a drop that
    /// turns out to be a move inside the app can put it back.
    @ObservationIgnored private var draggedLastUsed: [UUID: Date?] = [:]
    private let images = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, CGImage>()
    /// nil inside means "looked, and it isn't one colour", so it is never worked out twice.
    @ObservationIgnored private var singleColors: [String: SIMD3<Double>?] = [:]
    /// Set when library.json is there but can't be read, so nothing saves an empty library over it.
    @ObservationIgnored private var indexUnreadable = false
    /// Why the last scheduled backup failed, kept until one succeeds.
    @ObservationIgnored private var lastScheduledFailure: String?

    // What the views would otherwise work out again on every redraw: one sort of a 9,000-icon
    // library takes 28 ms (measured), and a click used to run three. Each is kept with what it was
    // made from and rebuilt when that differs. An array still sharing storage with the kept one
    // compares equal without looking at its elements, so an unchanged library costs nothing.
    @ObservationIgnored private var cachedTree: (sets: [IconSet], children: [UUID?: [IconSet]])?
    @ObservationIgnored
    private var cachedOrder: (icons: [Icon], sort: GridSort, descending: Bool, sorted: [Icon])?
    @ObservationIgnored
    private var cachedCounts: (icons: [Icon], sets: [IconSet], bySet: [UUID: Int])?
    @ObservationIgnored private var cachedVisible: (key: VisibleKey, icons: [Icon])?

    /// Changes when the library is moved or switched in Settings.
    private(set) var folder: URL
    /// Where Back Up Now writes.
    private(set) var backupFolder: URL
    private(set) var lastBackup: Date?
    var iconsFolder: URL { folder.appending(path: "Icons", directoryHint: .isDirectory) }
    private var indexURL: URL { folder.appending(path: "library.json") }

    let preferences: Preferences
    /// Where Export writes without asking; nil asks each time.
    private(set) var exportFolder: URL?
    private(set) var isBackingUp = false
    @ObservationIgnored private var duplicates: DuplicateFinder?

    /// Opens the library chosen in Settings, or the default one. Passing `folder` opens that
    /// library instead and ignores the remembered one, which tests rely on, as they do on passing
    /// their own `preferences`.
    init(folder: URL? = nil, preferences: Preferences = .shared) {
        self.preferences = preferences
        // Without limits these only shed under memory pressure, and a 256 pt grid keeps a 1 MB
        // thumbnail per icon scrolled past.
        thumbnails.totalCostLimit = 256 * 1024 * 1024
        images.countLimit = 500
        exportFolder = Self.storedURL(Self.exportKey)
        let remembered = Self.storedURL(Self.libraryKey)
        self.folder = folder ?? remembered ?? Self.defaultFolder
        backupFolder = Self.storedURL(Self.backupKey) ?? Self.defaultBackupFolder
        lastBackup = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date
        load()
        // Where the window left off, with anything pointing at a set that has gone dropped.
        let known = Set(sets.map(\.id))
        let rememberedSidebar = preferences.sidebarItem.flatMap(SidebarItem.init(stored:))
        if case .set(let id) = rememberedSidebar, !known.contains(id) {
            sidebar = .all
        } else {
            sidebar = rememberedSidebar ?? .all
        }
        expandedSets = Set(preferences.expandedSetIDs.compactMap(UUID.init(uuidString:)))
            .intersection(known)
        let hadLocation = UserDefaults.standard.data(forKey: Self.libraryKey) != nil
        if folder == nil, hadLocation, remembered == nil {
            // The location is kept, so the library opens again once its drive is back.
            notice = Notice(
                title: "Your library couldn't be found",
                message: "It may be on a drive that isn't connected. Iconery opened the default "
                    + "library for now. Choose Settings ▸ Switch to open yours again."
            )
        }
        try? FileManager.default.removeItem(at: Exporter.dragRoot)
        try? FileManager.default.removeItem(at: Self.openRoot)
    }

    // MARK: Persistence

    private struct Index: Codable {
        var sets: [IconSet]
        var icons: [Icon]
        /// Optional: libraries saved before licences existed start with the starter set.
        var licenses: [License]?
    }

    private func load() {
        indexUnreadable = false
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch CocoaError.fileReadNoSuchFile {
            return  // a new library
        } catch {
            // There but unreadable: a drive that dropped off, an iCloud file not yet downloaded, a
            // permissions change. The next save would write an empty library over it.
            indexUnreadable = true
            notice = Notice(
                title: "The library could not be read",
                message: "Changes won't be saved until it can be, so nothing is lost. Quit and "
                    + "open Iconery again once it's available. \(error.localizedDescription)"
            )
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let index = try decoder.decode(Index.self, from: data)
            sets = index.sets
            icons = index.icons
            licenses = index.licenses ?? License.starters
            repairSetTree()
        } catch {
            // Set an unreadable index aside before anything saves an empty library over it.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = folder.appending(path: "library-unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: indexURL, to: aside)
                notice = Notice(
                    title: "The library could not be read",
                    message: "It was moved to \(aside.path(percentEncoded: false)) and an empty "
                        + "library opened in its place. \(error.localizedDescription)"
                )
            } catch let moveError {
                indexUnreadable = true
                notice = Notice(
                    title: "The library could not be read",
                    message: "Changes won't be saved, so nothing is written over it. "
                        + "\(error.localizedDescription) \(moveError.localizedDescription)"
                )
            }
        }
    }

    /// Makes every set reachable from the top level, or it would never be drawn: a set whose
    /// parent is gone is lifted to the top, and so is the set that closes a loop of parents
    /// (A inside B inside A), which only a damaged or hand-edited file could hold.
    private func repairSetTree() {
        let ids = Set(sets.map(\.id))
        for i in sets.indices where sets[i].parentID.map({ !ids.contains($0) }) == true {
            sets[i].parentID = nil
        }
        var parents = Dictionary(sets.map { ($0.id, $0.parentID) }) { first, _ in first }
        for i in sets.indices {
            var seen: Set<UUID> = []
            var current = sets[i].parentID
            while let id = current, seen.insert(id).inserted {
                if id == sets[i].id {
                    sets[i].parentID = nil
                    parents.updateValue(nil, forKey: id)
                    break
                }
                current = parents[id] ?? nil
            }
        }
    }

    private func save() {
        guard !indexUnreadable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder.encode(Index(sets: sets, icons: icons, licenses: licenses))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            notice = Notice(
                title: "The library could not be saved", message: error.localizedDescription
            )
        }
    }

    // MARK: Queries

    func children(of parent: UUID?) -> [IconSet] {
        if cachedTree?.sets != sets {
            let children = Dictionary(grouping: sets, by: \.parentID).mapValues {
                $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            cachedTree = (sets, children)
        }
        return cachedTree?.children[parent] ?? []
    }

    /// Every set, depth first, with its full path ("UI › Arrows") for menus and pickers, where a
    /// bare name could belong to several sets.
    var setPaths: [(set: IconSet, path: String)] {
        var result: [(set: IconSet, path: String)] = []
        func visit(_ parent: UUID?, prefix: String) {
            for set in children(of: parent) {
                let path = prefix.isEmpty ? set.name : "\(prefix) › \(set.name)"
                result.append((set, path))
                visit(set.id, prefix: path)
            }
        }
        visit(nil, prefix: "")
        return result
    }

    /// `id` and every set nested anywhere beneath it.
    func subtree(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var pending = [id]
        while let current = pending.popLast() {
            // Only sets not seen yet, so even a loop of parents comes to an end.
            for child in children(of: current) where result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    /// A set shows its own icons and those of every set inside it, as IconJar's groups do.
    func icons(in item: SidebarItem?) -> [Icon] {
        switch item {
        case .all, nil:
            sortedIcons
        case .starred:
            sortedIcons.filter(\.starred)
        case .recent:
            Array(
                icons.filter { $0.lastUsed != nil }
                    .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
                    .prefix(preferences.recentLimit)
            )
        case .set(let id):
            sortedIcons.filter(isInside(id))
        }
    }

    /// The whole library in the grid's order. Filtering this keeps the order, so nothing sorts
    /// again until an icon or the order in Settings changes.
    private var sortedIcons: [Icon] {
        let sort = preferences.sort
        let descending = preferences.sortDescending
        if let cachedOrder, cachedOrder.sort == sort, cachedOrder.descending == descending,
           cachedOrder.icons == icons {
            return cachedOrder.sorted
        }
        let result = sorted(icons)
        cachedOrder = (icons, sort, descending, result)
        return result
    }

    /// In the key the toolbar's sort menu picks. The direction flips only that key: ties, like
    /// icons of one file type or never used, read by name A to Z either way.
    private func sorted(_ icons: [Icon]) -> [Icon] {
        let descending = preferences.sortDescending
        func ordered<Key: Comparable>(_ key: (Icon) -> Key) -> [Icon] {
            icons.sorted {
                let (a, b) = (key($0), key($1))
                return a == b ? Self.byName($0, $1) : (descending ? a > b : a < b)
            }
        }
        switch preferences.sort {
        case .name:
            let ascending = icons.sorted(by: Self.byName)
            return descending ? Array(ascending.reversed()) : ascending
        case .fileType:
            return ordered { $0.kind.rawValue }
        case .dateAdded:
            return ordered(\.added)
        case .dateUsed:
            return ordered { $0.lastUsed ?? .distantPast }
        }
    }

    /// Built once per call, so filtering a large library walks the set tree once, not per icon.
    private func isInside(_ setID: UUID) -> (Icon) -> Bool {
        let tree = subtree(of: setID)
        return { tree.contains($0.setID) }
    }

    func count(in item: SidebarItem) -> Int {
        switch item {
        case .all: icons.count
        case .starred: icons.count(where: \.starred)
        case .recent: min(icons.count { $0.lastUsed != nil }, preferences.recentLimit)
        case .set(let id): setCounts[id] ?? 0
        }
    }

    /// Every set's count, nested sets' icons included, worked out for all of them at once rather
    /// than with a walk of the library per sidebar row.
    private var setCounts: [UUID: Int] {
        if let cachedCounts, cachedCounts.icons == icons, cachedCounts.sets == sets {
            return cachedCounts.bySet
        }
        var own: [UUID: Int] = [:]
        for icon in icons { own[icon.setID, default: 0] += 1 }
        var bySet: [UUID: Int] = [:]
        for set in sets {
            bySet[set.id] = subtree(of: set.id).reduce(0) { $0 + own[$1, default: 0] }
        }
        cachedCounts = (icons, sets, bySet)
        return bySet
    }

    /// Everything the grid's contents depend on.
    private struct VisibleKey: Equatable {
        var icons: [Icon]
        var sets: [IconSet]
        var sidebar: SidebarItem?
        var searchText: String
        var sort: GridSort
        var descending: Bool
        var recentLimit: Int
        var scope: SearchScope
    }

    var visibleIcons: [Icon] {
        let scope = SearchScope(
            tags: preferences.searchesTags, setNames: preferences.searchesSetNames,
            descriptions: preferences.searchesDescriptions
        )
        let key = VisibleKey(
            icons: icons, sets: sets, sidebar: sidebar, searchText: searchText,
            sort: preferences.sort, descending: preferences.sortDescending,
            recentLimit: preferences.recentLimit, scope: scope
        )
        if let cachedVisible, cachedVisible.key == key { return cachedVisible.icons }
        var shown = icons(in: sidebar)
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let paths = Dictionary(uniqueKeysWithValues: setPaths.map { ($0.set.id, $0.path) })
            shown = shown.filter {
                iconMatches($0, query: searchText, setPath: paths[$0.setID] ?? "", scope: scope)
            }
        }
        cachedVisible = (key, shown)
        return shown
    }

    var selectedIcons: [Icon] {
        sortedIcons.filter { selection.contains($0.id) }
    }

    var currentSetID: UUID? {
        guard case .set(let id) = sidebar else { return nil }
        return id
    }

    func title(for item: SidebarItem?) -> String {
        switch item {
        case .all, nil: "All Icons"
        case .recent: "Recently Used"
        case .starred: "Starred"
        case .set(let id): sets.first { $0.id == id }?.name ?? "Set"
        }
    }

    /// What a menu action on `icon` applies to: the whole selection when the icon is part of it,
    /// otherwise the icon alone, as in Finder.
    func targets(for icon: Icon) -> Set<UUID> {
        selection.contains(icon.id) ? selection : [icon.id]
    }

    func fileURL(for icon: Icon) -> URL {
        iconsFolder.appending(path: icon.fileName)
    }

    private static func byName(_ a: Icon, _ b: Icon) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Images

    func image(for icon: Icon) -> NSImage? {
        let key = icon.fileName as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: fileURL(for: icon)) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// A raster for showing `icon` at `points`, from a few fixed sizes so dragging the zoom slider
    /// reuses them instead of redrawing every icon at every step.
    func thumbnail(
        for icon: Icon, points: Double, scale: Double, onDark: Bool = false,
        improveContrast: Bool = false
    ) -> CGImage? {
        let needed = Int((points * scale).rounded(.up))
        let pixels = [32, 64, 128, 256, 512].first { $0 >= needed } ?? 512
        let fix = improveContrast ? contrastFix(for: icon, onDark: onDark) : nil
        let variant = fix == nil ? "" : (onDark ? "-light" : "-dark")
        let key = "\(icon.fileName)@\(pixels)\(variant)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = image(for: icon), var raster = Raster.render(image, pixels: pixels) else {
            return nil
        }
        if let fix, let tinted = Raster.tinted(raster, fix) { raster = tinted }
        thumbnails.setObject(raster, forKey: key, cost: raster.bytesPerRow * raster.height)
        return raster
    }

    /// The colour to draw `icon` in so it stands out from the background, or nil when it already
    /// does.
    /// Only one-colour SVGs qualify, and only on screen; exports never pass through here.
    ///
    /// A grey or black icon gets WCAG's 3:1 minimum for graphics, since it has no colour to lose.
    /// A coloured one is only rescued from near-invisibility, below 1.5:1. Measured on the user's
    /// DevIcon set: at 3:1 React's cyan (1.63), Node's green (1.96) and Bulma's teal (1.97) all
    /// turned black on a white background, though plainly visible and part of the logo.
    /// JavaScript's yellow (1.43) is the one that really vanishes.
    private func contrastFix(for icon: Icon, onDark: Bool) -> CGColor? {
        guard icon.kind == .svg, let color = singleColor(of: icon) else { return nil }
        let shade = onDark ? BackgroundShade.dark : BackgroundShade.light
        let background = Raster.luminance(SIMD3(repeating: shade))
        let isGrey = color.max() - color.min() < 0.15
        let minimum = isGrey ? 3.0 : 1.5
        guard Raster.contrast(Raster.luminance(color), background) < minimum else { return nil }
        return onDark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
    }

    /// Worked out once per icon from a small raster, and kept, since every thumbnail size asks.
    private func singleColor(of icon: Icon) -> SIMD3<Double>? {
        if let known = singleColors[icon.fileName] { return known }
        let color = image(for: icon)
            .flatMap { Raster.render($0, pixels: 64) }
            .flatMap(Raster.singleColor)
        singleColors.updateValue(color, forKey: icon.fileName)
        return color
    }

    func dimensions(of icon: Icon) -> String {
        guard let image = image(for: icon) else { return "Unknown" }
        if icon.kind != .svg,
           let largest = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            return "\(largest.pixelsWide) × \(largest.pixelsHigh) px"
        }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    func fileSize(of icon: Icon) -> String {
        let path = fileURL(for: icon).path(percentEncoded: false)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Selection

    func click(_ id: UUID, in visible: [Icon], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let anchor,
                  let from = visible.firstIndex(where: { $0.id == anchor }),
                  let to = visible.firstIndex(where: { $0.id == id }) {
            selection = Set(visible[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    // MARK: Sets

    @discardableResult
    func createSet(named name: String, inside parent: UUID? = nil) -> IconSet {
        let set = makeSet(named: name, inside: parent)
        save()
        return set
    }

    /// Adds a set without saving, for an import that creates many and saves once at the end.
    private func makeSet(named name: String, inside parent: UUID?, id: UUID = UUID()) -> IconSet {
        let set = IconSet(id: id, name: uniqueSetName(name, inside: parent), parentID: parent)
        sets.append(set)
        if let parent { expandedSets.insert(parent) }
        return set
    }

    func renameSet(_ id: UUID, to name: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].name = name
        save()
    }

    /// Moves a set, with everything inside it, under `parent`, or to the top level when nil. A set
    /// can't move into itself or into a set inside it.
    func moveSet(_ id: UUID, into parent: UUID?) {
        if let parent, subtree(of: id).contains(parent) { return }
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].parentID = parent
        if let parent { expandedSets.insert(parent) }
        save()
    }

    func beginNewSet(inside parent: UUID? = nil) {
        draftName = ""
        naming = .newSet(parent: parent)
    }

    func beginRename(_ set: IconSet) {
        draftName = set.name
        naming = .renameSet(set.id)
    }

    func beginRename(_ icon: Icon) {
        draftName = icon.name
        naming = .renameIcon(icon.id)
    }

    func finishNaming(_ naming: Naming) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch naming {
        case .newSet(let parent): sidebar = .set(createSet(named: name, inside: parent).id)
        case .renameSet(let id): renameSet(id, to: name)
        case .renameIcon(let id): rename(id, to: name)
        }
    }

    func requestDelete(_ set: IconSet) {
        pendingDeletion = .set(
            set, iconCount: count(in: .set(set.id)), setCount: subtree(of: set.id).count - 1
        )
    }

    func perform(_ deletion: Deletion) {
        switch deletion {
        case .set(let set, _, _):
            let tree = subtree(of: set.id)
            removeIcons(Set(icons.filter { tree.contains($0.setID) }.map(\.id)))
            sets.removeAll { tree.contains($0.id) }
            expandedSets.subtract(tree)
            if let current = currentSetID, tree.contains(current) { sidebar = .all }
        case .icons(let ids):
            removeIcons(ids)
        }
        save()
    }

    /// Asks first, unless Settings says not to.
    func requestDeleteIcons(_ ids: Set<UUID>) {
        if preferences.confirmsIconDeletion {
            pendingDeletion = .icons(ids)
        } else {
            perform(.icons(ids))
        }
    }

    private func removeIcons(_ ids: Set<UUID>) {
        for icon in icons where ids.contains(icon.id) {
            try? FileManager.default.removeItem(at: fileURL(for: icon))
        }
        icons.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Unique among its siblings only: "Outline" may sit inside both "Lucide" and "Heroicons".
    private func uniqueSetName(_ name: String, inside parent: UUID?) -> String {
        let taken = Set(sets.filter { $0.parentID == parent }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Icons

    func update(_ ids: Set<UUID>, _ change: (inout Icon) -> Void) {
        for index in icons.indices where ids.contains(icons[index].id) {
            change(&icons[index])
        }
        save()
    }

    func move(_ ids: Set<UUID>, to setID: UUID) {
        update(ids) { $0.setID = setID }
    }

    /// Whether the menu bar offers Unstar: only when every selected icon is starred.
    var selectionAllStarred: Bool {
        let chosen = icons.filter { selection.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.starred)
    }

    func clearRecents() {
        update(Set(icons.filter { $0.lastUsed != nil }.map(\.id))) { $0.lastUsed = nil }
    }

    func toggleStar(_ ids: Set<UUID>) {
        let star = !icons.filter { ids.contains($0.id) }.allSatisfy(\.starred)
        update(ids) { $0.starred = star }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update([id]) { $0.name = name }
        revealed = id
    }

    func setTags(_ id: UUID, _ tags: [String]) {
        let tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The tag field reports whenever it loses focus, changed or not.
        guard icons.first(where: { $0.id == id })?.tags != tags else { return }
        update([id]) { $0.tags = tags }
    }

    func setInfo(_ id: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update([id]) { $0.info = text.isEmpty ? nil : text }
    }

    func setLicense(_ ids: Set<UUID>, _ licenseID: UUID?) {
        update(ids) { $0.licenseID = licenseID }
    }

    func license(of icon: Icon) -> License? {
        licenses.first { $0.id == icon.licenseID }
    }

    /// Selects the icon `offset` places from `id` in the grid, for the inspector's arrows.
    func selectNeighbour(of id: UUID, by offset: Int) {
        let visible = visibleIcons
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset)
        else { return }
        selection = [visible[index + offset].id]
        anchor = visible[index + offset].id
    }

    /// The grid's arrow keys: from the icon last clicked, or the first icon when none is
    /// selected. Returns the icon selected, for the grid to scroll to.
    @discardableResult
    func moveSelection(by offset: Int) -> UUID? {
        let current = anchor.flatMap { selection.contains($0) ? $0 : nil }
            ?? selectedIcons.first?.id
        if let current {
            selectNeighbour(of: current, by: offset)
        } else if let first = visibleIcons.first {
            selection = [first.id]
            anchor = first.id
        }
        return anchor
    }

    func selectAll() {
        selection = Set(visibleIcons.map(\.id))
    }

    // MARK: Licences

    @discardableResult
    func addLicense() -> License {
        let license = License(name: "New License", url: "")
        licenses.append(license)
        save()
        return license
    }

    func updateLicense(_ license: License) {
        guard let index = licenses.firstIndex(where: { $0.id == license.id }) else { return }
        licenses[index] = license
        save()
    }

    /// Icons that carried the licence go back to having none.
    func removeLicense(_ id: UUID) {
        licenses.removeAll { $0.id == id }
        for index in icons.indices where icons[index].licenseID == id {
            icons[index].licenseID = nil
        }
        save()
    }

    // MARK: Open In

    /// Where Open In puts its copies. Emptied at launch.
    static let openRoot = FileManager.default.temporaryDirectory
        .appending(path: "IconeryOpen", directoryHint: .isDirectory)

    /// Copies for Quick Look, named after the icons so the panel's title is the name rather
    /// than the library's id-named file, in the grid's order so its arrows walk the selection
    /// as the grid shows it. Previewing isn't using, so Recently Used is left alone.
    func quickLookURLs(for ids: Set<UUID>) -> [URL] {
        let shown = visibleIcons.filter { ids.contains($0.id) }
        let folder = Self.openRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let files: [ExportFile] = shown.compactMap { icon in
            guard let data = try? Data(contentsOf: fileURL(for: icon)) else { return nil }
            return ExportFile(
                name: "\(Exporter.safeFileName(icon.name)).\(icon.kind.rawValue)", data: data
            )
        }
        return (try? Exporter.write(files, to: folder)) ?? []
    }

    /// Opens a copy named after the icon, so the other app shows its name rather than the
    /// library's id-named file, and nothing saved there can change the library. `app` nil uses
    /// the file type's default app.
    func open(_ icon: Icon, with app: URL?) {
        let folder = Self.openRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let name = "\(Exporter.safeFileName(icon.name)).\(icon.kind.rawValue)"
        let copy = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL(for: icon), to: copy)
        } catch {
            notice = Notice(
                title: "“\(icon.name)” could not be opened", message: error.localizedDescription
            )
            return
        }
        if let app {
            NSWorkspace.shared.open(
                [copy], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(copy)
        }
        update([icon.id]) { $0.lastUsed = .now }
    }

    // MARK: Import

    struct ImportReport {
        var imported = 0
        var skipped: [String] = []
        /// Files left out because the library already had them.
        var duplicates = 0
        /// IconJar icons left out because its records of them lack a file or a set.
        var incomplete = 0
        /// The sets folders became at the top of the import, then every set it made.
        var createdSets: [UUID] = []
        var allCreated: [UUID] = []
    }

    /// A folder becomes a set named after it, inside `target` when there is one, and each
    /// subfolder holding icons becomes a set inside that, mirroring the tree on disk. Loose files
    /// go into `target`, or into "Unsorted" when no set is selected.
    @discardableResult
    func importItems(_ urls: [URL], into target: UUID?) -> ImportReport {
        var report = ImportReport()
        duplicates = preferences.skipsDuplicates ? DuplicateFinder(files: icons.map(fileURL)) : nil
        defer { duplicates = nil }
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard let folder = Self.scan(url) else {
                    report.skipped.append("\(url.lastPathComponent) (no icon files inside)")
                    continue
                }
                report.createdSets.append(importFolder(folder, inside: target, report: &report))
            } else {
                add(url, to: target ?? looseFilesSetID(), report: &report)
            }
        }
        // A folder whose every file was already here would leave its set standing empty.
        let empty = Set(report.allCreated.filter { count(in: .set($0)) == 0 })
        sets.removeAll { empty.contains($0.id) }
        expandedSets.subtract(empty)
        report.createdSets.removeAll { empty.contains($0) }
        save()
        return report
    }

    private struct ScannedFolder {
        var url: URL
        var files: [URL]
        var subfolders: [ScannedFolder]
    }

    /// nil when no icon file lives anywhere beneath `folder`, so empty branches never become
    /// empty sets.
    private static func scan(_ folder: URL) -> ScannedFolder? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? []
        var files: [URL] = []
        var subfolders: [ScannedFolder] = []
        let sorted = items.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for item in sorted {
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if values?.isPackage != true, let subfolder = scan(item) {
                    subfolders.append(subfolder)
                }
            } else if IconKind(url: item) != nil {
                files.append(item)
            }
        }
        guard !files.isEmpty || !subfolders.isEmpty else { return nil }
        return ScannedFolder(url: folder, files: files, subfolders: subfolders)
    }

    @discardableResult
    private func importFolder(
        _ folder: ScannedFolder, inside parent: UUID?, report: inout ImportReport
    ) -> UUID {
        let setID = makeSet(named: folder.url.lastPathComponent, inside: parent).id
        report.allCreated.append(setID)
        for file in folder.files { add(file, to: setID, report: &report) }
        for subfolder in folder.subfolders {
            importFolder(subfolder, inside: setID, report: &report)
        }
        return setID
    }

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.svg, .png, .icns, .ico, .folder]
        panel.prompt = "Import"
        panel.message = currentSetID == nil
            ? "Each folder becomes a set, with its subfolders as sets inside it. Loose files go "
                + "into “Unsorted”."
            : "Files go into “\(title(for: sidebar))”. Folders become sets inside it."
        guard panel.runModal() == .OK else { return }
        importAndReport(panel.urls, into: currentSetID)
    }

    @discardableResult
    func importAndReport(_ urls: [URL], into target: UUID?) -> Bool {
        // An IconJar library is a folder too, but it needs reading, not walking.
        let jars = urls.filter(IconJarLibrary.isLibrary)
        for jar in jars { notice = importIconJarWithNotice(jar, into: target) }
        let files = urls.filter { !IconJarLibrary.isLibrary($0) }
        guard !files.isEmpty else { return !jars.isEmpty }

        let report = importItems(files, into: target)
        if report.createdSets.count == 1 { sidebar = .set(report.createdSets[0]) }
        var lines: [String] = []
        if report.duplicates > 0 {
            let count = plural(report.duplicates, "file")
            lines.append("\(count) already in the library were left out.")
        }
        if !report.skipped.isEmpty {
            let skipped = Self.listed(report.skipped)
            lines.append("Skipped what isn't a readable SVG, PNG, ICNS or ICO:\n" + skipped)
        }
        if !lines.isEmpty {
            notice = Notice(
                title: "Imported \(plural(report.imported, "icon"))",
                message: lines.joined(separator: "\n\n")
            )
        }
        return report.imported > 0
    }

    private static func listed(_ names: [String]) -> String {
        let more = names.count > 8 ? "\n…and \(names.count - 8) more" : ""
        return names.prefix(8).joined(separator: "\n") + more
    }

    /// A drop of the grid's own drag arrives as the temporary export it carries, so it is told
    /// apart by where that file lives: onto a set it moves the dragged icons; anywhere else it is
    /// ignored rather than imported back as a copy.
    @discardableResult
    func handleDrop(_ urls: [URL], onto setID: UUID?) -> Bool {
        // resolvingSymlinksInPath on both sides: a dropped URL may come back as /private/var/...
        // while temporaryDirectory says /var/...
        let dragRoot = Exporter.dragRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        let fromGrid = urls.contains {
            $0.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(dragRoot)
        }
        guard fromGrid else { return importAndReport(urls, into: setID) }
        guard let setID, let ids = draggingIDs else { return false }
        // The drag stamped Recently Used when it began, because a drop into Finder or another
        // app never reports back. Filing icons into a set isn't using them, so put the old
        // dates back along with the move.
        let before = draggedLastUsed
        update(ids) {
            $0.setID = setID
            if let old = before[$0.id] { $0.lastUsed = old }
        }
        return true
    }

    private func add(_ url: URL, to setID: UUID, report: inout ImportReport) {
        // Duplicates first: checking one reads the file at most, and decoding it costs more.
        if IconKind(url: url) != nil, duplicates?.contains(url) == true {
            report.duplicates += 1
            return
        }
        guard let kind = IconKind(url: url), let image = NSImage(contentsOf: url),
              image.isValid, image.size.width > 0, image.size.height > 0
        else {
            report.skipped.append(url.lastPathComponent)
            return
        }
        let stem = url.deletingPathExtension().lastPathComponent
        var icon = Icon(name: stem, setID: setID, kind: kind)
        icon.originalName = stem
        if kind == .svg, preferences.readsSVGTitles,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let named = SVGCleaner.titleAndDescription(of: text)
            if let title = named.title { icon.name = title }
            // Sketch and Figma write "Created with …" there, which describes nothing.
            icon.info = named.description.flatMap { $0.hasPrefix("Created with") ? nil : $0 }
        }
        do {
            try FileManager.default.createDirectory(
                at: iconsFolder, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: fileURL(for: icon))
            icons.append(icon)
            duplicates?.insert(url)
            report.imported += 1
        } catch {
            report.skipped.append("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    /// The set Settings names for loose files, or "Unsorted" when it names none or that set is
    /// gone.
    private func looseFilesSetID() -> UUID {
        if let id = preferences.looseFilesSetID, sets.contains(where: { $0.id == id }) { return id }
        return unsortedSetID()
    }

    private func unsortedSetID() -> UUID {
        sets.first { $0.name == "Unsorted" && $0.parentID == nil }?.id
            ?? makeSet(named: "Unsorted", inside: nil).id
    }

    // MARK: IconJar

    func chooseIconJarLibrary() {
        guard let url = Self.chooseIconJarLibraryURL() else { return }
        notice = importIconJarWithNotice(url, into: currentSetID)
    }

    /// The open panel for an IconJar library, shared by the File menu and Settings.
    static func chooseIconJarLibraryURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [IconJarLibrary.libraryType, .folder].compactMap { $0 }
        // ~/Library is hidden in open panels, so start where IconJar keeps its libraries.
        let support = URL.applicationSupportDirectory
        let homes = [support.appending(path: "IconJar 2.0"), support.appending(path: "IconJar")]
        panel.directoryURL = homes.first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        panel.prompt = "Import"
        panel.message = "Choose an IconJar library (.ijlibrary). Its groups and sets become sets "
            + "here, with names, tags and stars."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Imports and describes how it went, for whichever window asked to show it.
    func importIconJarWithNotice(_ library: URL, into target: UUID?) -> Notice {
        let setsBefore = sets.count
        do {
            let report = try importIconJar(library, into: target)
            var message = "\(plural(sets.count - setsBefore, "set")) added."
            if report.incomplete > 0 {
                message += " \(plural(report.incomplete, "icon")) left out: IconJar's record of "
                    + "\(report.incomplete == 1 ? "it" : "them") has no file or no set."
            }
            if !report.skipped.isEmpty {
                message += " Skipped what Iconery can't read:\n" + Self.listed(report.skipped)
            }
            return Notice(
                title: "Imported \(plural(report.imported, "icon")) from IconJar", message: message
            )
        } catch {
            return Notice(
                title: "The IconJar library could not be read", message: error.localizedDescription
            )
        }
    }

    /// IconJar's groups become sets holding its sets, nested as they were, inside `target` when
    /// there is one. Icons keep their names, tags, stars and dates. Everything keeps IconJar's
    /// identifier, so importing the same library again adds only what is new since.
    @discardableResult
    func importIconJar(_ library: URL, into target: UUID?) throws -> ImportReport {
        let jar = try IconJarLibrary.read(library)
        var report = ImportReport()
        report.incomplete = jar.incompleteItems

        let groups = Dictionary(jar.groups.map { ($0.key, $0) }) { first, _ in first }
        var groupSets: [Int: UUID] = [:]
        func set(forGroup key: Int, depth: Int = 0) -> UUID? {
            if let id = groupSets[key] { return id }
            // The depth limit only stops a parent loop in a damaged store.
            guard let group = groups[key], depth < 64 else { return target }
            let parent = group.parent.flatMap { set(forGroup: $0, depth: depth + 1) } ?? target
            let id = adoptSet(uuid: group.uuid, named: group.name, inside: parent)
            groupSets[key] = id
            return id
        }
        // Groups with no sets in them come across too.
        for group in jar.groups { _ = set(forGroup: group.key) }

        var collections: [Int: (folder: String, set: UUID)] = [:]
        for collection in jar.collections {
            let parent = collection.group.flatMap { set(forGroup: $0) } ?? target
            let id = adoptSet(uuid: collection.uuid, named: collection.name, inside: parent)
            collections[collection.key] = (collection.folder, id)
        }

        try FileManager.default.createDirectory(at: iconsFolder, withIntermediateDirectories: true)
        let setsFolder = library.appending(path: "Sets", directoryHint: .isDirectory)
        var known = Set(icons.map(\.id))
        // Collected and appended once: appending to an observed array one icon at a time copies
        // the whole array each time, which is quadratic over a library of thousands.
        var added: [Icon] = []
        for item in jar.items {
            guard let collection = collections[item.collection] else {
                report.incomplete += 1
                continue
            }
            // Both names come from IconJar's database. IconJar writes plain names, and a ".." in
            // either would reach outside Sets/ to any file on the Mac.
            guard !"\(collection.folder)/\(item.file)".split(separator: "/").contains("..") else {
                report.skipped.append("\(item.file) (outside the library)")
                continue
            }
            let file = setsFolder.appending(path: collection.folder).appending(path: item.file)
            guard let kind = IconKind(url: file) ?? item.recordedKind else {
                report.skipped.append(item.file)
                continue
            }
            let id = UUID(uuidString: item.uuid) ?? UUID()
            guard known.insert(id).inserted else { continue }
            let stem = file.deletingPathExtension().lastPathComponent
            let icon = Icon(
                id: id, name: item.name.flatMap { $0.isEmpty ? nil : $0 } ?? stem,
                setID: collection.set, kind: kind, tags: item.tags, starred: item.starred,
                added: item.added ?? .now, lastUsed: item.lastUsed
            )
            do {
                try FileManager.default.copyItem(at: file, to: fileURL(for: icon))
                added.append(icon)
                report.imported += 1
            } catch {
                report.skipped.append("\(item.file) (\(error.localizedDescription))")
            }
        }
        icons += added
        save()
        return report
    }

    /// The set IconJar knew by `uuid`: made on the first import and found again on the next.
    private func adoptSet(uuid: String, named name: String, inside parent: UUID?) -> UUID {
        let id = UUID(uuidString: uuid) ?? UUID()
        if sets.contains(where: { $0.id == id }) { return id }
        return makeSet(named: name, inside: parent, id: id).id
    }

    // MARK: Locations

    struct Problem: LocalizedError {
        var errorDescription: String?

        static let backupInsideLibrary = Problem(
            errorDescription: "Backups can't be kept inside the library they back up."
        )

        /// The backup is zipping the library folder, which mustn't move or change under it.
        static let backingUp = Problem(
            errorDescription: "A backup is being written. Try again once it has finished."
        )
    }

    static let defaultFolder = URL.applicationSupportDirectory
        .appending(path: "Iconery", directoryHint: .isDirectory)

    /// iCloud Drive ▸ Iconery when iCloud Drive is on, as IconJar defaults to iCloud Drive ▸
    /// IconJar, so a backup leaves this Mac with no setup. Documents ▸ Iconery otherwise.
    static var defaultBackupFolder: URL {
        let iCloud = URL.libraryDirectory
            .appending(path: "Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        let hasICloud = FileManager.default.fileExists(atPath: iCloud.path(percentEncoded: false))
        return (hasICloud ? iCloud : URL.documentsDirectory)
            .appending(path: "Iconery", directoryHint: .isDirectory)
    }

    nonisolated static let libraryKey = "libraryLocation"
    nonisolated static let backupKey = "backupLocation"
    nonisolated static let lastBackupKey = "lastBackup"
    nonisolated static let exportKey = "exportLocation"

    /// Locations are kept as bookmarks rather than paths, so a folder renamed or moved in Finder
    /// is still found.
    private static func storedURL(_ key: String) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { remember(url, as: key) }
        return url
    }

    private static func remember(_ url: URL, as key: String) {
        UserDefaults.standard.set(try? url.bookmarkData(), forKey: key)
    }

    /// Whether `url` is `folder` itself or anywhere inside it.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = normalizedPath(url)
        let root = normalizedPath(folder)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Moves the whole library into `destination` as "Iconery Library" and carries on there.
    func moveLibrary(into destination: URL) throws {
        guard !isBackingUp else { throw Problem.backingUp }
        guard !Self.isInside(destination, folder) else {
            throw Problem(errorDescription: "A library can't move into itself.")
        }
        save()
        let target = Exporter.uniqueURL(for: "Iconery Library", in: destination)
        try FileManager.default.moveItem(at: folder, to: target)
        folder = target
        Self.remember(target, as: Self.libraryKey)
    }

    /// Opens the library in `url` in place of this one. A folder unzipped from a backup is one,
    /// which makes this the way to restore a backup.
    func switchLibrary(to url: URL) throws {
        guard !isBackingUp else { throw Problem.backingUp }
        let index = url.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: index.path(percentEncoded: false)) else {
            throw Problem(
                errorDescription: "“\(url.lastPathComponent)” isn't an Iconery library: it has no "
                    + "library.json inside."
            )
        }
        save()
        folder = url
        sets = []
        licenses = License.starters
        icons = []
        selection = []
        expandedSets = []
        sidebar = .all
        images.removeAllObjects()
        thumbnails.removeAllObjects()
        singleColors = [:]
        load()
        Self.remember(url, as: Self.libraryKey)
    }

    func changeBackupFolder(to url: URL) throws {
        guard !Self.isInside(url, folder) else {
            throw Problem.backupInsideLibrary
        }
        backupFolder = url
        Self.remember(url, as: Self.backupKey)
    }

    // MARK: Backup

    /// File ▸ Back Up Library Now. Settings calls `backUp(into:)` and shows its own errors.
    func backUpNow() {
        Task {
            do {
                let url = try await backUp(into: backupFolder)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                notice = Notice(
                    title: "The backup could not be written", message: error.localizedDescription
                )
            }
        }
    }

    /// Writes "Iconery Backup <date> at <time>.zip" into `destination`, then trims the folder to
    /// the number of backups Settings keeps.
    @discardableResult
    func backUp(into destination: URL) async throws -> URL {
        guard !Self.isInside(destination, folder) else { throw Problem.backupInsideLibrary }
        guard !isBackingUp else {
            throw Problem(errorDescription: "A backup is already being written.")
        }
        isBackingUp = true
        defer { isBackingUp = false }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // Sorts by name in date order, and has no colon, which a file name can't hold.
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Iconery Backup \(stamp.string(from: .now)).zip"
        let url = Exporter.uniqueURL(for: name, in: destination)
        try await writeBackup(to: url)
        lastBackup = .now
        UserDefaults.standard.set(lastBackup, forKey: Self.lastBackupKey)
        Self.pruneBackups(in: destination, keeping: preferences.backupsKept)
        return url
    }

    /// Zips the library folder exactly as it sits on disk (the index plus every icon file), so
    /// sets, nesting, tags and stars all survive and a restore is a straight swap back. `ditto`
    /// because it ships with macOS and Foundation has no zip writer. It runs while the window
    /// stays responsive: a library of large ICNS files takes a while to zip.
    func writeBackup(to url: URL) async throws {
        save()  // the index on disk now matches what the window shows
        // ditto's complaints go to a file rather than a pipe, which a long one could fill and
        // stall.
        let log = FileManager.default.temporaryDirectory
            .appending(path: "iconery-backup-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        // Zipped under another name and renamed once whole. A zip that stops part way is removed,
        // and until then its name keeps it from counting as one of the backups pruning keeps.
        let partial = url.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        // --keepParent puts the folder itself at the top of the archive, not its contents loose.
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            folder.path(percentEncoded: false), partial.path(percentEncoded: false),
        ]
        process.standardError = try FileHandle(forWritingTo: log)
        let status = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Problem(
                errorDescription: message.isEmpty ? "ditto stopped with status \(status)." : message
            )
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// Moves backups in `folder` past the newest `keep` to the Trash, where they can still be
    /// fished out.
    static func pruneBackups(in folder: URL, keeping keep: Int) {
        for old in backupsToPrune(in: folder, keeping: keep) {
            try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
        }
    }

    /// The backups in `folder` older than the newest `keep`. Only files named the way
    /// `backUp(into:)` names them count, and those names sort in date order. 0 keeps everything.
    nonisolated static func backupsToPrune(in folder: URL, keeping keep: Int) -> [URL] {
        guard keep > 0 else { return [] }
        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? [])
            .filter {
                $0.lastPathComponent.hasPrefix("Iconery Backup ") && $0.pathExtension == "zip"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(backups.dropLast(keep))
    }

    /// Backs up whenever the schedule in Settings says one is due: first shortly after launch,
    /// then hourly, for as long as the window is open.
    func runBackupSchedule() async {
        try? await Task.sleep(for: .seconds(15))
        while !Task.isCancelled {
            await backUpIfDue()
            try? await Task.sleep(for: .seconds(60 * 60))
        }
    }

    func backUpIfDue() async {
        guard let interval = preferences.backupSchedule.interval, !isBackingUp else { return }
        if let lastBackup, Date.now.timeIntervalSince(lastBackup) < interval { return }
        do {
            try await backUp(into: backupFolder)
            lastScheduledFailure = nil
        } catch {
            let message = error.localizedDescription
            if alertsScheduledFailure(message) {
                notice = Notice(
                    title: "The scheduled backup could not be written", message: message
                )
            }
            lastScheduledFailure = message
        }
    }

    /// Whether a scheduled backup that failed with `message` should raise an alert. The schedule
    /// tries again every hour the window is open, so a backup drive left unplugged fails the same
    /// way each time. `lastScheduledFailure` holds the previous attempt's message, or nil when it
    /// succeeded or there was none.
    private func alertsScheduledFailure(_ message: String) -> Bool {
        // TODO(kenny): decide when a repeated failure is worth an alert. Until then, every one is.
        true
    }

    // MARK: Export

    var activePreset: ExportPreset? {
        guard let id = export.presetID else { return nil }
        return (ExportPreset.builtIn + presets).first { $0.id == id }
    }

    var canExport: Bool { activePreset != nil || export.isExportable }

    /// Every file exporting `icon` writes: each output of the active preset, or the current
    /// settings when there is none.
    func exportFiles(for icon: Icon) throws -> [ExportFile] {
        let settings = activePreset.map { export.outputs(of: $0) } ?? [export]
        return try settings.flatMap { options in
            try Exporter.files(
                for: icon, source: fileURL(for: icon), image: image(for: icon), options: options
            )
        }
    }

    /// Saves the current format, sizes, prefix and suffix as one of the user's presets, and
    /// switches to it.
    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let output = PresetOutput(
            format: export.format, sizes: export.sizes, prefix: export.prefix,
            suffix: export.suffix, includeSize: export.includeSize
        )
        let preset = ExportPreset(
            id: UUID().uuidString, name: name, platform: nil, outputs: [output]
        )
        presets.append(preset)
        export.presetID = preset.id
    }

    func deletePreset(_ id: String) {
        presets.removeAll { $0.id == id }
        if export.presetID == id { export.presetID = nil }
    }

    func setExportFolder(_ url: URL?) {
        exportFolder = url
        if let url {
            Self.remember(url, as: Self.exportKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.exportKey)
        }
    }

    func exportSelection() {
        let targets = selectedIcons
        guard !targets.isEmpty, canExport else { return }
        let folder: URL
        if let exportFolder {
            folder = exportFolder
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            let way = activePreset?.name ?? export.format.title
            panel.message = "Choose where to save \(plural(targets.count, "icon")) as \(way)."
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            folder = chosen
        }

        let (written, problems) = export(targets, to: folder)
        if preferences.revealsExports, !written.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(written)
        }
        if !problems.isEmpty {
            notice = Notice(
                title: "Exported \(plural(written.count, "file"))",
                message: problems.joined(separator: "\n")
            )
        }
    }

    /// Writes every file for `icons` into `folder`, in set folders and with Finder tags when
    /// Settings asks for them. Returns what was written and what went wrong, per icon.
    func export(_ icons: [Icon], to folder: URL) -> (written: [URL], problems: [String]) {
        var written: [URL] = []
        var problems: [String] = []
        for icon in icons {
            do {
                let destination = preferences.keepsSetFolders
                    ? setFolder(for: icon, in: folder) : folder
                let urls = try Exporter.write(exportFiles(for: icon), to: destination)
                if preferences.addsFinderTags, !icon.tags.isEmpty {
                    for url in urls {
                        try? (url as NSURL).setResourceValue(icon.tags, forKey: .tagNamesKey)
                    }
                }
                written += urls
            } catch {
                problems.append("\(icon.name): \(error.localizedDescription)")
            }
        }
        update(Set(icons.map(\.id))) { $0.lastUsed = .now }
        return (written, problems)
    }

    /// `folder`, then one folder per set from the top level down to the icon's own: IconJar's
    /// "Maintain set hierarchy".
    private func setFolder(for icon: Icon, in folder: URL) -> URL {
        var names: [String] = []
        var current = sets.first { $0.id == icon.setID }
        // The bound only stops a parent loop in a damaged library.
        while let set = current, names.count < 64 {
            names.insert(Exporter.safeFileName(set.name), at: 0)
            current = set.parentID.flatMap { parent in sets.first { $0.id == parent } }
        }
        return names.reduce(folder) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// The drag carries real files, exported with the inspector's current settings, so Finder,
    /// Figma or an editor gets exactly what Export would have written. IconJar calls this
    /// QuickDrag. A drag of several icons, or of one icon in several sizes, carries one folder.
    func dragProvider(for icon: Icon, alone: Bool = false) -> NSItemProvider {
        let ids = alone ? [icon.id] : targets(for: icon)
        draggingIDs = ids
        let dragged = icons.filter { ids.contains($0.id) }
        draggedLastUsed = Dictionary(uniqueKeysWithValues: dragged.map { ($0.id, $0.lastUsed) })
        // Everything must land under dragRoot, or a drop onto a set could not be told apart
        // from an import.
        let (folder, written) = writtenForTransfer(
            dragged, under: Exporter.dragRoot,
            name: dragged.count == 1 ? Exporter.safeFileName(icon.name) : "Icons",
            leftOutOf: "the drag"
        )
        update(ids) { $0.lastUsed = .now }
        let payload = written.count == 1 ? written[0] : folder
        return NSItemProvider(contentsOf: payload) ?? NSItemProvider()
    }

    /// ⌘C and the menu's Copy: the selection goes on the pasteboard as the files a drag would
    /// carry. Copying counts as using, as dragging does.
    func copyToPasteboard(_ ids: Set<UUID>) {
        let items = sortedIcons.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let (_, written) = writtenForTransfer(
            items, under: Self.openRoot, name: "Copied", leftOutOf: "the copy"
        )
        guard !written.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(written as [NSURL])
        update(ids) { $0.lastUsed = .now }
    }

    /// The same files for the Edit menu's Copy, which hands the pasteboard providers instead.
    func copyProviders(for ids: Set<UUID>) -> [NSItemProvider] {
        let items = sortedIcons.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return [] }
        let (_, written) = writtenForTransfer(
            items, under: Self.openRoot, name: "Copied", leftOutOf: "the copy"
        )
        update(ids) { $0.lastUsed = .now }
        return written.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
    }

    /// The icon's SVG source, for pasting straight into an editor or a design tool. The file as
    /// it is, not the cleaned-up copy an SVG export can write.
    func copySVGCode(_ icon: Icon) {
        guard icon.kind == .svg, let data = try? Data(contentsOf: fileURL(for: icon)),
              let text = String(data: data, encoding: .utf8)
        else {
            notice = Notice(
                title: "“\(icon.name)” could not be copied",
                message: "Its file is missing from the library folder or isn't text."
            )
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        update([icon.id]) { $0.lastUsed = .now }
    }

    /// Shows the library's own file. Read-only in spirit: moving or editing it there changes
    /// the library, so the menu item says Finder rather than inviting that, as IconJar's does.
    func revealInFinder(_ ids: Set<UUID>) {
        let urls = icons.filter { ids.contains($0.id) }.map { fileURL(for: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Writes `items` out the way a drag or copy carries them: exported with the current
    /// settings, or the original file when exporting fails, so nothing arrives as an empty
    /// file. Icons whose files are missing are reported and left out.
    private func writtenForTransfer(
        _ items: [Icon], under root: URL, name: String, leftOutOf what: String
    ) -> (folder: URL, written: [URL]) {
        let folder = root.appending(path: UUID().uuidString).appending(path: name)
        var written: [URL] = []
        var missing: [String] = []
        for item in items {
            let files: [ExportFile]
            if let exported = try? exportFiles(for: item) {
                files = exported
            } else if let data = try? Data(contentsOf: fileURL(for: item)) {
                files = [ExportFile(
                    name: "\(Exporter.safeFileName(item.name)).\(item.kind.rawValue)", data: data
                )]
            } else {
                missing.append(item.name)
                continue
            }
            written += (try? Exporter.write(files, to: folder)) ?? []
        }
        if !missing.isEmpty {
            notice = Notice(
                title: "Some icons were left out of \(what)",
                message: "Their files are missing from the library folder:\n" + Self.listed(missing)
            )
        }
        return (folder, written)
    }
}

/// Finds files the library already has, by content. Sizes are compared first, so only a file the
/// same size as one already here is ever read and hashed.
private struct DuplicateFinder {
    private var bySize: [Int: [URL]] = [:]
    private var hashes: [URL: Data] = [:]

    init(files: [URL]) {
        for url in files { insert(url) }
    }

    mutating func insert(_ url: URL) {
        guard let size = Self.size(of: url) else { return }
        bySize[size, default: []].append(url)
    }

    mutating func contains(_ url: URL) -> Bool {
        guard let size = Self.size(of: url), let sameSize = bySize[size],
              let hash = hash(of: url)
        else { return false }
        for other in sameSize where other != url {
            if self.hash(of: other) == hash { return true }
        }
        return false
    }

    private mutating func hash(of url: URL) -> Data? {
        if let known = hashes[url] { return known }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = Data(SHA256.hash(data: data))
        hashes[url] = hash
        return hash
    }

    private static func size(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}

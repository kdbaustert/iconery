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
    private(set) var smartSets: [SmartSet] = []

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
    /// Shows the batch rename sheet for the selection.
    var batchRenaming = false
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
    /// The keyboard caret: the moving end of a ⇧-arrow range, where the anchor is the fixed one.
    @ObservationIgnored private var focusID: UUID?
    /// Type-to-select's prefix so far, and when it starts over.
    @ObservationIgnored private var typeAhead = ""
    @ObservationIgnored private var typeAheadExpiry = Date.distantPast
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
    /// A bookmark of this library's own folder, taken once it exists, so a rename or move in
    /// Finder mid-session can be followed. Deliberately not the one in UserDefaults: that is
    /// shared state naming the *remembered* library, which this instance — a test's, or the
    /// default standing in for a missing one — may not be, and following it would save this
    /// library over that one.
    @ObservationIgnored private var folderBookmark: Data?
    /// Set when the remembered library couldn't be found and the default opened in its place.
    /// Scheduled backups sit out until the user switches somewhere on purpose: backing up the
    /// stand-in would prune the real library's backups to make room.
    @ObservationIgnored private var openedFallbackLibrary = false
    /// Why the last scheduled backup failed, kept until one succeeds.
    @ObservationIgnored private var lastScheduledFailure: String?
    /// File names of the backups this library wrote, kept in library.json beside `lastBackup`.
    /// Pruning looks only at these, so a user's own files and another library's backups in the
    /// same folder are never counted or trashed.
    @ObservationIgnored private var backupNames: [String] = []
    /// Set when the backup folder chosen in Settings can't be found, say on a drive that isn't
    /// plugged in. Falling back to the default folder would scatter backups the user didn't
    /// ask for, so scheduled backups sit out until it resolves again or another is chosen.
    @ObservationIgnored private var backupFolderMissing = false
    /// Whether the notice about a library folder in the Trash has been shown for this stay there.
    @ObservationIgnored private var warnedOfTrash = false
    /// Held to remove it on deinit, which isn't on the main actor.
    @ObservationIgnored private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

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
    @ObservationIgnored
    private var cachedTagCounts: (icons: [Icon], counts: [(tag: String, count: Int)])?
    @ObservationIgnored private var cachedSmartCounts:
        (icons: [Icon], sets: [IconSet], smartSets: [SmartSet], bySet: [UUID: Int])?

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
    /// their own `preferences` and on `defaultFolder`, where the stand-in for a library that
    /// can't be found opens.
    init(
        folder: URL? = nil, defaultFolder: URL = Library.defaultFolder,
        preferences: Preferences = .shared
    ) {
        self.preferences = preferences
        // Without limits these only shed under memory pressure, and a 256 pt grid keeps a 1 MB
        // thumbnail per icon scrolled past.
        thumbnails.totalCostLimit = 256 * 1024 * 1024
        images.countLimit = 500
        exportFolder = Self.storedURL(Self.exportKey)
        let remembered = Self.storedURL(Self.libraryKey)
        self.folder = folder ?? remembered ?? defaultFolder
        let storedBackupFolder = Self.storedBackupFolder()
        backupFolder = storedBackupFolder ?? Self.defaultBackupFolder
        backupFolderMissing = storedBackupFolder == nil
            && Self.defaults.data(forKey: Self.backupKey) != nil
        // nil for a library that has never been saved; the first save takes one instead.
        folderBookmark = try? self.folder.bookmarkData()
        let hadIndex = FileManager.default.fileExists(
            atPath: self.folder.appending(path: "library.json").path(percentEncoded: false)
        )
        load()
        // Where the window left off, with anything pointing at a set that has gone dropped.
        let known = Set(sets.map(\.id))
        let rememberedSidebar = preferences.sidebarItem.flatMap(SidebarItem.init(stored:))
        sidebar = switch rememberedSidebar {
        case .set(let id) where !known.contains(id): .all
        case .smart(let id) where !smartSets.contains(where: { $0.id == id }): .all
        case let item?: item
        case nil: .all
        }
        expandedSets = Set(preferences.expandedSetIDs.compactMap(UUID.init(uuidString:)))
            .intersection(known)
        let hadLocation = Self.defaults.data(forKey: Self.libraryKey) != nil
        if folder == nil, hadLocation, remembered == nil {
            // The location is kept, so the library opens again once its drive is back.
            openedFallbackLibrary = true
            notice = Notice(
                title: "Your library couldn't be found",
                message: "It may be on a drive that isn't connected. Iconery opened the default "
                    + "library for now. Choose Settings ▸ Switch to open yours again."
            )
        }
        // Backups used to be tracked for the whole Mac. The library opened at launch takes that
        // date once, and save() clears it from UserDefaults when it lands in the index, so it
        // can never be mistaken for another library's. Not the stand-in for a missing library,
        // and not a brand-new one: neither is the library those backups were made of.
        if lastBackup == nil, hadIndex, !openedFallbackLibrary {
            lastBackup = Self.defaults.object(forKey: Self.lastBackupKey) as? Date
        }
        if backupFolderMissing {
            notice = Self.backupFolderMissingNotice
        }
        try? FileManager.default.removeItem(at: Exporter.dragRoot)
        try? FileManager.default.removeItem(at: Self.openRoot)
        // A Finder move always deactivates the app first, so coming back is when to look. That
        // way what only reads the folder (thumbnails, export, drag, Quick Look) follows a move
        // too, without waiting for an edit.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.followMovedFolder() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // MARK: Persistence

    private struct Index: Codable {
        var sets: [IconSet]
        var icons: [Icon]
        /// Optional: libraries saved before licences existed start with the starter set.
        var licenses: [License]?
        /// Optional, like licenses: libraries from before smart sets still decode.
        var smartSets: [SmartSet]?
        /// Backups belong to a library rather than the Mac, so a second library backing up into
        /// the same folder isn't thought up to date, or pruned, by the first one's.
        var lastBackup: Date?
        /// File names of the backups this library wrote. See `backupNames`.
        var backups: [String]?
    }

    private func load() {
        // A different library's past is not this one's to undo.
        undoManager?.removeAllActions()
        indexUnreadable = false
        lastBackup = nil
        backupNames = []
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
            // A repeated id would crash the dictionaries built from these, so the first of each
            // stays: a hand-edited or copy-pasted index is the only way one gets here.
            sets = Self.firstOfEachID(index.sets)
            icons = Self.firstOfEachID(index.icons)
            licenses = Self.firstOfEachID(index.licenses ?? License.starters)
            smartSets = Self.firstOfEachID(index.smartSets ?? [])
            lastBackup = index.lastBackup
            backupNames = index.backups ?? []
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

    private static func firstOfEachID<Item: Identifiable>(_ items: [Item]) -> [Item] {
        var seen: Set<Item.ID> = []
        return items.filter { seen.insert($0.id).inserted }
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

    /// Finder can rename or move the library folder while it's open. A bookmark follows the
    /// move; `folder`'s path doesn't, and a write to the old path would recreate the folder
    /// there and split the library in two. So before writing anything: if the folder is gone
    /// but its bookmark now points somewhere real, carry on there. The one in UserDefaults
    /// follows the move by itself, so the next launch agrees.
    ///
    /// A folder moved to the Trash is not followed: saving there would keep editing a library
    /// the user threw away, and writing to the old path would recreate it. Returns true while
    /// that is where it is, and everything that writes files stops on it. It is looked at again
    /// each time rather than remembered, so Put Back resumes saving by itself, and a move from
    /// the Trash to a normal place is followed like any other.
    ///
    /// The notice is queued the first time only, so the many things that call this don't stack
    /// alerts. A caller that is refusing something the user asked for passes `announce: false`
    /// and speaks for itself every time.
    @discardableResult
    private func followMovedFolder(announce: Bool = true) -> Bool {
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            warnedOfTrash = false
            return false
        }
        guard let bookmark = folderBookmark else { return false }
        var isStale = false
        guard let moved = try? URL(
            resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &isStale
        ), moved != folder,
        FileManager.default.fileExists(atPath: moved.path(percentEncoded: false))
        else { return false }
        if Self.isInTrash(moved) {
            if announce, !warnedOfTrash {
                warnedOfTrash = true
                notice = Self.inTrashNotice
            }
            return true
        }
        folder = moved
        // Whatever a scan found points at the old place.
        check = nil
        return false
    }

    private static let inTrashNotice = Notice(
        title: "Your library is in the Trash",
        message: "Changes won't be saved until it's put back: in the Trash, choose "
            + "File ▸ Put Back. Or choose Settings ▸ Switch to open another library."
    )

    /// The Trash notice when the library is in the Trash, every time it is asked rather than
    /// once, for the actions the user just tried and was turned down.
    private func trashRefusal() -> Notice? {
        followMovedFolder(announce: false) ? Self.inTrashNotice : nil
    }

    private static func isInTrash(_ url: URL) -> Bool {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false
        ) else { return false }
        return isInside(url, trash)
    }

    private func save() {
        guard !indexUnreadable, !followMovedFolder() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder.encode(
                Index(
                    sets: sets, icons: icons, licenses: licenses, smartSets: smartSets,
                    lastBackup: lastBackup, backups: backupNames
                )
            )
            try data.write(to: indexURL, options: .atomic)
            // Now in the index, where it belongs to this library alone.
            if lastBackup != nil { Self.defaults.removeObject(forKey: Self.lastBackupKey) }
            // A new library's folder exists from its first save on; bookmark it then.
            if folderBookmark == nil { folderBookmark = try? folder.bookmarkData() }
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
        case .tag(let tag):
            sortedIcons.filter { $0.tags.contains(tag) }
        case .smart(let id):
            matching(smartSets.first { $0.id == id }?.query ?? "")
        }
    }

    /// A smart set's icons: its saved query run over the whole library, across every field, so
    /// what it finds doesn't swing with the search scope in Settings.
    private func matching(_ query: String) -> [Icon] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let paths = Dictionary(uniqueKeysWithValues: setPaths.map { ($0.set.id, $0.path) })
        let scope = SearchScope(tags: true, setNames: true, descriptions: true)
        return sortedIcons.filter {
            iconMatches($0, query: query, setPath: paths[$0.setID] ?? "", scope: scope)
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
        case .tag(let tag): tagCounts.first { $0.tag == tag }?.count ?? 0
        case .smart(let id): smartCounts[id] ?? 0
        }
    }

    /// Every tag in the library with how many icons carry it, in name order, cached like the
    /// set counts so the sidebar never rebuilds it per row.
    var tagCounts: [(tag: String, count: Int)] {
        if let cachedTagCounts, cachedTagCounts.icons == icons { return cachedTagCounts.counts }
        var histogram: [String: Int] = [:]
        for icon in icons {
            for tag in icon.tags { histogram[tag, default: 0] += 1 }
        }
        let counts = histogram
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (tag: $0.key, count: $0.value) }
        cachedTagCounts = (icons, counts)
        return counts
    }

    private var smartCounts: [UUID: Int] {
        if let cachedSmartCounts, cachedSmartCounts.icons == icons,
           cachedSmartCounts.sets == sets, cachedSmartCounts.smartSets == smartSets {
            return cachedSmartCounts.bySet
        }
        let bySet = Dictionary(
            uniqueKeysWithValues: smartSets.map { ($0.id, matching($0.query).count) }
        )
        cachedSmartCounts = (icons, sets, smartSets, bySet)
        return bySet
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
        var smartSets: [SmartSet]
    }

    var visibleIcons: [Icon] {
        let scope = SearchScope(
            tags: preferences.searchesTags, setNames: preferences.searchesSetNames,
            descriptions: preferences.searchesDescriptions
        )
        let key = VisibleKey(
            icons: icons, sets: sets, sidebar: sidebar, searchText: searchText,
            sort: preferences.sort, descending: preferences.sortDescending,
            recentLimit: preferences.recentLimit, scope: scope, smartSets: smartSets
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
        case .smart(let id): smartSets.first { $0.id == id }?.name ?? "Smart Set"
        case .tag(let tag): tag
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
        focusID = id
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
        recording("New Set") {
            let set = makeSet(named: name, inside: parent)
            save()
            return set
        }
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
        recording("Rename Set") {
            sets[index].name = uniqueSetName(name, inside: sets[index].parentID, excluding: id)
            save()
        }
    }

    /// Moves a set, with everything inside it, under `parent`, or to the top level when nil. A set
    /// can't move into itself or into a set inside it.
    /// Returns whether the set moved, so a drop that was refused can say so. A name the new
    /// siblings already use is numbered, as a new set's would be.
    @discardableResult
    func moveSet(_ id: UUID, into parent: UUID?) -> Bool {
        if let parent, subtree(of: id).contains(parent) { return false }
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return false }
        recording("Move Set") {
            sets[index].name = uniqueSetName(sets[index].name, inside: parent, excluding: id)
            sets[index].parentID = parent
            if let parent { expandedSets.insert(parent) }
            save()
        }
        return true
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

    // MARK: Smart sets

    /// Saves what's in the search field as a smart set named after it, and shows it.
    func saveSearchAsSmartSet() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let smart = SmartSet(name: query, query: query)
        recording("New Smart Set") {
            smartSets.append(smart)
            save()
        }
        searchText = ""
        sidebar = .smart(smart.id)
    }

    func beginRename(_ smart: SmartSet) {
        draftName = smart.name
        naming = .renameSmartSet(smart.id)
    }

    func beginEditQuery(_ smart: SmartSet) {
        draftName = smart.query
        naming = .editSmartSetQuery(smart.id)
    }

    func renameSmartSet(_ id: UUID, to name: String) {
        guard let index = smartSets.firstIndex(where: { $0.id == id }) else { return }
        recording("Rename Smart Set") {
            smartSets[index].name = name
            save()
        }
    }

    func editSmartSetQuery(_ id: UUID, to query: String) {
        guard let index = smartSets.firstIndex(where: { $0.id == id }) else { return }
        recording("Edit Query") {
            smartSets[index].query = query
            save()
        }
    }

    /// No confirmation: it holds nothing but its query, and undo brings it back.
    func deleteSmartSet(_ id: UUID) {
        recording("Delete Smart Set") {
            smartSets.removeAll { $0.id == id }
            save()
        }
        if sidebar == .smart(id) { sidebar = .all }
    }

    func finishNaming(_ naming: Naming) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch naming {
        case .newSet(let parent): sidebar = .set(createSet(named: name, inside: parent).id)
        case .renameSet(let id): renameSet(id, to: name)
        case .renameIcon(let id): rename(id, to: name)
        case .renameSmartSet(let id): renameSmartSet(id, to: name)
        case .editSmartSetQuery(let id): editSmartSetQuery(id, to: name)
        }
    }

    func requestDelete(_ set: IconSet) {
        pendingDeletion = .set(
            set, iconCount: count(in: .set(set.id)), setCount: subtree(of: set.id).count - 1
        )
    }

    func perform(_ deletion: Deletion) {
        let name = if case .set = deletion { "Delete Set" } else { "Delete" }
        recording(name) {
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
        // No file deletion here: every removal runs inside recording(), which moves the files
        // of icons that leave the library to the Trash so undo can bring them back.
        icons.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Unique among its siblings only: "Outline" may sit inside both "Lucide" and "Heroicons".
    /// `excluding` is a set being renamed or moved, which must not clash with its own old name.
    private func uniqueSetName(
        _ name: String, inside parent: UUID?, excluding id: UUID? = nil
    ) -> String {
        let taken = Set(
            sets.filter { $0.parentID == parent && $0.id != id }.map { $0.name.lowercased() }
        )
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Undo

    /// The window's undo manager, handed over by ContentView, so Edit ▸ Undo reaches the
    /// library when the grid has focus and text fields keep their own. Nil in tests until a
    /// test brings one.
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var isRecording = false

    /// What one action changed, as only the items it touched: `before` holds them as they were
    /// (the changed and the removed), `after` as they became (the changed and the added). Undo
    /// puts `before` back and removes what only `after` has; redo the reverse. Files of removed
    /// icons sit in the Trash meanwhile, under `trashed`, keyed by icon id.
    private struct Step: Sendable {
        var name: String
        var before = Delta()
        var after = Delta()
        var trashed: [UUID: URL] = [:]
    }

    private struct Delta: Sendable {
        var icons: [Icon] = []
        var sets: [IconSet] = []
        var licenses: [License] = []
        var smartSets: [SmartSet] = []
        var isEmpty: Bool {
            icons.isEmpty && sets.isEmpty && licenses.isEmpty && smartSets.isEmpty
        }
    }

    /// Runs `change` and registers what it did with the undo manager, worked out by diffing the
    /// library around it, so a caller never lists what it touched. Reentrant calls, like the
    /// set a folder import creates, fold into the outermost step. Recently Used stamps happen
    /// outside any recording on purpose: a drag or copy is not an edit to undo.
    @discardableResult
    private func recording<T>(_ name: String, _ change: () throws -> T) rethrows -> T {
        guard !isRecording else { return try change() }
        // Icon files are written before save() would notice a move, so catch it before the edit.
        followMovedFolder()
        isRecording = true
        defer { isRecording = false }
        let (icons0, sets0, licenses0, smart0) = (icons, sets, licenses, smartSets)
        let result = try change()
        var step = Step(name: name)
        diff(icons0, icons, into: &step.before.icons, &step.after.icons)
        diff(sets0, sets, into: &step.before.sets, &step.after.sets)
        diff(licenses0, licenses, into: &step.before.licenses, &step.after.licenses)
        diff(smart0, smartSets, into: &step.before.smartSets, &step.after.smartSets)
        guard !(step.before.isEmpty && step.after.isEmpty) else { return result }
        // Files of icons the action removed go to the Trash rather than away.
        let kept = Set(icons.map(\.id))
        trashFiles(of: step.before.icons.filter { !kept.contains($0.id) }, into: &step.trashed)
        register(step, undoing: true)
        return result
    }

    /// Items only or different in `old` land in `before`; only or different in `new`, `after`.
    private func diff<Item: Identifiable & Equatable>(
        _ old: [Item], _ new: [Item], into before: inout [Item], _ after: inout [Item]
    ) {
        if old == new { return }  // still sharing storage: nothing to walk
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        before = old.filter { newByID[$0.id] != $0 }
        after = new.filter { oldByID[$0.id] != $0 }
    }

    private func register(_ step: Step, undoing: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            // Undo always arrives on the main thread in an AppKit app.
            MainActor.assumeIsolated { target.apply(step, undoing: undoing) }
        }
        undoManager.setActionName(step.name)
    }

    /// One direction of a step: what the direction adds is removed (files to the Trash), and
    /// what it had is put back (files out of the Trash). Registering the reverse lands it on
    /// the other of the undo manager's two stacks.
    private func apply(_ step: Step, undoing: Bool) {
        // Moving files back would recreate the old path, or write into the Trash. The step is
        // dropped: while the undo manager is undoing, anything registered lands on its redo
        // stack and would still mean "undo", and it has no way to put a step back on the stack
        // it came off. Registering nothing leaves the rest of the history coherent, and the
        // notice says the step is gone.
        guard !followMovedFolder(announce: false) else {
            notice = Notice(
                title: "Your library is in the Trash",
                message: "Put it back in Finder (File ▸ Put Back) to keep working. Undo can't "
                    + "reach files in the Trash, so that step can no longer be undone."
            )
            return
        }
        var step = step
        let restored = undoing ? step.before : step.after
        let counterpart = undoing ? step.after : step.before

        let restoredIconIDs = Set(restored.icons.map(\.id))
        let goneIcons = Set(counterpart.icons.map(\.id)).subtracting(restoredIconIDs)
        trashFiles(of: icons.filter { goneIcons.contains($0.id) }, into: &step.trashed)
        icons.removeAll { goneIcons.contains($0.id) }
        selection.subtract(goneIcons)

        let present = Set(icons.map(\.id))
        let counterpartByID = Dictionary(
            uniqueKeysWithValues: counterpart.icons.map { ($0.id, $0) }
        )
        var missing: [String] = []
        for icon in restored.icons {
            if !present.contains(icon.id) {
                let file = fileURL(for: icon)
                if let away = step.trashed[icon.id] {
                    // Forgotten only once it is back, or a failed move would lose track of the
                    // file in the Trash. Redo then takes the icon out again without touching
                    // the entry (there is no file to trash), and the next Undo finds it and
                    // tries the move again.
                    do {
                        try FileManager.default.moveItem(at: away, to: file)
                        step.trashed[icon.id] = nil
                    } catch {
                        missing.append(icon.name)
                    }
                } else if !FileManager.default.fileExists(
                    atPath: file.path(percentEncoded: false)
                ) {
                    missing.append(icon.name)
                }
            }
            if let index = icons.firstIndex(where: { $0.id == icon.id }) {
                var restoredIcon = icon
                // Recently Used stamps happen outside any recording, so a stamp since this
                // step was made isn't the step's to revert. The counterpart holds the date the
                // step left: while the icon still has it, nothing has stamped since and the
                // step's own date comes back, as with Clear Recently Used. Any other date is
                // newer than the step and stays.
                if let left = counterpartByID[icon.id], icons[index].lastUsed != left.lastUsed {
                    restoredIcon.lastUsed = icons[index].lastUsed
                }
                icons[index] = restoredIcon
            } else {
                icons.append(icon)
            }
        }

        let goneSets = Set(counterpart.sets.map(\.id)).subtracting(restored.sets.map(\.id))
        sets.removeAll { goneSets.contains($0.id) }
        expandedSets.subtract(goneSets)
        if case .set(let id) = sidebar, goneSets.contains(id) { sidebar = .all }
        for set in restored.sets {
            if let index = sets.firstIndex(where: { $0.id == set.id }) {
                sets[index] = set
            } else {
                sets.append(set)
            }
        }

        let goneLicenses = Set(counterpart.licenses.map(\.id))
            .subtracting(restored.licenses.map(\.id))
        licenses.removeAll { goneLicenses.contains($0.id) }
        for license in restored.licenses {
            if let index = licenses.firstIndex(where: { $0.id == license.id }) {
                licenses[index] = license
            } else {
                licenses.append(license)
            }
        }

        let goneSmart = Set(counterpart.smartSets.map(\.id))
            .subtracting(restored.smartSets.map(\.id))
        smartSets.removeAll { goneSmart.contains($0.id) }
        if case .smart(let id) = sidebar, goneSmart.contains(id) { sidebar = .all }
        for smart in restored.smartSets {
            if let index = smartSets.firstIndex(where: { $0.id == smart.id }) {
                smartSets[index] = smart
            } else {
                smartSets.append(smart)
            }
        }

        if !missing.isEmpty {
            notice = Notice(
                title: "Some icons came back without their files",
                message: "Their files are no longer in the Trash:\n" + Self.listed(missing)
            )
        }
        save()
        register(step, undoing: !undoing)
    }

    /// Moves the icons' library files to the Trash, keeping where each landed so they can come
    /// back. A volume without a Trash falls back to deleting, and such an icon would return
    /// fileless.
    private func trashFiles(of icons: [Icon], into trashed: inout [UUID: URL]) {
        for icon in icons {
            let url = fileURL(for: icon)
            var landed: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                if let landed { trashed[icon.id] = landed as URL }
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Icons

    func update(_ ids: Set<UUID>, _ change: (inout Icon) -> Void) {
        for index in icons.indices where ids.contains(icons[index].id) {
            change(&icons[index])
        }
        save()
    }

    func move(_ ids: Set<UUID>, to setID: UUID) {
        recording("Move to Set") { update(ids) { $0.setID = setID } }
    }

    /// Whether the menu bar offers Unstar: only when every selected icon is starred.
    var selectionAllStarred: Bool {
        let chosen = icons.filter { selection.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.starred)
    }

    func clearRecents() {
        recording("Clear Recently Used") {
            update(Set(icons.filter { $0.lastUsed != nil }.map(\.id))) { $0.lastUsed = nil }
        }
    }

    func toggleStar(_ ids: Set<UUID>) {
        let star = !icons.filter { ids.contains($0.id) }.allSatisfy(\.starred)
        recording(star ? "Star" : "Unstar") { update(ids) { $0.starred = star } }
    }

    /// The selection in the order `batchRename` applies: the grid's order, which in Recently
    /// Used is by last use rather than the toolbar's sort. The rename sheet's preview reads
    /// this too, so the numbers it shows are the numbers Sequence gives.
    var batchRenameTargets: [Icon] {
        visibleIcons.filter { selection.contains($0.id) }
    }

    /// Renames the selection in grid order through `rename.newName`, as one undoable step.
    /// Icons it answers nil, an empty name or the same name for keep theirs.
    func batchRename(_ ids: Set<UUID>, applying rename: BatchRename) {
        let items = visibleIcons.filter { ids.contains($0.id) }
        recording("Rename") {
            for (index, icon) in items.enumerated() {
                guard let raw = rename.newName(for: icon.name, index: index) else { continue }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != icon.name,
                      let at = icons.firstIndex(where: { $0.id == icon.id })
                else { continue }
                icons[at].name = name
            }
            save()
        }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        recording("Rename") { update([id]) { $0.name = name } }
        revealed = id
    }

    func setTags(_ id: UUID, _ tags: [String]) {
        let tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The tag field reports whenever it loses focus, changed or not.
        guard icons.first(where: { $0.id == id })?.tags != tags else { return }
        recording("Change Tags") { update([id]) { $0.tags = tags } }
    }

    func setInfo(_ id: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        recording("Change Description") { update([id]) { $0.info = text.isEmpty ? nil : text } }
    }

    /// Adds `tags` to every icon in `ids` that doesn't already carry them.
    func addTags(_ ids: Set<UUID>, _ tags: [String]) {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        recording("Add Tags") {
            update(ids) { icon in
                for tag in cleaned where !icon.tags.contains(tag) { icon.tags.append(tag) }
            }
        }
    }

    func removeTag(_ ids: Set<UUID>, _ tag: String) {
        recording("Remove Tag") { update(ids) { $0.tags.removeAll { $0 == tag } } }
    }

    func setLicense(_ ids: Set<UUID>, _ licenseID: UUID?) {
        recording("Change License") { update(ids) { $0.licenseID = licenseID } }
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
        settle(on: visible[index + offset].id, in: visible, extending: false)
    }

    /// The grid's arrow keys: from the icon last clicked, or the first icon when none is
    /// selected. Returns the icon selected, for the grid to scroll to.
    @discardableResult
    func moveSelection(by offset: Int, extending: Bool = false) -> UUID? {
        let visible = visibleIcons
        let current = focusID.flatMap { selection.contains($0) ? $0 : nil }
            ?? anchor.flatMap { selection.contains($0) ? $0 : nil }
            ?? selectedIcons.first?.id
        guard let current, let index = visible.firstIndex(where: { $0.id == current }) else {
            guard let first = visible.first?.id else { return nil }
            settle(on: first, in: visible, extending: false)
            return first
        }
        guard visible.indices.contains(index + offset) else { return current }
        let next = visible[index + offset].id
        settle(on: next, in: visible, extending: extending)
        return next
    }

    /// Home and End: the first or last icon, or everything from the anchor to it with ⇧ held.
    func selectEnd(_ last: Bool, extending: Bool = false) -> UUID? {
        let visible = visibleIcons
        guard let target = (last ? visible.last : visible.first)?.id else { return nil }
        settle(on: target, in: visible, extending: extending)
        return target
    }

    /// Finder's type-to-select: letters typed within a second join into a prefix, and the first
    /// icon whose name starts with it is selected.
    func typeToSelect(_ characters: String) -> UUID? {
        let now = Date()
        typeAhead = (now < typeAheadExpiry ? typeAhead : "") + characters.lowercased()
        typeAheadExpiry = now.addingTimeInterval(1)
        let visible = visibleIcons
        guard let match = visible.first(where: { $0.name.lowercased().hasPrefix(typeAhead) })
        else { return nil }
        settle(on: match.id, in: visible, extending: false)
        return match.id
    }

    /// Moves the keyboard caret to `target`: extending selects the anchor through the caret, as
    /// Finder does; otherwise the selection becomes the caret alone and anchors there.
    private func settle(on target: UUID, in visible: [Icon], extending: Bool) {
        focusID = target
        if extending, let anchor, let from = visible.firstIndex(where: { $0.id == anchor }),
           let to = visible.firstIndex(where: { $0.id == target }) {
            selection = Set(visible[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [target]
            anchor = target
        }
    }

    func selectAll() {
        selection = Set(visibleIcons.map(\.id))
    }

    // MARK: Check Library

    /// What a check found: icons sharing one file content, records whose files are gone, and
    /// files in the icons folder no record names. Presented as a sheet while non-nil.
    struct LibraryCheck: Sendable {
        var duplicateGroups: [[Icon]] = []
        var missing: [Icon] = []
        var orphans: [URL] = []
        var isClean: Bool { duplicateGroups.isEmpty && missing.isEmpty && orphans.isEmpty }
    }

    var check: LibraryCheck?
    private(set) var isChecking = false

    /// Reads and hashes every same-sized pair of files, so it runs off the main actor and only
    /// when asked: the import-time duplicate check never sees what came before it or through an
    /// IconJar import.
    func checkLibrary() async {
        guard !isChecking, !followMovedFolder() else { return }
        isChecking = true
        let scanned = self.folder
        let snapshot = icons
        let folder = iconsFolder
        let result = await Task.detached(priority: .userInitiated) {
            Self.scan(icons: snapshot, folder: folder)
        }.value
        isChecking = false
        // A switch or a move in Finder while it ran leaves results about a folder that is no
        // longer this library's, and acting on them would trash or drop the wrong things.
        guard self.folder == scanned else { return }
        check = result
    }

    private nonisolated static func scan(icons: [Icon], folder: URL) -> LibraryCheck {
        var check = LibraryCheck()
        let manager = FileManager.default
        var bySize: [Int: [(icon: Icon, url: URL)]] = [:]
        for icon in icons {
            let url = folder.appending(path: icon.fileName)
            // fileExists follows links; the size alone is the link's own, so a dangling one passes.
            guard manager.fileExists(atPath: url.path(percentEncoded: false)),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            else {
                check.missing.append(icon)
                continue
            }
            bySize[size, default: []].append((icon, url))
        }
        for group in bySize.values where group.count > 1 {
            var byHash: [Data: [Icon]] = [:]
            for entry in group {
                guard let data = try? Data(contentsOf: entry.url) else { continue }
                byHash[Data(SHA256.hash(data: data)), default: []].append(entry.icon)
            }
            for dupes in byHash.values where dupes.count > 1 {
                // Oldest first, so "keep the oldest" keeps the original.
                check.duplicateGroups.append(dupes.sorted { $0.added < $1.added })
            }
        }
        check.duplicateGroups.sort {
            ($0.first?.name ?? "").localizedStandardCompare($1.first?.name ?? "")
                == .orderedAscending
        }
        check.missing.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let known = Set(icons.map(\.fileName))
        let contents = (try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        check.orphans = contents
            .filter { !known.contains($0.lastPathComponent) && !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return check
    }

    /// Keeps the oldest surviving copy of each group and deletes the rest, as one undoable step.
    /// The check ran on a snapshot, so icons deleted or undone since drop out first: without
    /// that, losing the oldest copy mid-scan would delete every remaining one.
    func deleteDuplicates() {
        let present = Set(icons.map(\.id))
        let extras = (check?.duplicateGroups ?? []).flatMap {
            $0.filter { present.contains($0.id) }.dropFirst().map(\.id)
        }
        guard !extras.isEmpty else { return }
        recording("Delete Duplicates") {
            removeIcons(Set(extras))
            save()
        }
        check?.duplicateGroups = []
    }

    /// Drops the records whose files are gone; there is nothing left to show for them. A file
    /// that has turned up since the scan — undo, or a copy back into the folder — keeps its
    /// record.
    func removeMissingRecords() {
        guard !followMovedFolder() else { return }
        let gone = (check?.missing ?? []).filter {
            !FileManager.default.fileExists(
                atPath: fileURL(for: $0).path(percentEncoded: false)
            )
        }
        guard !gone.isEmpty else { return }
        recording("Remove Missing Icons") {
            removeIcons(Set(gone.map(\.id)))
            save()
        }
        check?.missing = []
    }

    /// Files no record names go to the Trash, like any other file an edit removes. Checked
    /// against the live library at the moment of trashing, not the scan's snapshot: an icon
    /// imported while the scan ran looks like an orphan to the snapshot, and trashing its
    /// file would break it with no undo.
    func trashOrphans() {
        guard !followMovedFolder() else { return }
        let known = Set(icons.map(\.fileName))
        var failed: [URL] = []
        var firstError: Error?
        for url in check?.orphans ?? [] where !known.contains(url.lastPathComponent) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failed.append(url)
                firstError = firstError ?? error
            }
        }
        // What couldn't be moved stays listed, so it can be tried again.
        check?.orphans = failed
        if let firstError {
            notice = Notice(
                title: "Some files could not be moved to the Trash",
                message: "\(plural(failed.count, "file")) couldn't be moved. "
                    + firstError.localizedDescription
            )
        }
    }

    // MARK: Licences

    @discardableResult
    func addLicense() -> License {
        recording("Add License") {
            let license = License(name: "New License", url: "")
            licenses.append(license)
            save()
            return license
        }
    }

    func updateLicense(_ license: License) {
        guard let index = licenses.firstIndex(where: { $0.id == license.id }) else { return }
        recording("Change License") {
            licenses[index] = license
            save()
        }
    }

    /// Icons that carried the licence go back to having none.
    func removeLicense(_ id: UUID) {
        recording("Remove License") {
            licenses.removeAll { $0.id == id }
            for index in icons.indices where icons[index].licenseID == id {
                icons[index].licenseID = nil
            }
            save()
        }
    }

    // MARK: Open In

    /// Where Open In puts its copies. Emptied at launch.
    nonisolated(unsafe) static var openRoot = FileManager.default.temporaryDirectory
        .appending(path: "IconeryOpen", directoryHint: .isDirectory)

    /// The folder the last Quick Look press filled, so the next press can remove it.
    @ObservationIgnored private var quickLookFolder: URL?

    /// Copies for Quick Look, named after the icons so the panel's title is the name rather
    /// than the library's id-named file, in the grid's order so its arrows walk the selection
    /// as the grid shows it. Previewing isn't using, so Recently Used is left alone. Each press
    /// replaces the last one's folder instead of leaving another full set until relaunch, and
    /// copyItem clones on APFS, where reading every file into memory cost 540 ms for 3,000.
    func quickLookURLs(for ids: Set<UUID>) -> [URL] {
        let shown = visibleIcons.filter { ids.contains($0.id) }
        if let previous = quickLookFolder { try? FileManager.default.removeItem(at: previous) }
        let folder = Self.openRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        quickLookFolder = folder
        guard (try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )) != nil else { return [] }
        return shown.compactMap { icon in
            let name = "\(Exporter.safeFileName(icon.name)).\(icon.kind.rawValue)"
            let copy = Exporter.uniqueURL(for: name, in: folder)
            return (try? FileManager.default.copyItem(at: fileURL(for: icon), to: copy)) != nil
                ? copy : nil
        }
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
        // Copying icons in would recreate the old path, or land them in the Trash.
        guard !followMovedFolder() else { return ImportReport() }
        return recording("Import") { importItemsNow(urls, into: target) }
    }

    private func importItemsNow(_ urls: [URL], into target: UUID?) -> ImportReport {
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
                let setID = target ?? looseFilesSetID(report: &report)
                add(url, to: setID, report: &report)
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
        // A backup lands here from the Dock icon or Finder's Open With. Importing it would
        // only report it as unreadable, so say how a restore actually works instead.
        let backups = urls.filter { $0.pathExtension.lowercased() == "iconerybackup" }
        for backup in backups {
            notice = Notice(
                title: "“\(backup.lastPathComponent)” is a backup",
                message: "To restore it, double-click it in Finder, which unpacks it into a "
                    + "folder, then open that folder with Settings ▸ Library ▸ Switch."
            )
        }
        let urls = urls.filter { $0.pathExtension.lowercased() != "iconerybackup" }
        // An IconJar library is a folder too, but it needs reading, not walking.
        let jars = urls.filter(IconJarLibrary.isLibrary)
        for jar in jars { notice = importIconJarWithNotice(jar, into: target) }
        let files = urls.filter { !IconJarLibrary.isLibrary($0) }
        guard !files.isEmpty else { return !jars.isEmpty || !backups.isEmpty }

        if let refusal = trashRefusal() {
            notice = refusal
            return false
        }
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
    /// How a sidebar set travels in a drag: a private scheme the drop side recognises, so the
    /// row's one URL drop target serves files, grid drags and sets alike.
    static func setDragURL(_ id: UUID) -> URL {
        URL(string: "iconery-set://\(id.uuidString)")!
    }

    private static func draggedSetID(_ url: URL) -> UUID? {
        url.scheme == "iconery-set" ? url.host().flatMap(UUID.init(uuidString:)) : nil
    }

    @discardableResult
    func handleDrop(_ urls: [URL], onto setID: UUID?) -> Bool {
        // A set dragged onto another nests it there; moveSet turns down a drop into the set's
        // own subtree. Anywhere without a set under it, nothing happens.
        if let dragged = urls.compactMap(Self.draggedSetID).first {
            guard let setID, dragged != setID else { return false }
            return moveSet(dragged, into: setID)
        }
        guard Self.isGridDrag(urls) else { return importAndReport(urls, into: setID) }
        guard let setID, let ids = draggingIDs else { return false }
        // The drag stamped Recently Used when it began, because a drop into Finder or another
        // app never reports back. Filing icons into a set isn't using them, so put the old
        // dates back — before recording, or the stamps would become part of the step and
        // undoing the move would re-stamp the icons.
        let before = draggedLastUsed
        update(ids) { if let old = before[$0.id] { $0.lastUsed = old } }
        recording("Move to Set") {
            update(ids) { $0.setID = setID }
        }
        return true
    }

    /// Whether `urls` are a drag that began in the grid: files staged under dragRoot.
    /// resolvingSymlinksInPath on both sides, because a dropped URL may come back as
    /// /private/var/... while temporaryDirectory says /var/...
    nonisolated static func isGridDrag(_ urls: [URL]) -> Bool {
        let dragRoot = Exporter.dragRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        return urls.contains {
            $0.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(dragRoot)
        }
    }

    private func add(_ link: URL, to setID: UUID, report: inout ImportReport) {
        // Icon themes like Papirus and Breeze alias icons with symlinks. Copying one as a link
        // leaves a dangling link here, or one that dies with its source, so everything below
        // reads and copies the file it points at. The name stays the link's own; the kind comes
        // from the target, or `a.png -> a.svg` would be stored as a .png holding SVG.
        let url = link.resolvingSymlinksInPath()
        // Duplicates first: checking one reads the file at most, and decoding it costs more.
        if IconKind(url: url) != nil, duplicates?.contains(url) == true {
            report.duplicates += 1
            return
        }
        guard let kind = IconKind(url: url), let image = NSImage(contentsOf: url),
              image.isValid, image.size.width > 0, image.size.height > 0
        else {
            report.skipped.append(link.lastPathComponent)
            return
        }
        let stem = link.deletingPathExtension().lastPathComponent
        var icon = Icon(name: stem, setID: setID, kind: kind)
        icon.originalName = stem
        if kind == .svg, preferences.readsSVGTitles,
           let text = (try? Data(contentsOf: url)).flatMap(Self.svgText) {
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
            report.skipped.append("\(link.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    /// The set Settings names for loose files, or "Unsorted" when it names none or that set is
    /// gone. An "Unsorted" made here joins the report, or an import whose every loose file is
    /// skipped would leave it standing empty.
    private func looseFilesSetID(report: inout ImportReport) -> UUID {
        if let id = preferences.looseFilesSetID, sets.contains(where: { $0.id == id }) { return id }
        // Without case, as uniqueSetName compares, or "unsorted" would breed "Unsorted 2", 3 ….
        let unsorted = sets.first { $0.name.lowercased() == "unsorted" && $0.parentID == nil }
        if let id = unsorted?.id { return id }
        let id = makeSet(named: "Unsorted", inside: nil).id
        report.allCreated.append(id)
        return id
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
        if let refusal = trashRefusal() { return refusal }
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
        guard !followMovedFolder() else { return ImportReport() }
        return try recording("Import") { try importIconJarNow(library, into: target) }
    }

    private func importIconJarNow(_ library: URL, into target: UUID?) throws -> ImportReport {
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
            var icon = Icon(
                id: id, name: item.name.flatMap { $0.isEmpty ? nil : $0 } ?? stem,
                setID: collection.set, kind: kind, tags: item.tags, starred: item.starred,
                added: item.added ?? .now, lastUsed: item.lastUsed
            )
            icon.originalName = stem
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

        static let backupInTrash = Problem(
            errorDescription: "The backup folder is in the Trash. Put it back, or choose another "
                + "in Settings."
        )

        static let backupInsideLibrary = Problem(
            errorDescription: "Backups can't be kept inside the library they back up."
        )

        /// The folder chosen for backups is gone, and the default one is not what was chosen.
        static let backupFolderMissing = Problem(
            errorDescription: "The backup folder couldn't be found. It may be on a drive that "
                + "isn't connected. Connect it, or choose another in Settings."
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

    private static let backupFolderMissingNotice = Notice(
        title: "Your backup folder couldn't be found",
        message: "It may be on a drive that isn't connected, or it was moved to the Trash. "
            + "Scheduled backups are paused until it's back, or until you choose another folder "
            + "in Settings."
    )

    nonisolated static let libraryKey = "libraryLocation"
    nonisolated static let backupKey = "backupLocation"
    nonisolated static let lastBackupKey = "lastBackup"
    /// Hidden file a backup folder gets once its older backups have been adopted. See
    /// `adoptLegacyBackups(in:)`.
    nonisolated static let adoptionMarkerName = ".iconery-adopted"
    nonisolated static let exportKey = "exportLocation"
    /// Where locations, the last backup and export settings are kept. Tests point it at a suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Locations are kept as bookmarks rather than paths, so a folder renamed or moved in Finder
    /// is still found.
    private static func storedURL(_ key: String) -> URL? {
        guard let bookmark = Self.defaults.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { remember(url, as: key) }
        return url
    }

    /// The backup folder chosen in Settings, or nil when it can't be found or has been thrown
    /// away: the bookmark follows it into the Trash, where backups would be written and pruned
    /// out of sight.
    private static func storedBackupFolder() -> URL? {
        guard let url = storedURL(backupKey), !isInTrash(url) else { return nil }
        return url
    }

    private static func remember(_ url: URL, as key: String) {
        Self.defaults.set(try? url.bookmarkData(), forKey: key)
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
        // A library folder that is a link (say to Dropbox) would otherwise have only the link
        // renamed, leaving the library where it was behind a link that points nowhere new.
        let link = folder
        let isLink = (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?
            .isSymbolicLink == true
        try FileManager.default.moveItem(at: link.resolvingSymlinksInPath(), to: target)
        if isLink, !FileManager.default.fileExists(atPath: link.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: link)  // it points at nothing now
        }
        folder = target
        folderBookmark = try? target.bookmarkData()
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
        folderBookmark = try? url.bookmarkData()
        // Results and warnings about the library left behind aren't this one's.
        check = nil
        warnedOfTrash = false
        sets = []
        licenses = License.starters
        icons = []
        // Not left for load() to replace: a library whose index can't be decoded would keep
        // this library's smart sets and save them into that one on its next edit.
        smartSets = []
        selection = []
        expandedSets = []
        sidebar = .all
        images.removeAllObjects()
        thumbnails.removeAllObjects()
        singleColors = [:]
        load()
        Self.remember(url, as: Self.libraryKey)
        openedFallbackLibrary = false  // wherever this leads is now deliberate
    }

    func changeBackupFolder(to url: URL) throws {
        guard !Self.isInside(url, folder) else {
            throw Problem.backupInsideLibrary
        }
        backupFolder = url
        backupFolderMissing = false
        Self.remember(url, as: Self.backupKey)
    }

    /// Looks again for the backup folder chosen in Settings and returns whether it is there.
    /// Done before every backup into it, not just after it went missing, because it can be
    /// renamed, moved or thrown away while the app runs, and writing to the remembered path
    /// would make a new folder there. A move or rename is followed; a folder that is gone or in
    /// the Trash pauses backups. True, with nothing to do, when none was ever chosen.
    private func resolveBackupFolder() -> Bool {
        guard Self.defaults.data(forKey: Self.backupKey) != nil else { return true }
        guard let url = Self.storedBackupFolder() else {
            if !backupFolderMissing { notice = Self.backupFolderMissingNotice }
            backupFolderMissing = true
            return false
        }
        if url != backupFolder || backupFolderMissing {
            backupFolder = url
            Self.remember(url, as: Self.backupKey)
        }
        backupFolderMissing = false
        return true
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

    /// Writes "Iconery Backup <date> at <time>.iconerybackup" into `destination`, then trims the
    /// folder to the number of backups Settings keeps. The file is a zip under Iconery's own type,
    /// declared in Info.plist as conforming to zip, so Archive Utility still unpacks it.
    @discardableResult
    func backUp(into destination: URL) async throws -> URL {
        var destination = destination
        // Asked for the folder Settings shows: make sure it is still where it was, and when it
        // is the default one standing in for a chosen folder that is gone, write there only if
        // the chosen one has come back.
        if destination == backupFolder {
            guard resolveBackupFolder() else { throw Problem.backupFolderMissing }
            destination = backupFolder
        }
        guard !Self.isInside(destination, folder) else { throw Problem.backupInsideLibrary }
        guard !Self.isInTrash(destination) else { throw Problem.backupInTrash }
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
        let name = "Iconery Backup \(stamp.string(from: .now)).iconerybackup"
        let url = Exporter.uniqueURL(for: name, in: destination)
        try await writeBackup(to: url)
        lastBackup = .now
        backupNames.append(url.lastPathComponent)
        adoptLegacyBackups(in: destination)
        let trashed = Self.pruneBackups(
            in: destination, keeping: preferences.backupsKept, owned: Set(backupNames)
        )
        // Also the names whose file is gone from this folder, deleted by hand in Finder or
        // written to another backup folder: pruning can never trash those, so they would pile
        // up in library.json for good.
        let present = Set(Self.backupFiles(in: destination).map(\.url.lastPathComponent))
        backupNames.removeAll { trashed.contains($0) || !present.contains($0) }
        save()
        return url
    }

    /// Backups from before each library kept its own list sit in the folder with nobody's name
    /// on them. The first library to back up into a folder takes them all, so they go on being
    /// pruned instead of piling up; anything later is told apart by the lists. A marker file in
    /// the folder says it has been done, so it holds per folder rather than per Mac, follows the
    /// folder if it is moved and syncs with it in iCloud Drive. If the marker can't be written
    /// the next library adopts again, which only means it may take another's recent backups.
    private func adoptLegacyBackups(in destination: URL) {
        let marker = destination.appending(path: Self.adoptionMarkerName)
        guard !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        else { return }
        let known = Set(backupNames)
        backupNames += Self.backupFiles(in: destination)
            .map(\.url.lastPathComponent)
            .filter { !known.contains($0) }
        try? Data().write(to: marker)
    }

    /// Zips the library folder exactly as it sits on disk (the index plus every icon file), so
    /// sets, nesting, tags and stars all survive and a restore is a straight swap back. `ditto`
    /// because it ships with macOS and Foundation has no zip writer. It runs while the window
    /// stays responsive: a library of large ICNS files takes a while to zip.
    func writeBackup(to url: URL, snapshotsIn parent: URL? = nil) async throws {
        save()  // the index on disk now matches what the window shows
        // The window staying responsive also means an import or delete can land mid-zip, and
        // ditto would archive half of each. So ditto reads a snapshot: copyItem clones on
        // APFS, and nothing else runs on this actor until the copy returns, so the snapshot
        // is the library at one instant. It is made on the library's own volume when that volume
        // can clone, because a clone can't cross volumes: a library on an external APFS drive
        // would otherwise be copied byte by byte to the boot disk, and a big one takes that
        // long with the window waiting. Where it can't (exFAT, SMB) the copy is a full one
        // either way, and making it there would need the library's size free on that volume
        // again, so it goes to the temporary folder instead.
        //
        // `parent` is for tests, which rely on it as they do on init's `folder:`: the other
        // places are hidden from a listing (TemporaryItems is behind a privacy prompt), so a
        // test could not see whether a failed copy left its snapshot behind.
        let clones = parent == nil
            && (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning == true
        let onLibraryVolume = clones ? (try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder,
            create: true
        )) : nil
        let snapshotRoot = onLibraryVolume ?? (parent ?? FileManager.default.temporaryDirectory)
            .appending(path: "iconery-snapshot-\(UUID().uuidString)")
        let snapshot = snapshotRoot.appending(path: folder.lastPathComponent)
        try FileManager.default.createDirectory(
            at: snapshotRoot, withIntermediateDirectories: true
        )
        // Registered before the copy: one that fails part way leaves a half-made snapshot.
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        try FileManager.default.copyItem(at: folder, to: snapshot)
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
            snapshot.path(percentEncoded: false), partial.path(percentEncoded: false),
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
    /// fished out. Leftover ".partial" files go too: one survives only when the app died
    /// mid-backup, and nothing else ever removes it. This library's own in-flight partial has
    /// already been renamed away, but a shared folder (iCloud) may hold another Mac's or
    /// library's, which ditto is still writing; one touched within the last hour is left.
    /// Only backups named in `owned` count, so another library's, or a user's own file with a
    /// name like one, is never trashed. Returns the names it trashed.
    @discardableResult
    static func pruneBackups(in folder: URL, keeping keep: Int, owned: Set<String>) -> [String] {
        var trashed: [String] = []
        for old in backupsToPrune(in: folder, keeping: keep, owned: owned) {
            if (try? FileManager.default.trashItem(at: old, resultingItemURL: nil)) != nil {
                trashed.append(old.lastPathComponent)
            }
        }
        let stale = Date.now.addingTimeInterval(-60 * 60)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter {
                let modified = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return $0.lastPathComponent.hasPrefix("Iconery Backup ")
                    && $0.pathExtension == "partial" && (modified ?? .distantPast) < stale
            }
        for leftover in leftovers {
            try? FileManager.default.trashItem(at: leftover, resultingItemURL: nil)
        }
        return trashed
    }

    /// The backups in `owned` that are in `folder` and older than the newest `keep`, ordered by
    /// the date in the name. Only names exactly the way `backUp(into:)` writes them count — a
    /// prefix match alone would let any "Iconery Backup …" file of the user's own sort as the newest and push a
    /// real backup out. The names sort as text until two backups land in the same second and
    /// `uniqueURL` adds " 2": a space sorts before a dot, so plain sorting would call the
    /// newer file older and trash it first; the counter is compared as the number it is.
    /// Backups made before they had their own type ended in .zip, and still count.
    /// 0 keeps everything.
    nonisolated static func backupsToPrune(
        in folder: URL, keeping keep: Int, owned: Set<String>
    ) -> [URL] {
        guard keep > 0 else { return [] }
        let backups = backupFiles(in: folder).filter { owned.contains($0.url.lastPathComponent) }
        return backups.dropLast(keep).map(\.url)
    }

    /// Every backup in `folder` named exactly as `backUp(into:)` names them, oldest first.
    nonisolated static func backupFiles(
        in folder: URL
    ) -> [(url: URL, stamp: Substring, clash: Int)] {
        let name =
            /^Iconery Backup (\d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2})(?: (\d+))?\.(?i:iconerybackup|zip)$/
        return ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? [])
            .compactMap { url -> (url: URL, stamp: Substring, clash: Int)? in
                guard let match = url.lastPathComponent.wholeMatch(of: name) else { return nil }
                return (url, match.1, match.2.flatMap { Int($0) } ?? 0)
            }
            .sorted { ($0.stamp, $0.clash) < ($1.stamp, $1.clash) }
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
        // Never while the default library is standing in for one that couldn't be found:
        // its backups would land beside the real library's and prune them to make room.
        guard let interval = preferences.backupSchedule.interval, !isBackingUp,
              !openedFallbackLibrary, !followMovedFolder()
        else { return }
        // A chosen folder that was unplugged is looked for again each time, so backups resume
        // by themselves when it's back; the alert at launch said they were paused.
        guard resolveBackupFolder() else { return }
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

    /// The formats exporting would write right now: the preset's outputs when one is active,
    /// or the picked format. The fill, background and quality controls follow this, because a
    /// preset keeps those settings while bringing formats of its own.
    var exportFormats: [ExportFormat] {
        activePreset.map { $0.outputs.map(\.format) } ?? [export.format]
    }

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
        // No prefix or suffix: the form's own apply on top of every preset, so keeping a copy
        // here would write them twice.
        let output = PresetOutput(
            format: export.format, sizes: export.sizes, includeSize: export.includeSize
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
            Self.defaults.removeObject(forKey: Self.exportKey)
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
        var exported: Set<UUID> = []
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
                if !urls.isEmpty { exported.insert(icon.id) }
            } catch {
                problems.append("\(icon.name): \(error.localizedDescription)")
            }
        }
        // Only icons that reached the disk were used; a failed one would otherwise jump into
        // Recently Used with nothing to show for it.
        update(exported) { $0.lastUsed = .now }
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

    /// SVG source as text: UTF-8, or UTF-16 with or without a byte order mark. Editors on
    /// Windows save the latter, and AppKit draws it, so reading only UTF-8 would fail on an icon
    /// that imported and shows fine. UTF-16 without a mark is also valid UTF-8, with a NUL after
    /// every ASCII character, so a UTF-8 reading that holds one is taken as UTF-16 instead.
    /// Foundation assumes big-endian when there's no mark, so little-endian is said outright:
    /// "<" then a NUL as the first two bytes.
    private nonisolated static func svgText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return text }
        let littleEndian = data.first.map { $0 != 0 } == true && data.dropFirst().first == 0
        return String(data: data, encoding: littleEndian ? .utf16LittleEndian : .utf16)
    }

    /// The icon's SVG source, for pasting straight into an editor or a design tool. The file as
    /// it is, not the cleaned-up copy an SVG export can write.
    func copySVGCode(_ icon: Icon) {
        guard icon.kind == .svg, let data = try? Data(contentsOf: fileURL(for: icon)),
              let text = Self.svgText(data)
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
        let settings = activePreset.map { export.outputs(of: $0) } ?? [export]
        let drawn = Exporter.transferFiles(
            items.map { ($0, fileURL(for: $0)) }, settings: settings
        )
        // Names are decided in selection order before anything is written, so a clash is renamed
        // the same way whichever core finished first.
        var missing: [String] = []
        var batches: [[ExportFile]] = []
        for (item, files) in zip(items, drawn) {
            guard let files else {
                missing.append(item.name)
                continue
            }
            batches.append(files)
        }
        let written = Exporter.write(batches: batches, to: folder).flatMap { $0 }
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
        // A file may match itself: dragging a library file back in (Reveal in Finder, then drop)
        // must count as a duplicate. Nothing is lost by it, since a URL is only checked before
        // it is inserted, and Check Library hashes with its own code.
        for other in sameSize where self.hash(of: other) == hash { return true }
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

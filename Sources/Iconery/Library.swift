import AppKit
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

    var sidebar: SidebarItem? = .all
    var expandedSets: Set<UUID> = []
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
    var pendingDeletion: Deletion?
    var notice: Notice?

    @ObservationIgnored private var anchor: UUID?
    @ObservationIgnored private var draggingIDs: Set<UUID>?
    private let images = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, CGImage>()
    /// nil inside means "looked, and it isn't one colour", so it is never worked out twice.
    @ObservationIgnored private var singleColors: [String: SIMD3<Double>?] = [:]

    /// Changes when the library is moved or switched in Settings.
    private(set) var folder: URL
    /// Where Back Up Now writes.
    private(set) var backupFolder: URL
    private(set) var lastBackup: Date?
    var iconsFolder: URL { folder.appending(path: "Icons", directoryHint: .isDirectory) }
    private var indexURL: URL { folder.appending(path: "library.json") }

    static let recentLimit = 100

    /// Opens the library chosen in Settings, or the default one. Passing `folder` opens that
    /// library instead and ignores the remembered one, which tests rely on.
    init(folder: URL? = nil) {
        let remembered = Self.storedURL(Self.libraryKey)
        self.folder = folder ?? remembered ?? Self.defaultFolder
        backupFolder = Self.storedURL(Self.backupKey) ?? Self.defaultBackupFolder
        lastBackup = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date
        load()
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
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let index = try decoder.decode(Index.self, from: data)
            sets = index.sets
            icons = index.icons
            licenses = index.licenses ?? License.starters
            // A set whose parent is gone would never be drawn; lift it to the top level instead.
            let ids = Set(sets.map(\.id))
            for i in sets.indices where sets[i].parentID.map({ !ids.contains($0) }) == true {
                sets[i].parentID = nil
            }
        } catch {
            // Set an unreadable index aside before anything saves an empty library over it.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = folder.appending(path: "library-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            notice = Notice(
                title: "The library could not be read",
                message: "It was moved to \(aside.path(percentEncoded: false)) and an empty "
                    + "library opened in its place. \(error.localizedDescription)"
            )
        }
    }

    private func save() {
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
        sets.filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
            for child in sets where child.parentID == current {
                result.insert(child.id)
                pending.append(child.id)
            }
        }
        return result
    }

    /// A set shows its own icons and those of every set inside it, as IconJar's groups do.
    func icons(in item: SidebarItem?) -> [Icon] {
        switch item {
        case .all, nil:
            icons.sorted(by: Self.byName)
        case .starred:
            icons.filter(\.starred).sorted(by: Self.byName)
        case .recent:
            Array(
                icons.filter { $0.lastUsed != nil }
                    .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
                    .prefix(Self.recentLimit)
            )
        case .set(let id):
            icons.filter(isInside(id)).sorted(by: Self.byName)
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
        case .recent: min(icons.count { $0.lastUsed != nil }, Self.recentLimit)
        case .set(let id): icons.count(where: isInside(id))
        }
    }

    var visibleIcons: [Icon] {
        let setNames = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.name) })
        return icons(in: sidebar).filter {
            iconMatches($0, query: searchText, setName: setNames[$0.setID] ?? "")
        }
    }

    var selectedIcons: [Icon] {
        icons.filter { selection.contains($0.id) }.sorted(by: Self.byName)
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
        thumbnails.setObject(raster, forKey: key)
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

    func finishNaming(_ naming: Naming) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch naming {
        case .newSet(let parent): sidebar = .set(createSet(named: name, inside: parent).id)
        case .renameSet(let id): renameSet(id, to: name)
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

    func toggleStar(_ ids: Set<UUID>) {
        let star = !icons.filter { ids.contains($0.id) }.allSatisfy(\.starred)
        update(ids) { $0.starred = star }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update([id]) { $0.name = name }
    }

    func setTags(_ id: UUID, _ tags: [String]) {
        let tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
        var createdSets: [UUID] = []
    }

    /// A folder becomes a set named after it, inside `target` when there is one, and each
    /// subfolder holding icons becomes a set inside that, mirroring the tree on disk. Loose files
    /// go into `target`, or into "Unsorted" when no set is selected.
    @discardableResult
    func importItems(_ urls: [URL], into target: UUID?) -> ImportReport {
        var report = ImportReport()
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard let folder = Self.scan(url) else {
                    report.skipped.append("\(url.lastPathComponent) (no icon files inside)")
                    continue
                }
                report.createdSets.append(importFolder(folder, inside: target, report: &report))
            } else {
                add(url, to: target ?? unsortedSetID(), report: &report)
            }
        }
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
        if !report.skipped.isEmpty {
            notice = Notice(
                title: "Imported \(plural(report.imported, "icon"))",
                message: "Skipped what isn't a readable SVG, PNG, ICNS or ICO:\n"
                    + Self.listed(report.skipped)
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
        move(ids, to: setID)
        return true
    }

    private func add(_ url: URL, to setID: UUID, report: inout ImportReport) {
        guard let kind = IconKind(url: url), let image = NSImage(contentsOf: url),
              image.isValid, image.size.width > 0, image.size.height > 0
        else {
            report.skipped.append(url.lastPathComponent)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let icon = Icon(name: name, setID: setID, kind: kind)
        do {
            try FileManager.default.createDirectory(
                at: iconsFolder, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: fileURL(for: icon))
            icons.append(icon)
            report.imported += 1
        } catch {
            report.skipped.append("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
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
            guard let collection = collections[item.collection] else { continue }
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
        do {
            let url = try backUp(into: backupFolder)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            notice = Notice(
                title: "The backup could not be written", message: error.localizedDescription
            )
        }
    }

    /// Writes "Iconery Backup <date> at <time>.zip" into `destination`.
    @discardableResult
    func backUp(into destination: URL) throws -> URL {
        guard !Self.isInside(destination, folder) else {
            throw Problem.backupInsideLibrary
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // Sorts by name in date order, and has no colon, which a file name can't hold.
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Iconery Backup \(stamp.string(from: .now)).zip"
        let url = Exporter.uniqueURL(for: name, in: destination)
        try writeBackup(to: url)
        lastBackup = .now
        UserDefaults.standard.set(lastBackup, forKey: Self.lastBackupKey)
        return url
    }

    /// Zips the library folder exactly as it sits on disk (the index plus every icon file), so
    /// sets, nesting, tags and stars all survive and a restore is a straight swap back. `ditto`
    /// because it ships with macOS and Foundation has no zip writer.
    func writeBackup(to url: URL) throws {
        save()  // the index on disk now matches what the window shows
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        // --keepParent puts the folder itself at the top of the archive, not its contents loose.
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            folder.path(percentEncoded: false), url.path(percentEncoded: false),
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        // Read before waiting: a full pipe would otherwise stall ditto while it waits on us.
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Problem(errorDescription: String(decoding: message, as: UTF8.self))
        }
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

    func exportSelection() {
        let targets = selectedIcons
        guard !targets.isEmpty, canExport else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        let way = activePreset?.name ?? export.format.title
        panel.message = "Choose where to save \(plural(targets.count, "icon")) as \(way)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var written: [URL] = []
        var problems: [String] = []
        for icon in targets {
            do {
                written += try Exporter.write(exportFiles(for: icon), to: folder)
            } catch {
                problems.append("\(icon.name): \(error.localizedDescription)")
            }
        }
        update(Set(targets.map(\.id))) { $0.lastUsed = .now }
        if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
        if !problems.isEmpty {
            notice = Notice(
                title: "Exported \(plural(written.count, "file"))",
                message: problems.joined(separator: "\n")
            )
        }
    }

    /// The drag carries real files, exported with the inspector's current settings, so Finder,
    /// Figma or an editor gets exactly what Export would have written. IconJar calls this
    /// QuickDrag. A drag of several icons, or of one icon in several sizes, carries one folder.
    func dragProvider(for icon: Icon, alone: Bool = false) -> NSItemProvider {
        let ids = alone ? [icon.id] : targets(for: icon)
        draggingIDs = ids
        let dragged = icons.filter { ids.contains($0.id) }
        let folder = Exporter.dragRoot
            .appending(path: UUID().uuidString)
            .appending(path: dragged.count == 1 ? Exporter.safeFileName(icon.name) : "Icons")
        var written: [URL] = []
        for item in dragged {
            let source = fileURL(for: item)
            // Something must always land under dragRoot, or a drop onto a set could not be told
            // apart from an import. When the export fails, the original file travels instead.
            let files = (try? exportFiles(for: item)) ?? [ExportFile(
                name: "\(Exporter.safeFileName(item.name)).\(item.kind.rawValue)",
                data: (try? Data(contentsOf: source)) ?? Data()
            )]
            written += (try? Exporter.write(files, to: folder)) ?? []
        }
        update(ids) { $0.lastUsed = .now }
        let payload = written.count == 1 ? written[0] : folder
        return NSItemProvider(contentsOf: payload) ?? NSItemProvider()
    }
}

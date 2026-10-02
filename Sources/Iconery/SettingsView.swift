import AppKit
import SwiftUI

enum Appearance: String {
    case system, light, dark

    static let key = "appearance"
    /// Read by IconTile, which is where the contrast fix shows.
    static let improveContrastKey = "improveIconContrast"

    static var saved: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Set on the application rather than per window, so Settings, panels and alerts all follow.
    @MainActor
    func apply() {
        NSApplication.shared.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Laid out like IconJar's preferences: tabs of right-aligned labels beside their controls.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            ImportSettings()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
            ExportSettings()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 640)
    }
}

/// One tab: right-aligned labels in the first column, controls beside them.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 18) {
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

@MainActor
private func settingsLabel(_ title: String) -> some View {
    Text(title)
        .font(.title3)
        .gridColumnAlignment(.trailing)
}

@MainActor
private func settingsNote(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

@MainActor
private func chooseFolder(prompt: String, message: String, startingAt start: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.message = message
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
}

private struct GeneralSettings: View {
    @Environment(Library.self) private var library
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Appearance.improveContrastKey) private var improveContrast = true

    var body: some View {
        @Bindable var preferences = library.preferences
        SettingsPage {
            GridRow {
                settingsLabel("Appearance")
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Set appearance automatically", isOn: automatic)
                    // Indented to the checkbox's text, as in IconJar.
                    HStack(spacing: 22) {
                        choice("Light", .light)
                        choice("Dark", .dark)
                    }
                    .padding(.leading, 20)
                    .disabled(appearance == .system)
                    Toggle("Improve icon contrast", isOn: $improveContrast)
                    settingsNote(
                        "This only changes SVGs drawn in one color, and only on screen: one too "
                            + "faint against the background is drawn in black or white instead. "
                            + "Exports are untouched."
                    )
                    .padding(.leading, 20)
                }
            }
            Divider()
            GridRow {
                settingsLabel("Grid")
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Sort by", selection: $preferences.sort) {
                        ForEach(GridSort.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Picker("Show names", selection: $preferences.labels) {
                        ForEach(LabelMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("Recently Used keeps", selection: $preferences.recentLimit) {
                        ForEach(Preferences.recentLimits, id: \.self) { limit in
                            Text("\(limit) icons").tag(limit)
                        }
                    }
                    .fixedSize()
                }
            }
            Divider()
            GridRow {
                settingsLabel("Search")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Tags", isOn: $preferences.searchesTags)
                    Toggle("Set names", isOn: $preferences.searchesSetNames)
                    Toggle("Descriptions", isOn: $preferences.searchesDescriptions)
                    settingsNote(
                        "Names are always searched. Every word you type has to turn up in one of "
                            + "them, so each word narrows the grid."
                    )
                }
            }
            Divider()
            GridRow {
                settingsLabel("Deleting")
                Toggle("Ask before deleting icons", isOn: $preferences.confirmsIconDeletion)
            }
        }
        .onChange(of: appearance) { appearance.apply() }
    }

    private func choice(_ title: String, _ option: Appearance) -> some View {
        AppearanceChoice(title: title, dark: option == .dark, isChosen: appearance == option) {
            appearance = option
        }
    }

    /// Turning automatic off keeps whichever appearance macOS is showing, so nothing flips.
    private var automatic: Binding<Bool> {
        Binding(
            get: { appearance == .system },
            set: { isAutomatic in
                if isAutomatic {
                    appearance = .system
                } else {
                    let current = NSApplication.shared.effectiveAppearance
                        .bestMatch(from: [.aqua, .darkAqua])
                    appearance = current == .darkAqua ? .dark : .light
                }
            }
        )
    }
}

private struct LibrarySettings: View {
    @Environment(Library.self) private var library
    /// Shown here rather than on the main window, which may be behind Settings.
    @State private var notice: Notice?

    var body: some View {
        @Bindable var preferences = library.preferences
        SettingsPage {
            GridRow {
                settingsLabel("Library")
                VStack(alignment: .leading, spacing: 10) {
                    PathControl(url: library.folder)
                    HStack {
                        Button("Move…", action: moveLibrary)
                        Button("Switch…", action: switchLibrary)
                    }
                    settingsNote(
                        "Move takes the whole library to a folder you choose. Switch opens "
                            + "another Iconery library, such as a backup opened in Finder."
                    )
                }
            }
            Divider()
            GridRow {
                settingsLabel("Backups")
                VStack(alignment: .leading, spacing: 10) {
                    PathControl(url: library.backupFolder)
                    HStack {
                        Button("Change Backup Location…", action: changeBackupFolder)
                        Button("Back Up Now", action: backUpNow)
                            .disabled(library.isBackingUp)
                        if library.isBackingUp { ProgressView().controlSize(.small) }
                    }
                    Picker("Back up automatically", selection: $preferences.backupSchedule) {
                        ForEach(BackupSchedule.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Picker("Keep", selection: $preferences.backupsKept) {
                        ForEach(Preferences.backupCounts, id: \.self) { count in
                            Text(count == 0 ? "Every backup" : "The last \(count)").tag(count)
                        }
                    }
                    .fixedSize()
                    settingsNote(
                        (library.lastBackup.map {
                            "Last backed up \($0.formatted(date: .abbreviated, time: .shortened)). "
                        } ?? "Not backed up yet. ")
                            + "Backups past the number kept go to the Trash."
                    )
                }
            }
            Divider()
            GridRow {
                settingsLabel("IconJar")
                VStack(alignment: .leading, spacing: 10) {
                    Button("Import IconJar Library…", action: importIconJar)
                    settingsNote(
                        "Brings in an IconJar library or one of its backups (.ijlibrary). Its "
                            + "groups and sets become sets here, with names, tags and stars. "
                            + "Importing the same library again adds only what's new."
                    )
                }
            }
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private func moveLibrary() {
        guard let destination = chooseFolder(
            prompt: "Move Here",
            message: "Choose where the library goes. It moves there as “Iconery Library”, "
                + "with every icon.",
            startingAt: library.folder.deletingLastPathComponent()
        ) else { return }
        attempt("The library could not be moved") { try library.moveLibrary(into: destination) }
    }

    private func switchLibrary() {
        guard let folder = chooseFolder(
            prompt: "Switch",
            message: "Choose an Iconery library: a folder with library.json inside.",
            startingAt: library.folder.deletingLastPathComponent()
        ) else { return }
        attempt("That library could not be opened") { try library.switchLibrary(to: folder) }
    }

    private func changeBackupFolder() {
        guard let folder = chooseFolder(
            prompt: "Choose", message: "Choose where backups are saved.",
            startingAt: library.backupFolder
        ) else { return }
        attempt("Backups can't go there") { try library.changeBackupFolder(to: folder) }
    }

    private func backUpNow() {
        Task {
            do {
                let backup = try await library.backUp(into: library.backupFolder)
                NSWorkspace.shared.activateFileViewerSelecting([backup])
            } catch {
                notice = Notice(
                    title: "The backup could not be written", message: error.localizedDescription
                )
            }
        }
    }

    /// Into the top level: Settings has no selected set to import into.
    private func importIconJar() {
        guard let url = Library.chooseIconJarLibraryURL() else { return }
        notice = library.importIconJarWithNotice(url, into: nil)
    }

    private func attempt(_ title: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            notice = Notice(title: title, message: error.localizedDescription)
        }
    }
}

private struct ImportSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var preferences = library.preferences
        SettingsPage {
            GridRow {
                settingsLabel("Loose Files")
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Go into", selection: $preferences.looseFilesSetID) {
                        Text("Unsorted").tag(UUID?.none)
                        ForEach(library.setPaths, id: \.set.id) { entry in
                            Text(entry.path).tag(UUID?.some(entry.set.id))
                        }
                    }
                    .fixedSize()
                    settingsNote(
                        "Where files end up when they're imported with no set selected. A folder "
                            + "always becomes a set of its own."
                    )
                }
            }
            Divider()
            GridRow {
                settingsLabel("Duplicates")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Skip files already in the library", isOn: $preferences.skipsDuplicates)
                    settingsNote("Compared by content, so a renamed copy is still caught.")
                }
            }
            Divider()
            GridRow {
                settingsLabel("SVG Files")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Name icons from an SVG's title", isOn: $preferences.readsSVGTitles)
                    settingsNote(
                        "Uses the <title> inside the file as the icon's name and its <desc> as the "
                            + "description, as IconJar does."
                    )
                }
            }
        }
    }
}

private struct ExportSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        @Bindable var preferences = library.preferences
        SettingsPage {
            GridRow {
                settingsLabel("File Names")
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Name files after", selection: $library.export.naming) {
                        ForEach(ExportNaming.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    settingsNote(
                        "Tags are joined with hyphens. An icon without tags, or without an "
                            + "original file name on record, uses its name."
                    )
                }
            }
            Divider()
            GridRow {
                settingsLabel("Folders")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep set folders", isOn: $preferences.keepsSetFolders)
                    settingsNote(
                        "Exports each icon inside folders named after its sets, as IconJar's "
                            + "“Maintain set hierarchy” does."
                    )
                    Toggle("Add tags to exported files", isOn: $preferences.addsFinderTags)
                    settingsNote("The icon's tags become Finder tags on the files it exports.")
                }
            }
            Divider()
            GridRow {
                settingsLabel("Export To")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Ask where to export each time", isOn: asksEachTime)
                    if let folder = library.exportFolder {
                        PathControl(url: folder)
                        Button("Change Folder…", action: chooseExportFolder)
                    }
                    Toggle("Show exported files in Finder", isOn: $preferences.revealsExports)
                }
            }
            Divider()
            GridRow {
                settingsLabel("SVG Export")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Remove width and height", isOn: $library.export.svgCleanup.removesSize)
                    settingsNote(
                        "Lets the SVG scale to whatever holds it. A file without a viewBox gets "
                            + "one first, so it keeps its proportions."
                    )
                    Toggle("Remove comments", isOn: $library.export.svgCleanup.removesComments)
                    Toggle(
                        "Remove XML declaration",
                        isOn: $library.export.svgCleanup.removesDeclaration
                    )
                    Toggle("Compress", isOn: $library.export.svgCleanup.compresses)
                    settingsNote(
                        "Applies when exporting as SVG. Original always writes the file untouched."
                    )
                }
            }
        }
    }

    private var asksEachTime: Binding<Bool> {
        Binding(
            get: { library.exportFolder == nil },
            set: { asks in
                if asks {
                    library.setExportFolder(nil)
                } else {
                    chooseExportFolder()
                }
            }
        )
    }

    private func chooseExportFolder() {
        guard let folder = chooseFolder(
            prompt: "Choose", message: "Choose where Export saves files.",
            startingAt: library.exportFolder ?? URL.downloadsDirectory
        ) else { return }
        library.setExportFolder(folder)
    }
}

/// A picture of the app in one appearance, chosen by clicking it. Dimmed while the appearance is
/// automatic, as IconJar's are.
private struct AppearanceChoice: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let dark: Bool
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                WindowSketch(dark: dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 3)
                            .padding(-4)
                    }
                Text(title)
                    .foregroundStyle(isChosen ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// A small drawing of an app window over a desktop, light or dark, like the pictures in System
/// Settings and IconJar: traffic lights, a sidebar with a selected row, a grid of icons.
private struct WindowSketch: View {
    let dark: Bool

    var body: some View {
        let window = Color(white: dark ? 0.16 : 0.96)
        let sidebar = Color(white: dark ? 0.22 : 0.88)
        let cell = Color(white: dark ? 0.1 : 0.91)
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: dark ? Self.nightDesktop : Self.dayDesktop,
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2.5) {
                    ForEach(Self.trafficLights, id: \.self) { light in
                        Circle().fill(light).frame(width: 4, height: 4)
                    }
                }
                .padding(4)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 3)
                        .padding(3)
                        .frame(width: 20, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(sidebar)
                    Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                        ForEach(0..<4, id: \.self) { _ in
                            GridRow {
                                ForEach(0..<5, id: \.self) { _ in cell }
                            }
                        }
                    }
                    .padding(2)
                }
            }
            .frame(width: 64, height: 42)
            .background(window)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .offset(x: 12, y: 9)
        }
        .frame(width: 68, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private static let dayDesktop = [
        Color(red: 0.72, green: 0.78, blue: 0.86), Color(red: 0.86, green: 0.72, blue: 0.52),
    ]
    private static let nightDesktop = [
        Color(red: 0.2, green: 0.25, blue: 0.36), Color(red: 0.05, green: 0.06, blue: 0.1),
    ]
    private static let trafficLights = [
        Color(red: 1, green: 0.37, blue: 0.34),
        Color(red: 1, green: 0.74, blue: 0.18),
        Color(red: 0.16, green: 0.79, blue: 0.25),
    ]
}

/// AppKit's path control: the breadcrumb of folder icons IconJar's preferences show.
private struct PathControl: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        // A long path truncates its middle folders instead of widening the window.
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = url
    }
}

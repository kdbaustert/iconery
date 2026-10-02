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

/// Laid out like IconJar's preferences: right-aligned labels, a path control per location.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Appearance.improveContrastKey) private var improveContrast = true
    /// Shown here rather than on the main window, which may be behind Settings.
    @State private var notice: Notice?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 18) {
            GridRow {
                label("Appearance")
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
                    note(
                        "This only changes SVGs drawn in one colour, and only on screen: one too "
                            + "faint against the background is drawn in black or white instead. "
                            + "Exports are untouched."
                    )
                    .padding(.leading, 20)
                }
            }
            Divider()
            GridRow {
                label("Library")
                VStack(alignment: .leading, spacing: 10) {
                    PathControl(url: library.folder)
                    HStack {
                        Button("Move…", action: moveLibrary)
                        Button("Switch…", action: switchLibrary)
                    }
                    note(
                        "Move takes the whole library to a folder you choose. Switch opens "
                            + "another Iconery library, such as an unzipped backup."
                    )
                }
            }
            Divider()
            GridRow {
                label("Backup Location")
                VStack(alignment: .leading, spacing: 10) {
                    PathControl(url: library.backupFolder)
                    HStack {
                        Button("Change Backup Location…", action: changeBackupFolder)
                        Button("Back Up Now", action: backUpNow)
                    }
                    note(
                        library.lastBackup.map {
                            "Last backed up \($0.formatted(date: .abbreviated, time: .shortened))."
                        } ?? "Not backed up yet."
                    )
                }
            }
            Divider()
            GridRow {
                label("IconJar")
                VStack(alignment: .leading, spacing: 10) {
                    Button("Import IconJar Library…", action: importIconJar)
                    note(
                        "Brings in an IconJar library or one of its backups (.ijlibrary). Its "
                            + "groups and sets become sets here, with names, tags and stars. "
                            + "Importing the same library again adds only what's new."
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .onChange(of: appearance) { appearance.apply() }
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

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.title3)
            .gridColumnAlignment(.trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

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

    /// Into the top level: Settings has no selected set to import into.
    private func importIconJar() {
        guard let url = Library.chooseIconJarLibraryURL() else { return }
        notice = library.importIconJarWithNotice(url, into: nil)
    }

    private func backUpNow() {
        attempt("The backup could not be written") {
            let backup = try library.backUp(into: library.backupFolder)
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        }
    }

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

    private func attempt(_ title: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            notice = Notice(title: title, message: error.localizedDescription)
        }
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

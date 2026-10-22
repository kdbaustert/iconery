import SwiftUI

@main
struct IconeryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: Library
    @State private var keyWindow = KeyWindowWatcher()

    init() {
        // Before the first window draws, so a chosen Light or Dark never flashes the other.
        Appearance.saved.apply()
        let library = Library()
        _library = State(initialValue: library)
        appDelegate.library = library
    }

    var body: some Scene {
        Window("Iconery", id: "library") {
            ContentView()
                .environment(library)
                .frame(minWidth: 860, minHeight: 500)
        }
        Settings {
            SettingsView()
                .environment(library)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Set") { library.beginNewSet() }
                    .keyboardShortcut("n")
                Button(
                    library.currentSetID == nil
                        ? "New Set Inside…"
                        : "New Set Inside “\(library.title(for: library.sidebar))”"
                ) {
                    library.beginNewSet(inside: library.currentSetID)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(library.currentSetID == nil)
                Button("Save Search as Smart Set") { library.saveSearchAsSmartSet() }
                    .disabled(
                        library.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
            // The selection's commands, so they exist in the menu bar and not only on
            // right-click. Copy lives in Edit and lights up through the grid's onCopyCommand.
            CommandMenu("Icon") {
                Button(
                    library.selection.count > 1
                        ? "Rename \(library.selection.count) Icons…" : "Rename…"
                ) {
                    if library.selection.count > 1 {
                        library.batchRenaming = true
                    } else if let icon = library.selectedIcons.first {
                        library.beginRename(icon)
                    }
                }
                .disabled(library.selection.isEmpty)
                Button(library.selectionAllStarred ? "Unstar" : "Star") {
                    library.toggleStar(library.selection)
                }
                .disabled(library.selection.isEmpty)
                Divider()
                Button("Reveal in Finder") { library.revealInFinder(library.selection) }
                    .disabled(library.selection.isEmpty)
                Divider()
                Button(library.preferences.confirmsIconDeletion ? "Delete…" : "Delete") {
                    // ⌘⌫ reaches the menu before any other responder sees it. In a text field
                    // it means "delete to the start of the line" — typing an icon's name
                    // mustn't delete the selection — so the field editor gets it back.
                    let window = NSApp.keyWindow
                    if let editor = window?.firstResponder as? NSTextView {
                        editor.deleteToBeginningOfLine(nil)
                    } else if let window, window === AppDelegate.libraryWindow,
                              window.attachedSheet == nil {
                        library.requestDeleteIcons(library.selection)
                    }
                }
                .keyboardShortcut(.delete)
                // Off while a sheet, an alert or Settings is key: the icons behind them aren't
                // what the key means there, and nothing else would answer it.
                .disabled(library.selection.isEmpty || !keyWindow.libraryIsKey)
            }
            CommandGroup(replacing: .importExport) {
                Button("Import Icons…") { library.chooseAndImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import IconJar Library…") { library.chooseIconJarLibrary() }
                Button("Export Selected Icons…") { library.exportSelection() }
                    .keyboardShortcut("e")
                    .disabled(library.selection.isEmpty || !library.canExport)
                Divider()
                Button("Back Up Library Now") { library.backUpNow() }
                    .disabled(library.isBackingUp)
                Button("Check Library…") { Task { await library.checkLibrary() } }
                    .disabled(library.isChecking)
            }
        }
    }
}

/// Whether the library window is the key window, as something the menu bar can watch.
@MainActor
@Observable
final class KeyWindowWatcher {
    private(set) var libraryIsKey = false

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.libraryIsKey = NSApp.keyWindow === AppDelegate.libraryWindow
                }
            }
        }
    }
}

/// Takes files opened with Iconery: dropped on the Dock icon, or sent with Finder's Open With.
/// They go where the Import settings send loose files. An app launched by opening a file hears
/// about it before the scene exists, so the URLs wait until the library is wired up.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var library: Library? {
        didSet { deliver() }
    }
    /// The library's window, set by ContentView once it has one. Found by that rather than by
    /// an identifier or title, which SwiftUI picks and which Settings could share. Settings
    /// never hosts ContentView, so it can't be mistaken for the library.
    static weak var libraryWindow: NSWindow?
    private var waiting: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        waiting += urls
        deliver()
    }

    private func deliver() {
        guard let library, !waiting.isEmpty else { return }
        // Not the grid's own drags: a drag released on Iconery's Dock icon carries the staged
        // export, which would otherwise be imported back as a copy. The window's drop targets
        // turn these down the same way.
        let urls = waiting.filter { !Library.isGridDrag([$0]) }
        waiting = []
        guard !urls.isEmpty else { return }
        library.importAndReport(urls, into: nil)
    }
}

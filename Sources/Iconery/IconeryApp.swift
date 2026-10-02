import SwiftUI

@main
struct IconeryApp: App {
    @State private var library = Library()

    init() {
        // Before the first window draws, so a chosen Light or Dark never flashes the other.
        Appearance.saved.apply()
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
            }
        }
    }
}

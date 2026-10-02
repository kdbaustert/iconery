import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var showsInspector = true

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            IconGridView()
                .navigationTitle(library.title(for: library.sidebar))
                .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search")
                .toolbar {
                    ToolbarItem { SortMenu() }
                    ToolbarItem {
                        Button { library.chooseAndImport() } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help("Import SVG, PNG, ICNS or ICO files and folders")
                    }
                    ToolbarItem {
                        Button { showsInspector.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help(showsInspector ? "Hide the inspector" : "Show the inspector")
                    }
                }
                .inspector(isPresented: $showsInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 400)
                }
        }
        .onChange(of: library.sidebar) { library.selection = [] }
        .task { await library.runBackupSchedule() }
        .alert(
            library.naming?.title ?? "", isPresented: isPresent(\.naming),
            presenting: library.naming
        ) { naming in
            TextField("Name", text: $library.draftName)
            Button("Cancel", role: .cancel) {}
            Button(naming.confirmTitle) { library.finishNaming(naming) }
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(
            library.pendingDeletion?.title ?? "", isPresented: isPresent(\.pendingDeletion),
            titleVisibility: .visible, presenting: library.pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { library.perform(deletion) }
        } message: { deletion in
            Text(deletion.message)
        }
        .alert(
            library.notice?.title ?? "", isPresented: isPresent(\.notice),
            presenting: library.notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }

    /// Presents while the optional at `keyPath` holds a value, and clears it on dismissal.
    private func isPresent<Value>(
        _ keyPath: ReferenceWritableKeyPath<Library, Value?>
    ) -> Binding<Bool> {
        Binding(
            get: { library[keyPath: keyPath] != nil },
            set: { if !$0 { library[keyPath: keyPath] = nil } }
        )
    }
}

/// The toolbar's sort menu: the key and, under it, the direction, named for the key ("Z to A"
/// for names, "Newest First" for dates). Settings ▸ General keeps its sort picker; both read the
/// same preference, and picking a key resets the direction in Preferences itself.
private struct SortMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var preferences = library.preferences
        Menu {
            Picker("Sort By", selection: $preferences.sort) {
                ForEach(GridSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Direction", selection: $preferences.sortDescending) {
                Text(preferences.sort.ascendingTitle).tag(false)
                Text(preferences.sort.descendingTitle).tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("How the grid is sorted")
    }
}

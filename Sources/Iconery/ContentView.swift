import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undoManager
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
        // The window's undo manager, so Edit ▸ Undo reaches the library while text fields
        // keep their own.
        .onAppear { library.undoManager = undoManager }
        .onChange(of: undoManager) { library.undoManager = undoManager }
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
        .sheet(isPresented: isPresent(\.check)) { CheckResultsView() }
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

/// What Check Library found, with one fix per section. Each fix empties its section, so what
/// remains to do stays in front of you.
private struct CheckResultsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let check = library.check ?? .init()
        VStack(alignment: .leading, spacing: 14) {
            Text("Library Check")
                .font(.title3.bold())
            if check.isClean {
                Label("Nothing to fix. Every record has its file, every file its record, and no "
                      + "two icons share one content.", systemImage: "checkmark.seal")
            }
            if !check.duplicateGroups.isEmpty {
                section(
                    "\(plural(check.duplicateGroups.count, "group")) of identical icons",
                    names: check.duplicateGroups.map {
                        "\($0.first?.name ?? "") (\(plural($0.count, "copy", "copies")))"
                    },
                    fix: "Delete Duplicates, Keeping the Oldest",
                    action: library.deleteDuplicates
                )
            }
            if !check.missing.isEmpty {
                section(
                    "\(plural(check.missing.count, "icon")) missing their files",
                    names: check.missing.map(\.name),
                    fix: "Remove Their Records",
                    action: library.removeMissingRecords
                )
            }
            if !check.orphans.isEmpty {
                section(
                    "\(plural(check.orphans.count, "file")) no icon record names",
                    names: check.orphans.map(\.lastPathComponent),
                    fix: "Move Them to the Trash",
                    action: library.trashOrphans
                )
            }
            HStack {
                Spacer()
                Button("Done") { library.check = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func section(
        _ title: String, names: [String], fix: String, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            let shown = names.prefix(6).joined(separator: "\n")
                + (names.count > 6 ? "\n…and \(names.count - 6) more" : "")
            Text(shown)
                .foregroundStyle(.secondary)
                .font(.callout)
            Button(fix, action: action)
        }
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

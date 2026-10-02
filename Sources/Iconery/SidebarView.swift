import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    /// The tag list can dwarf the sets, so whether it's open is remembered.
    @AppStorage("sidebarShowsTags") private var showsTags = true

    var body: some View {
        @Bindable var library = library
        List(selection: $library.sidebar) {
            Section("Library") {
                row("All Icons", symbol: "square.grid.2x2", item: .all)
                row("Recently Used", symbol: "clock", item: .recent)
                    .contextMenu {
                        Button("Clear Recently Used") { library.clearRecents() }
                            .disabled(library.count(in: .recent) == 0)
                    }
                row("Starred", symbol: "star", item: .starred)
            }
            if !library.smartSets.isEmpty {
                Section("Smart Sets") {
                    ForEach(library.smartSets) { smart in
                        Label(smart.name, systemImage: "folder.badge.gearshape")
                            .badge(library.count(in: .smart(smart.id)))
                            .tag(SidebarItem.smart(smart.id))
                            .contextMenu {
                                Button("Rename…") { library.beginRename(smart) }
                                Button("Edit Query…") { library.beginEditQuery(smart) }
                                Button("Delete Smart Set", role: .destructive) {
                                    library.deleteSmartSet(smart.id)
                                }
                            }
                            .help(smart.query)
                    }
                }
            }
            Section("Sets") {
                ForEach(library.children(of: nil)) { SetTree(set: $0) }
            }
            let tags = library.tagCounts
            if !tags.isEmpty {
                Section("Tags", isExpanded: $showsTags) {
                    ForEach(tags, id: \.tag) { entry in
                        Label(entry.tag, systemImage: "tag")
                            .badge(entry.count)
                            .tag(SidebarItem.tag(entry.tag))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { library.beginNewSet() } label: {
                    Label("New Set", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func row(_ title: String, symbol: String, item: SidebarItem) -> some View {
        Label(title, systemImage: symbol)
            .badge(library.count(in: item))
            .tag(item)
    }
}

/// A set and, under a disclosure triangle, the sets inside it, recursively.
private struct SetTree: View {
    @Environment(Library.self) private var library
    let set: IconSet

    var body: some View {
        let children = library.children(of: set.id)
        if children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { SetTree(set: $0) }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        SetRow(set: set)
            .badge(library.count(in: .set(set.id)))
            .tag(SidebarItem.set(set.id))
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { library.expandedSets.contains(set.id) },
            set: { expanded in
                if expanded {
                    library.expandedSets.insert(set.id)
                } else {
                    library.expandedSets.remove(set.id)
                }
            }
        )
    }
}

/// A set takes drops: files and folders from Finder are imported into it, and icons dragged from
/// the grid move into it.
private struct SetRow: View {
    @Environment(Library.self) private var library
    @State private var isTargeted = false
    let set: IconSet

    var body: some View {
        Label(set.name, systemImage: "folder")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                library.handleDrop(urls, onto: set.id)
            } isTargeted: { isTargeted = $0 }
            .contextMenu {
                Button("New Set Inside…") { library.beginNewSet(inside: set.id) }
                Menu("Move To") {
                    Button("Top Level") { library.moveSet(set.id, into: nil) }
                        .disabled(set.parentID == nil)
                    Divider()
                    // Not into itself, nor into anything inside it.
                    let blocked = library.subtree(of: set.id)
                    let targets = library.setPaths.filter { !blocked.contains($0.set.id) }
                    ForEach(targets, id: \.set.id) { entry in
                        Button(entry.path) { library.moveSet(set.id, into: entry.set.id) }
                            .disabled(entry.set.id == set.parentID)
                    }
                }
                Divider()
                Button("Rename…") { library.beginRename(set) }
                Button("Delete Set…", role: .destructive) { library.requestDelete(set) }
            }
    }
}

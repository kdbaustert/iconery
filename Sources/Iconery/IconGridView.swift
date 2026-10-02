import SwiftUI

struct IconGridView: View {
    @Environment(Library.self) private var library
    // IconJar's grid zooms to 256pt; 24 is about the smallest an icon stays recognisable.
    @AppStorage("cellSize") private var cellSize = 64.0
    @State private var isDropTarget = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let icons = library.visibleIcons
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: cellSize + 36), spacing: 10, alignment: .top),
                ],
                spacing: 14
            ) {
                ForEach(icons) { icon in
                    IconCell(
                        icon: icon, size: cellSize, isSelected: library.selection.contains(icon.id)
                    )
                    .onTapGesture {
                        isFocused = true
                        library.click(icon.id, in: icons, modifiers: NSEvent.modifierFlags)
                    }
                    .onDrag { library.dragProvider(for: icon) }
                    .contextMenu { IconMenu(icon: icon) }
                }
            }
            .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            library.selection = []
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.delete) {
            guard !library.selection.isEmpty else { return .ignored }
            library.pendingDeletion = .icons(library.selection)
            return .handled
        }
        .overlay { emptyState(showing: icons) }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.handleDrop(urls, onto: library.currentSetID)
        } isTargeted: { isDropTarget = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(count: icons.count) }
    }

    @ViewBuilder
    private func emptyState(showing icons: [Icon]) -> some View {
        if library.icons.isEmpty {
            ContentUnavailableView {
                Label("No Icons Yet", systemImage: "square.grid.3x3")
            } description: {
                Text(
                    "Drag SVG, PNG, ICNS or ICO files or folders here. Each folder becomes a set."
                )
            } actions: {
                Button("Import Icons…") { library.chooseAndImport() }
            }
        } else if icons.isEmpty {
            if !library.searchText.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
            } else {
                switch library.sidebar {
                case .starred:
                    ContentUnavailableView(
                        "No Starred Icons", systemImage: "star",
                        description: Text(
                            "Star an icon from its right-click menu or the inspector."
                        )
                    )
                case .recent:
                    ContentUnavailableView(
                        "Nothing Used Yet", systemImage: "clock",
                        description: Text("Icons you export or drag out of the grid show up here.")
                    )
                default:
                    ContentUnavailableView(
                        "Empty Set", systemImage: "folder",
                        description: Text("Drag icon files here to add them to this set.")
                    )
                }
            }
        }
    }

    private func bottomBar(count: Int) -> some View {
        HStack(spacing: 10) {
            Text(
                library.selection.isEmpty
                    ? plural(count, "icon")
                    : "\(library.selection.count) of \(plural(count, "icon")) selected"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer()
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: $cellSize, in: 24...256)
                .controlSize(.small)
                .frame(width: 150)
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The background icons sit on in light and dark appearance, as sRGB greys: about the content
/// background macOS draws behind the grid. The contrast fix measures against these.
enum BackgroundShade {
    static let light = 1.0
    static let dark = 0.12
}

/// An icon on the window's own background, with no tile behind it. Shared by the grid and the
/// inspector's preview.
struct IconTile: View {
    @Environment(Library.self) private var library
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Appearance.improveContrastKey) private var improveContrast = true
    let icon: Icon
    let size: Double

    var body: some View {
        Group {
            if let image = library.thumbnail(
                for: icon, points: size, scale: displayScale, onDark: colorScheme == .dark,
                improveContrast: improveContrast
            ) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(max(6, size * 0.15))
    }
}

private struct IconCell: View {
    let icon: Icon
    let size: Double
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            IconTile(icon: icon, size: size)
                // Selection as Finder shows it: a soft highlight behind the icon, and the name in
                // the accent colour below.
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if icon.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .padding(5)
                    }
                }
            Text(icon.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(
                    isSelected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .frame(width: size + 36)
        .contentShape(Rectangle())
    }
}

private struct IconMenu: View {
    @Environment(Library.self) private var library
    let icon: Icon

    var body: some View {
        let targets = library.targets(for: icon)
        let allStarred = library.icons.filter { targets.contains($0.id) }.allSatisfy(\.starred)
        Button(allStarred ? "Unstar" : "Star") { library.toggleStar(targets) }
        Menu("Move to Set") {
            ForEach(library.setPaths, id: \.set.id) { entry in
                Button(entry.path) { library.move(targets, to: entry.set.id) }
            }
        }
        Button("Export…") {
            library.selection = targets
            library.exportSelection()
        }
        Divider()
        Button("Delete…", role: .destructive) { library.pendingDeletion = .icons(targets) }
    }
}

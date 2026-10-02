import SwiftUI

struct IconGridView: View {
    @Environment(Library.self) private var library
    // IconJar's grid zooms to 256pt; 24 is about the smallest an icon stays recognisable.
    @AppStorage("cellSize") private var cellSize = 64.0
    @State private var isDropTarget = false
    @FocusState private var isFocused: Bool
    /// The grid's width, for how many columns the up and down arrows jump.
    @State private var gridWidth = 0.0
    /// The icon the arrow keys last selected, kept in view as it changes.
    @State private var keyedID: UUID?
    private static let columnSpacing = 10.0

    var body: some View {
        let icons = library.visibleIcons
        let cellWidth = IconCell.width(for: cellSize)
        ScrollView {
            ScrollViewReader { proxy in
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: cellWidth), spacing: Self.columnSpacing,
                            alignment: .top
                        ),
                    ],
                    spacing: 14
                ) {
                    ForEach(icons) { icon in
                        IconCell(
                            icon: icon, size: cellSize, labels: library.preferences.labels,
                            isSelected: library.selection.contains(icon.id)
                        )
                        .onTapGesture {
                            isFocused = true
                            library.click(icon.id, in: icons, modifiers: NSEvent.modifierFlags)
                        }
                        .accessibilityAction { library.click(icon.id, in: icons, modifiers: []) }
                        .onDrag { library.dragProvider(for: icon) }
                        .contextMenu { IconMenu(icon: icon) }
                    }
                }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(16)
                .onChange(of: keyedID) { if let keyedID { proxy.scrollTo(keyedID) } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            library.selection = []
        }
        // A search, a move or an unstar can hide selected icons. They leave the selection, so
        // Delete and Export only ever act on icons that can be seen.
        .onChange(of: icons.map(\.id)) { _, visible in
            let kept = library.selection.intersection(visible)
            if kept.count < library.selection.count { library.selection = kept }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.delete) {
            guard !library.selection.isEmpty else { return .ignored }
            library.requestDeleteIcons(library.selection)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            // How an adaptive grid fits its columns.
            let fit = (gridWidth + Self.columnSpacing) / (cellWidth + Self.columnSpacing)
            let columns = max(1, Int(fit))
            let offset = switch press.key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -columns
            default: columns
            }
            keyedID = library.moveSelection(by: offset)
            return .handled
        }
        // Escape is the exit command on macOS.
        .onExitCommand { library.selection = [] }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            library.selectAll()
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
                .accessibilityHidden(true)
            Slider(value: $cellSize, in: 24...256)
                .controlSize(.small)
                .frame(width: 150)
                .accessibilityLabel("Icon size")
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
        .padding(Self.padding(for: size))
    }

    static func padding(for size: Double) -> Double { max(6, size * 0.15) }
}

private struct IconCell: View {
    let icon: Icon
    let size: Double
    let labels: LabelMode
    let isSelected: Bool
    @State private var isHovered = false

    /// Room for a short name under small icons, and for the tile's own padding under large ones,
    /// which past 120 pt is the wider of the two.
    static func width(for size: Double) -> Double {
        max(size + 36, size + 2 * IconTile.padding(for: size))
    }

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
            if labels != .never {
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
                    // On Hover keeps the label's space, so the grid doesn't shift under the
                    // pointer.
                    .opacity(labels == .always || isHovered || isSelected ? 1 : 0)
            }
        }
        .frame(width: Self.width(for: size))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // One element per icon for VoiceOver, named even when the label is hidden.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.name)
        .accessibilityValue(icon.starred ? "Starred" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
        let asks = library.preferences.confirmsIconDeletion
        Button(asks ? "Delete…" : "Delete", role: .destructive) {
            library.requestDeleteIcons(targets)
        }
    }
}

import AppKit
import SwiftUI

/// Laid out like IconJar's inspector: a preview you can drag out to export, with the size, format
/// and fill along its foot; the icon's details; its file information; and Open In.
struct InspectorView: View {
    @Environment(Library.self) private var library
    /// Which of several selected icons the preview shows.
    @State private var page = 0

    var body: some View {
        let selected = library.selectedIcons
        if selected.isEmpty {
            ContentUnavailableView(
                "No Selection", systemImage: "square.dashed",
                description: Text("Select icons to see their details and export them.")
            )
        } else {
            let index = min(page, selected.count - 1)
            let icon = selected[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PreviewHeader(
                        icon: icon, index: index, count: selected.count,
                        canStep: { canStep($0, icon: icon, index: index, count: selected.count) },
                        step: { step($0, icon: icon, index: index, count: selected.count) }
                    )
                    QuickDragWell(icon: icon)
                    ExportButton(icons: selected)
                    Divider().padding(.vertical, 2)
                    DetailsFields(icon: icon)
                        .id(icon.id)
                    if selected.count > 1 {
                        Divider().padding(.vertical, 2)
                        BulkFields(icons: selected)
                    }
                    InfoRows(icon: icon)
                    OpenInButton(icon: icon)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .onChange(of: library.selection) { page = 0 }
        }
    }

    /// With several selected the arrows page through them, as IconJar's do; with one they move
    /// to the next icon in the grid.
    private func step(_ offset: Int, icon: Icon, index: Int, count: Int) {
        if count > 1 {
            page = index + offset
        } else {
            library.selectNeighbour(of: icon.id, by: offset)
        }
    }

    private func canStep(_ offset: Int, icon: Icon, index: Int, count: Int) -> Bool {
        if count > 1 { return (0..<count).contains(index + offset) }
        let visible = library.visibleIcons
        guard let position = visible.firstIndex(where: { $0.id == icon.id }) else { return false }
        return visible.indices.contains(position + offset)
    }
}

private struct PreviewHeader: View {
    let icon: Icon
    let index: Int
    let count: Int
    let canStep: (Int) -> Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 1 ? "Preview – \(index + 1) of \(count)" : "Preview")
                    .font(.headline)
                Text(icon.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            ControlGroup {
                Button { step(-1) } label: {
                    Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .disabled(!canStep(-1))
                Button { step(1) } label: {
                    Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .disabled(!canStep(1))
            }
            .fixedSize()
            .help(count > 1 ? "Previous or next selected icon" : "Previous or next icon")
        }
    }
}

/// IconJar's QuickDrag: drag the preview out and it arrives exported with the settings below it.
private struct QuickDragWell: View {
    @Environment(Library.self) private var library
    let icon: Icon

    var body: some View {
        VStack(spacing: 0) {
            IconTile(icon: icon, size: 150)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
                .onDrag { library.dragProvider(for: icon, alone: true) }
                .help("Drag out to export with the settings below")
            ExportBar()
                .padding([.horizontal, .bottom], 10)
        }
        .background { DottedBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
    }
}

/// The dotted ground IconJar's preview sits on, so transparent parts read as transparent.
private struct DottedBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 9
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(0.14)))
                }
            }
        }
        .background(Color.primary.opacity(0.04))
    }
}

/// Size, format, fill and the remaining options, as one bar like IconJar's.
private struct ExportBar: View {
    @Environment(Library.self) private var library
    @State private var picksSizes = false
    @State private var showsOptions = false

    var body: some View {
        @Bindable var library = library
        let options = library.export
        HStack(spacing: 6) {
            Menu {
                ForEach(options.sizeChoices.filter(Self.quickSizes.contains), id: \.self) { size in
                    Button("\(size)s") { library.export.sizes = [size] }
                }
                Divider()
                Button("Sizes…") { picksSizes = true }
            } label: {
                Text(Self.sizeLabel(options))
            }
            .disabled(options.sizeChoices.isEmpty || library.activePreset != nil)
            .fixedSize()
            .help("Size: “32s” is 32 × 32")
            .popover(isPresented: $picksSizes) { SizesPopover() }

            Picker("Format", selection: $library.export.format) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            // A preset brings its own sizes and formats.
            .disabled(library.activePreset != nil)

            Spacer(minLength: 0)
            FillSwatch(fill: $library.export.fill)
                // exportFormats, not the picked format: a preset brings formats of its own
                // while keeping the fill, so the swatch follows what would be written.
                .disabled(!library.exportFormats.contains(where: \.isBitmap))
            Button { showsOptions = true } label: {
                Label("Export Options", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("File names, background and quality")
            .popover(isPresented: $showsOptions) { ExportOptionsForm() }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The sizes the menu offers directly, as IconJar's does; "Sizes…" has the rest.
    private static let quickSizes: Set = [16, 32, 64, 128, 256, 512]

    /// "32s" for one size, IconJar's shorthand for 32 × 32, or a count for several.
    static func sizeLabel(_ options: ExportOptions) -> String {
        if options.sizeChoices.isEmpty { return "Own size" }
        return options.sizes.count == 1 ? "\(options.sizes[0])s" : "\(options.sizes.count) sizes"
    }
}

private struct SizesPopover: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 10) {
            Text("Sizes").font(.headline)
            SizeGrid(choices: library.export.sizeChoices, sizes: $library.export.sizes)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 290)
    }

    private var note: String {
        switch library.export.format {
        case .ico: "One .ico per icon, holding every size picked."
        case .icns: "One .icns per icon, holding every size picked. 1024 is the 512 @2x slot."
        default: "One file per size."
        }
    }
}

/// IconJar's "Icon Fill" well. The red slash means no fill: icons keep their own colors.
private struct FillSwatch: View {
    @Binding var fill: ExportColor?
    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill?.color ?? Color(white: 0.18))
                .overlay {
                    if fill == nil {
                        Path { line in
                            line.move(to: CGPoint(x: 4, y: 18))
                            line.addLine(to: CGPoint(x: 18, y: 4))
                        }
                        .stroke(.red, lineWidth: 2)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5)) }
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(fill == nil ? "Icon Fill: none" : "Icon Fill")
        .accessibilityLabel(fill == nil ? "Icon Fill: none" : "Icon Fill")
        .popover(isPresented: $isPicking) { FillPicker(fill: $fill) }
    }
}

private struct FillPicker: View {
    @Binding var fill: ExportColor?

    /// Apple's system colors, plus black, grey and white. Named for VoiceOver.
    private static let presets: [(name: String, color: ExportColor)] = [
        ("Black", ExportColor(red: 0, green: 0, blue: 0)),
        ("Grey", ExportColor(red: 0.56, green: 0.56, blue: 0.58)),
        ("White", .white),
        ("Red", ExportColor(red: 1, green: 0.23, blue: 0.19)),
        ("Orange", ExportColor(red: 1, green: 0.58, blue: 0)),
        ("Yellow", ExportColor(red: 1, green: 0.8, blue: 0)),
        ("Green", ExportColor(red: 0.2, green: 0.78, blue: 0.35)),
        ("Teal", ExportColor(red: 0.19, green: 0.69, blue: 0.78)),
        ("Blue", ExportColor(red: 0, green: 0.48, blue: 1)),
        ("Indigo", ExportColor(red: 0.35, green: 0.34, blue: 0.84)),
        ("Purple", ExportColor(red: 0.69, green: 0.32, blue: 0.87)),
        ("Pink", ExportColor(red: 1, green: 0.18, blue: 0.33)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon Fill").font(.headline)
            let columns = Array(repeating: GridItem(.fixed(24), spacing: 6), count: 6)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Self.presets, id: \.color) { name, color in
                    Button { fill = color } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color.color)
                            .frame(width: 24, height: 24)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(
                                    fill == color ? Color.accentColor : .secondary.opacity(0.4),
                                    lineWidth: fill == color ? 2.5 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(fill == color ? .isSelected : [])
                }
            }
            ColorPicker(
                "Custom", selection: Binding(
                    get: { fill?.color ?? .black }, set: { fill = ExportColor($0) }
                ),
                supportsOpacity: false
            )
            Button("No Fill") { fill = nil }
                .disabled(fill == nil)
            Text("Draws the whole icon in one color when exported. Bitmap formats, ICO and ICNS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 220)
    }
}

/// The settings IconJar keeps in its export sheet and preferences: file naming, background and
/// JPG quality.
private struct ExportOptionsForm: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        // What exporting would write now — the preset's formats when one is active — so the
        // background and quality a preset keeps stay reachable while it is.
        let formats = library.exportFormats
        let format = library.export.format
        Form {
            Section("File Name") {
                TextField("Prefix", text: $library.export.prefix)
                TextField("Suffix", text: $library.export.suffix)
                Toggle("Include size in file name", isOn: $library.export.includeSize)
                    .disabled(!format.writesFilePerSize)
                if let icon = library.selectedIcons.first {
                    let names = Exporter.fileNames(for: icon, options: library.export)
                    Text(names.prefix(2).joined(separator: ", ") + (names.count > 2 ? ", …" : ""))
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            if formats.contains(where: \.isBitmap) {
                Section("Background") {
                    Toggle(
                        formats.contains(.jpg)
                            ? "Color (JPG is white without one)" : "Fill the background",
                        isOn: hasBackground
                    )
                    if library.export.background != nil {
                        ColorPicker("Color", selection: backgroundColor, supportsOpacity: false)
                    }
                }
            }
            if formats.contains(.jpg) {
                Section("Quality") {
                    Slider(value: $library.export.quality, in: 0.3...1) {
                        Text("\(Int(library.export.quality * 100))%").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }

    private var hasBackground: Binding<Bool> {
        Binding(
            get: { library.export.background != nil },
            set: { library.export.background = $0 ? .white : nil }
        )
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { library.export.background?.color ?? .white },
            set: { library.export.background = ExportColor($0) }
        )
    }
}

private struct ExportButton: View {
    @Environment(Library.self) private var library
    @State private var namesPreset = false
    @State private var presetName = ""
    let icons: [Icon]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetMenu
            Button { library.exportSelection() } label: {
                Text(icons.count == 1 ? "Export…" : "Export \(icons.count) Icons…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!library.canExport)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Save Preset", isPresented: $namesPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.savePreset(named: presetName) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Keeps the current format, sizes, prefix and suffix under a name.")
        }
    }

    /// IconJar's preset popup: the built-in presets by platform, then the user's own.
    private var presetMenu: some View {
        let active = library.activePreset
        return Menu {
            Toggle("Custom", isOn: choosing(nil))
            ForEach(ExportPreset.platforms, id: \.self) { platform in
                Menu(platform) {
                    ForEach(ExportPreset.builtIn.filter { $0.platform == platform }) { preset in
                        Toggle(preset.name, isOn: choosing(preset.id))
                    }
                }
            }
            if !library.presets.isEmpty {
                Menu("Your Presets") {
                    ForEach(library.presets) { preset in
                        Toggle(preset.name, isOn: choosing(preset.id))
                    }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") {
                presetName = ""
                namesPreset = true
            }
            .disabled(active != nil)
            if let active, !active.isBuiltIn {
                Button("Delete “\(active.name)”") { library.deletePreset(active.id) }
            }
        } label: {
            Text("Preset: \(active?.name ?? "Custom")")
        }
    }

    private func choosing(_ id: String?) -> Binding<Bool> {
        Binding(
            get: { library.export.presetID == id },
            set: { if $0 { library.export.presetID = id } }
        )
    }

    /// What a preset will write, or why SVG can't apply to every icon.
    private var note: String? {
        if let preset = library.activePreset, let icon = icons.first {
            let names = library.export.outputs(of: preset).flatMap {
                Exporter.fileNames(for: icon, options: $0)
            }
            let more = names.count > 3 ? ", …" : ""
            return "\(plural(names.count, "file")) per icon: "
                + names.prefix(3).joined(separator: ", ") + more
        }
        if library.export.format == .svg, icons.contains(where: { $0.kind != .svg }) {
            return "Only SVG icons have a vector version. The rest export as their own file."
        }
        return nil
    }
}

/// Edits that land on every selected icon at once, under the paged single-icon fields. Tags
/// here add to or leave each icon's own; they never replace them wholesale.
private struct BulkFields: View {
    @Environment(Library.self) private var library
    @State private var newTags = ""
    let icons: [Icon]

    var body: some View {
        let ids = Set(icons.map(\.id))
        VStack(alignment: .leading, spacing: 8) {
            Text("All \(icons.count) Selected")
                .font(.headline)
            HStack(spacing: 6) {
                TextField("Add tags, comma-separated", text: $newTags)
                    .onSubmit(addTags)
                Button("Add", action: addTags)
                    .disabled(newTags.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let shared = sharedTags
            if !shared.isEmpty {
                Menu("Remove Tag") {
                    ForEach(shared, id: \.self) { tag in
                        Button(tag) { library.removeTag(ids, tag) }
                    }
                }
            }
            Menu {
                Button("No License") { library.setLicense(ids, nil) }
                Divider()
                ForEach(library.licenses) { license in
                    Button(license.name) { library.setLicense(ids, license.id) }
                }
            } label: {
                Text("License: \(licenseLabel)").lineLimit(1)
            }
        }
    }

    /// Tags carried by any selected icon, for removal; a tag only some of them have still shows.
    private var sharedTags: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for tag in icons.flatMap(\.tags) where seen.insert(tag).inserted {
            ordered.append(tag)
        }
        return ordered
    }

    private var licenseLabel: String {
        let ids = Set(icons.map(\.licenseID))
        guard ids.count == 1, let only = ids.first else { return "Mixed" }
        guard let only else { return "None" }
        return library.licenses.first { $0.id == only }?.name ?? "None"
    }

    private func addTags() {
        library.addTags(Set(icons.map(\.id)), newTags.components(separatedBy: ","))
        newTags = ""
    }
}

private struct DetailsFields: View {
    @Environment(Library.self) private var library
    @State private var managesLicenses = false
    let icon: Icon

    var body: some View {
        VStack(spacing: 8) {
            CommitField(title: "Name", value: icon.name) { library.rename(icon.id, to: $0) }
            TagField(tags: icon.tags) { library.setTags(icon.id, $0) }
            CommitField(title: "Description", value: icon.info ?? "") {
                library.setInfo(icon.id, $0)
            }
            licenseMenu
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $managesLicenses) { ManageLicensesSheet() }
    }

    private var licenseMenu: some View {
        let current = library.license(of: icon)
        let link = current.flatMap { URL(string: $0.url) }
            .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        return HStack(spacing: 6) {
            Menu {
                Toggle("No License", isOn: choosing(nil, current: current))
                Divider()
                ForEach(library.licenses) { license in
                    Toggle(license.name, isOn: choosing(license.id, current: current))
                }
                Divider()
                Button("Manage Licenses…") { managesLicenses = true }
            } label: {
                Text(current?.name ?? "No License").lineLimit(1)
            }
            if let link {
                Link(destination: link) {
                    Label("Open License", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                }
                .help(link.absoluteString)
            }
        }
    }

    private func choosing(_ id: UUID?, current: License?) -> Binding<Bool> {
        Binding(
            get: { current?.id == id },
            set: { if $0 { library.setLicense([icon.id], id) } }
        )
    }
}

/// AppKit's token field, so tags show as tokens the way IconJar's do. Saves when editing ends.
private struct TagField: NSViewRepresentable {
    let tags: [String]
    let commit: ([String]) -> Void

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.placeholderString = "Tags"
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.commit = commit
        // Not while typing, or the tokens would be reset under the cursor.
        if field.currentEditor() == nil { field.objectValue = tags }
    }

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit) }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var commit: ([String]) -> Void

        init(commit: @escaping ([String]) -> Void) {
            self.commit = commit
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            // A token field holds an array of tokens, or a bare string while nothing is tokenized.
            if let tokens = field.objectValue as? [Any] {
                commit(tokens.compactMap { $0 as? String })
            } else if let text = field.objectValue as? String {
                commit(text.split(separator: ",").map(String.init))
            }
        }
    }
}

private struct InfoRows: View {
    @Environment(Library.self) private var library
    let icon: Icon

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            row("Dimensions", library.dimensions(of: icon))
            row("Import Date", icon.added.formatted(date: .abbreviated, time: .omitted))
            row("File Type", icon.kind.rawValue.uppercased())
            row("File Size", library.fileSize(of: icon))
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Opens the icon in another app, remembering the last one picked, as IconJar's Open In does.
private struct OpenInButton: View {
    @Environment(Library.self) private var library
    @AppStorage("openInApp") private var remembered = ""
    let icon: Icon

    var body: some View {
        let file = library.fileURL(for: icon)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file)
        // The remembered app may have come through "Other…" and so be missing from macOS's
        // list for this file type; it still counts as long as it's installed.
        let rememberedApp = remembered.isEmpty ? nil : URL(filePath: remembered)
        let chosen = rememberedApp.flatMap {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil
        } ?? NSWorkspace.shared.urlForApplication(toOpen: file)
        Menu {
            ForEach(apps, id: \.self) { app in
                Button { pick(app) } label: {
                    Label { Text(Self.name(of: app)) } icon: { Image(nsImage: Self.icon(of: app)) }
                }
            }
            Divider()
            Button("Other…") { if let app = Self.chooseApp() { pick(app) } }
        } label: {
            Label {
                Text("Open In › \(chosen.map(Self.name) ?? "…")")
            } icon: {
                if let chosen { Image(nsImage: Self.icon(of: chosen)) }
            }
        } primaryAction: {
            library.open(icon, with: chosen)
        }
        .fixedSize()
    }

    private func pick(_ app: URL) {
        remembered = app.path(percentEncoded: false)
        library.open(icon, with: app)
    }

    private static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(of app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
        let small = image.copy() as? NSImage ?? image
        small.size = NSSize(width: 16, height: 16)
        return small
    }

    private static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct ManageLicensesSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: License.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Licenses").font(.title3.bold())
            Table(library.licenses, selection: $selection) {
                TableColumn("Name") { license in
                    LicenseCell(license: license, title: "Name", field: \.name)
                }
                TableColumn("URL") { license in
                    LicenseCell(license: license, title: "URL", field: \.url)
                }
            }
            HStack {
                ControlGroup {
                    Button { selection = library.addLicense().id } label: {
                        Label("Add License", systemImage: "plus").labelStyle(.iconOnly)
                    }
                    Button { if let selection { library.removeLicense(selection) } } label: {
                        Label("Remove License", systemImage: "minus").labelStyle(.iconOnly)
                    }
                    .disabled(selection == nil)
                }
                .fixedSize()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Removing a license takes it off every icon that had it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 400)
    }
}

private struct LicenseCell: View {
    @Environment(Library.self) private var library
    let license: License
    let title: String
    let field: WritableKeyPath<License, String>

    var body: some View {
        CommitField(title: title, value: license[keyPath: field]) { text in
            var changed = license
            changed[keyPath: field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            library.updateLicense(changed)
        }
        .textFieldStyle(.plain)
    }
}

extension ExportColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}

/// A text field that saves when you press Return or leave it, not on every keystroke, so a name
/// being typed doesn't re-sort the grid under you.
private struct CommitField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onAppear { draft = value }
            .onChange(of: value) { draft = value }
            .onChange(of: isFocused) { if !isFocused { save() } }
            .onSubmit(save)
            .onDisappear(perform: save)
    }

    /// Back to the saved value afterwards: a change that's kept arrives as a new `value` straight
    /// after, and one turned down, like an empty name, would otherwise stay on screen as if saved.
    private func save() {
        if draft != value { commit(draft) }
        draft = value
    }
}

private struct SizeGrid: View {
    let choices: [Int]
    @Binding var sizes: [Int]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(choices, id: \.self) { pixels in
                Toggle(isOn: isOn(pixels)) {
                    Text("\(pixels)")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
            }
        }
    }

    private func isOn(_ pixels: Int) -> Binding<Bool> {
        Binding(
            get: { sizes.contains(pixels) },
            set: { on in
                var picked = Set(sizes)
                if on { picked.insert(pixels) } else { picked.remove(pixels) }
                sizes = picked.sorted()
            }
        )
    }
}

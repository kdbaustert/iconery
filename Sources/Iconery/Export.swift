import AppKit
import ImageIO
import UniformTypeIdentifiers

/// IconJar's format list, less the two macOS can't write: WebP (ImageIO reads it but has no writer,
/// measured on macOS 27) and EPS. In the order the format menu shows them.
enum ExportFormat: String, CaseIterable, Codable, Identifiable {
    case png, jpg, tiff, gif, pdf, ico, icns, svg, original, imageset

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Original"
        case .imageset: "Xcode Image Set"
        default: rawValue.uppercased()
        }
    }

    /// Drawn from a bitmap at each size, so these take the fill and background colours. An
    /// image set is only partly one: an SVG goes in as itself, anything else as 1x/2x/3x PNGs.
    var isBitmap: Bool { [.png, .jpg, .tiff, .gif, .ico, .icns, .imageset].contains(self) }

    /// One file per picked size, so a size can go in the file name.
    var writesFilePerSize: Bool { [.png, .jpg, .tiff, .gif, .pdf, .imageset].contains(self) }

    var imageType: UTType? {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .tiff: .tiff
        case .gif: .gif
        default: nil
        }
    }
}

/// An sRGB colour that survives a trip through UserDefaults.
struct ExportColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = ExportColor(red: 1, green: 1, blue: 1)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct ExportOptions: Codable, Equatable {
    var format = ExportFormat.png
    /// Sizes for the formats that write one file per size; named for the first of them.
    var pngSizes = [32]
    var icoSizes = [16, 24, 32, 48, 64, 128, 256]
    var icnsSizes = [16, 32, 64, 128, 256, 512, 1024]
    /// IconJar's "Icon Fill": the whole icon in one colour. nil keeps the icon's own colours.
    var fill: ExportColor?
    /// Painted behind bitmap formats. nil keeps them transparent, except JPG, which can't be and
    /// gets white.
    var background: ExportColor?
    var prefix = ""
    var suffix = ""
    /// IconJar's "Include Size in Filename". Several sizes carry it regardless, or they'd collide.
    var includeSize = false
    /// JPG only, from 0 to 1.
    var quality = 0.9
    /// When set, Export and drags write every output of this preset instead of the format and
    /// sizes above; the fill, background and quality still apply.
    var presetID: String?
    var naming = ExportNaming.iconName
    var svgCleanup = SVGCleanup()

    static let pngChoices = [16, 24, 32, 48, 64, 96, 128, 256, 512, 1024]
    /// An ICO entry stores each side in one byte, so 256 is the largest size the format holds.
    static let icoChoices = [16, 24, 32, 48, 64, 128, 256]
    /// The sizes ICNS has slots for; see ICNSEncoder.
    static let icnsChoices = [16, 32, 64, 128, 256, 512, 1024]

    /// The sizes the current format uses. Empty for SVG and Original, which keep their own.
    var sizes: [Int] {
        get {
            switch format {
            case .ico: icoSizes
            case .icns: icnsSizes
            case .svg, .original: []
            default: pngSizes
            }
        }
        set {
            switch format {
            case .ico: icoSizes = newValue
            case .icns: icnsSizes = newValue
            case .svg, .original: break
            default: pngSizes = newValue
            }
        }
    }

    var sizeChoices: [Int] {
        switch format {
        case .ico: Self.icoChoices
        case .icns: Self.icnsChoices
        case .svg, .original: []
        default: Self.pngChoices
        }
    }

    var isExportable: Bool { sizeChoices.isEmpty || !sizes.isEmpty }

    private static let defaultsKey = "exportOptions"

    static func load() -> ExportOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var options = try? JSONDecoder().decode(ExportOptions.self, from: data)
        else { return ExportOptions() }
        options.pngSizes.sort()
        options.icoSizes.sort()
        options.icnsSizes.sort()
        return options
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension ExportOptions {
    /// Each field falls back to its default, so settings saved before a field existed still load
    /// instead of all resetting. In an extension to keep the synthesized `init()`.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ExportOptions()
        // try?: a format a later version added shouldn't throw the rest away.
        format = (try? saved.decodeIfPresent(ExportFormat.self, forKey: .format)) ?? fallback.format
        pngSizes = try saved.decodeIfPresent([Int].self, forKey: .pngSizes) ?? fallback.pngSizes
        icoSizes = try saved.decodeIfPresent([Int].self, forKey: .icoSizes) ?? fallback.icoSizes
        icnsSizes = try saved.decodeIfPresent([Int].self, forKey: .icnsSizes) ?? fallback.icnsSizes
        fill = try saved.decodeIfPresent(ExportColor.self, forKey: .fill)
        background = try saved.decodeIfPresent(ExportColor.self, forKey: .background)
        prefix = try saved.decodeIfPresent(String.self, forKey: .prefix) ?? fallback.prefix
        suffix = try saved.decodeIfPresent(String.self, forKey: .suffix) ?? fallback.suffix
        includeSize = try saved.decodeIfPresent(Bool.self, forKey: .includeSize)
            ?? fallback.includeSize
        quality = try saved.decodeIfPresent(Double.self, forKey: .quality) ?? fallback.quality
        presetID = try saved.decodeIfPresent(String.self, forKey: .presetID)
        naming = (try? saved.decodeIfPresent(ExportNaming.self, forKey: .naming)) ?? fallback.naming
        svgCleanup = try saved.decodeIfPresent(SVGCleanup.self, forKey: .svgCleanup)
            ?? fallback.svgCleanup
    }

    /// The settings for each output of `preset`, keeping this export's fill, background and
    /// quality. Outputs that would share a file name get the size added to it.
    func outputs(of preset: ExportPreset) -> [ExportOptions] {
        preset.outputs.map { output in
            var options = self
            options.presetID = nil
            options.format = output.format
            options.sizes = output.sizes
            options.prefix = output.prefix
            options.suffix = output.suffix
            let twins = preset.outputs.filter {
                $0.format == output.format && $0.prefix == output.prefix
                    && $0.suffix == output.suffix
            }
            options.includeSize = output.includeSize || twins.count > 1
            return options
        }
    }
}

/// One row of an export preset, as in IconJar's export sheet: a format at one or more sizes, with
/// its own prefix and suffix. ICO and ICNS put every size in one file; the others write one each.
struct PresetOutput: Codable, Hashable {
    var format = ExportFormat.png
    var sizes: [Int]
    var prefix = ""
    var suffix = ""
    var includeSize = false
}

struct ExportPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    /// The submenu it sits in: macOS, iOS, Android, Web, or nil for one of the user's own.
    var platform: String?
    var outputs: [PresetOutput]

    var isBuiltIn: Bool { platform != nil }

    static let platforms = ["macOS", "iOS", "Android", "Web"]

    /// IconJar 2.11.4's built-in presets, under its own identifiers. Read from the strings in its
    /// binary, which keep each piece of text once, so a size appears only where first used:
    /// "Tab Bar Icon" 25s 50s 75s is one icon at @1x @2x @3x, and the Android sets' new sizes (33
    /// 44 66 88; 36 72 96) are 22 dp and 24 dp across mdpi to xxxhdpi. Two are not spelt out
    /// there and are this app's reading: iOS Toolbar & Navigation Icons as Apple's 22 pt, and the
    /// favicon as one .ico of 16, 32 and 48.
    static let builtIn: [ExportPreset] = [
        ExportPreset(
            id: "__IJBuiltInMacOSPresetAppIcon", name: "App Icon", platform: "macOS",
            outputs: [16, 32, 128, 256, 512].flatMap { size in
                let prefix = "\(size)x\(size)-"
                return [
                    PresetOutput(sizes: [size], prefix: prefix),
                    PresetOutput(sizes: [size * 2], prefix: prefix, suffix: "@2x"),
                ]
            }
        ),
        ExportPreset(
            id: "__IJBuiltInMacOSPresetToolbarIcon", name: "Toolbar Icon", platform: "macOS",
            outputs: [PresetOutput(sizes: [19]), PresetOutput(sizes: [24])]
        ),
        ExportPreset(
            id: "__IJBuiltInMacOSPresetSidebarIcon", name: "Sidebar Icon", platform: "macOS",
            outputs: [PresetOutput(sizes: [18])]
        ),
        ExportPreset(
            id: "__IJBuiltInMacOSPresetMenuBarIcon", name: "Menu Bar Icon", platform: "macOS",
            outputs: [PresetOutput(sizes: [22])]
        ),
        ExportPreset(
            id: "__IJBuiltInMacOSPresetSafariExtensionIcon", name: "Safari Extension Icon",
            platform: "macOS", outputs: [PresetOutput(sizes: [48])]
        ),
        ExportPreset(
            id: "__IJBuiltIniOSPresetTabBarIcon", name: "Tab Bar Icon", platform: "iOS",
            outputs: scaled(25)
        ),
        ExportPreset(
            id: "__IJBuiltIniOSPresetToolbarNavigationIcons", name: "Toolbar & Navigation Icons",
            platform: "iOS", outputs: scaled(22)
        ),
        ExportPreset(
            id: "__IJBuiltInAndroidPresetSMallContextualIcons", name: "Small Contextual Icons",
            platform: "Android", outputs: densities(16)
        ),
        ExportPreset(
            id: "__IJBuiltInAndroidPresetNoticationIcons", name: "Notification Icons",
            platform: "Android", outputs: densities(22)
        ),
        ExportPreset(
            id: "__IJBuiltInAndroidPresetActionBarDialogTabIcons",
            name: "Action Bar, Dialog & Tab Icons", platform: "Android", outputs: densities(24)
        ),
        ExportPreset(
            id: "__IJBuiltInWebFavicon", name: "Favicon", platform: "Web",
            outputs: [PresetOutput(format: .ico, sizes: [16, 32, 48])]
        ),
    ]

    /// Apple's @1x, @2x and @3x of a size in points.
    private static func scaled(_ points: Int) -> [PresetOutput] {
        [1, 2, 3].map { PresetOutput(sizes: [points * $0], suffix: $0 == 1 ? "" : "@\($0)x") }
    }

    /// Android's densities of a size in dp, mdpi being 1×.
    private static func densities(_ dp: Int) -> [PresetOutput] {
        let scales = [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]
        return scales.map { name, scale in
            PresetOutput(sizes: [Int(Double(dp) * scale)], suffix: "-\(name)")
        }
    }

    private static let defaultsKey = "exportPresets"

    /// The user's own presets, kept app-wide like the rest of the export settings.
    static func loadSaved() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ExportPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [ExportPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: defaultsKey)
    }
}

/// IconJar's file naming preferences.
enum ExportNaming: String, Codable, CaseIterable, Identifiable {
    case iconName, originalFileName, tags

    var id: Self { self }

    var title: String {
        switch self {
        case .iconName: "Icon name"
        case .originalFileName: "Original file name"
        case .tags: "Tags"
        }
    }
}

/// IconJar's simpler SVG export options. Its dozen path-optimising ones are left out.
struct SVGCleanup: Codable, Equatable {
    var removesSize = false
    var removesComments = false
    var removesDeclaration = false
    var compresses = false

    var changesAnything: Bool { removesSize || removesComments || removesDeclaration || compresses }
}

/// Edits SVG text in place rather than parsing and re-serialising it, so everything not asked for
/// stays byte for byte as it was.
enum SVGCleaner {
    static func clean(_ svg: String, _ options: SVGCleanup) -> String {
        var svg = svg
        if options.removesDeclaration {
            svg = svg.replacing(#/^\s*<\?xml[^>]*\?>\s*/#, with: "")
        }
        if options.removesComments {
            svg = svg.replacing(#/<!--[\s\S]*?-->/#, with: "")
        }
        if options.removesSize { svg = withoutSize(svg) }
        if options.compresses { svg = compressed(svg) }
        return svg
    }

    /// Whitespace between tags is only layout, except inside <text>, where the space between two
    /// <tspan>s is the space between two words. A text element is matched whole and kept as it is,
    /// so its insides are never looked at; only the whitespace around it goes.
    private static func compressed(_ svg: String) -> String {
        svg.replacing(#/(<text\b[\s\S]*?<\/text>)\s*|>\s+(?=<)/#) { match in
            match.output.1.map(String.init) ?? ">"
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops width and height from the root <svg>, so it scales to whatever holds it. A file with
    /// no viewBox gets one from them first, or the drawing would lose its proportions; when they
    /// aren't plain numbers it is left alone.
    private static func withoutSize(_ svg: String) -> String {
        // Comments are matched too, so an "<svg" written inside one is passed over, and quoted
        // values whole, so a ">" inside one doesn't end the tag.
        let tags = svg.matches(of: #/<!--[\s\S]*?-->|<svg\b(?:[^>"']|"[^"]*"|'[^']*')*>/#)
        guard let root = tags.first(where: { $0.output.hasPrefix("<svg") }) else { return svg }
        var tag = String(root.output)
        if attribute("viewBox", in: tag) == nil {
            guard let width = attribute("width", in: tag).flatMap(number),
                  let height = attribute("height", in: tag).flatMap(number)
            else { return svg }
            let box = String(format: "0 0 %g %g", width, height)
            tag = tag.replacing(#/^<svg\b/#, with: "<svg viewBox=\"\(box)\"")
        }
        // A space before the name, so stroke-width and the like are never touched.
        tag = tag.replacing(#/\s(?:width|height)\s*=\s*(?:"[^"]*"|'[^']*')/#, with: "")
        return svg.replacingCharacters(in: root.range, with: tag)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let pattern = try? Regex("\\s\(name)\\s*=\\s*[\"']([^\"']*)[\"']"),
              let match = tag.firstMatch(of: pattern),
              let value = match.output[1].substring
        else { return nil }
        return String(value)
    }

    /// "24" or "24px"; nil for "100%", "2em" and the like, which say nothing about proportions.
    private static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return Double(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed)
    }

    /// The <title> and <desc> an SVG names itself with, which IconJar reads into the icon's name
    /// and description on import.
    static func titleAndDescription(of svg: String) -> (title: String?, description: String?) {
        func text(_ element: String) -> String? {
            guard let pattern = try? Regex("<\(element)\\b[^>]*>([\\s\\S]*?)</\(element)>"),
                  let match = svg.firstMatch(of: pattern),
                  let value = match.output[1].substring
            else { return nil }
            let decoded = String(value)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.isEmpty ? nil : decoded
        }
        return (text("title"), text("desc"))
    }
}

struct ExportFile {
    var name: String
    var data: Data
}

enum Exporter {
    enum Failure: LocalizedError {
        case unreadable(String)
        case noSizes

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” could not be drawn."
            case .noSizes: "Pick at least one size."
            }
        }
    }

    /// Where drags out of the grid are exported to. Emptied at launch.
    static let dragRoot = FileManager.default.temporaryDirectory
        .appending(path: "IconeryDrag", directoryHint: .isDirectory)

    /// The names exporting `icon` writes, before anything is drawn: prefix, name and suffix, then
    /// the size when asked for or when several sizes would otherwise share one name.
    static func fileNames(for icon: Icon, options: ExportOptions) -> [String] {
        let stem = switch options.naming {
        case .iconName: icon.name
        case .originalFileName: icon.originalName ?? icon.name
        case .tags: icon.tags.isEmpty ? icon.name : icon.tags.joined(separator: "-")
        }
        let base = safeFileName(options.prefix + stem + options.suffix)
        let ext = options.format.rawValue
        switch options.format {
        // An icon that isn't an SVG has no vector version, so it goes out as the file it came in
        // as.
        case .svg, .original: return ["\(base).\(icon.kind.rawValue)"]
        case .ico, .icns: return ["\(base).\(ext)"]
        case .imageset:
            // An SVG keeps its vector representation in one universal set; sizes don't apply.
            if icon.kind == .svg { return ["\(base).imageset"] }
            let named = options.includeSize || options.pngSizes.count > 1
            return options.pngSizes.map { named ? "\(base)-\($0).imageset" : "\(base).imageset" }
        default:
            let named = options.includeSize || options.pngSizes.count > 1
            return options.pngSizes.map { named ? "\(base)-\($0).\(ext)" : "\(base).\(ext)" }
        }
    }

    @MainActor
    static func files(
        for icon: Icon, source: URL, image: NSImage?, options: ExportOptions
    ) throws -> [ExportFile] {
        let names = fileNames(for: icon, options: options)
        let format = options.format
        if format == .svg || format == .original {
            var data = try Data(contentsOf: source)
            if format == .svg, icon.kind == .svg, options.svgCleanup.changesAnything {
                let text = String(decoding: data, as: UTF8.self)
                let cleaned = SVGCleaner.clean(text, options.svgCleanup)
                data = Data(cleaned.utf8)
            }
            return [ExportFile(name: names[0], data: data)]
        }
        if format == .imageset {
            return try imageset(for: icon, source: source, image: image, options: options)
        }
        let sizes = switch format {
        case .ico: options.sizes.filter { $0 <= 256 }
        case .icns: options.sizes.filter(ExportOptions.icnsChoices.contains)
        default: options.sizes
        }
        guard !sizes.isEmpty else { throw Failure.noSizes }
        guard let image else { throw Failure.unreadable(icon.name) }

        switch format {
        case .ico, .icns:
            let entries = try sizes.map { pixels in
                let drawn = try drawn(image, pixels: pixels, options: options, name: icon.name)
                return (pixels: pixels, png: try encoded(drawn, as: .png, options, icon.name))
            }
            let data = format == .ico ? ICOEncoder.encode(entries) : ICNSEncoder.encode(entries)
            return [ExportFile(name: names[0], data: data)]
        case .pdf:
            return try zip(names, sizes).map { name, side in
                guard let data = Raster.pdf(image, side: side) else {
                    throw Failure.unreadable(icon.name)
                }
                return ExportFile(name: name, data: data)
            }
        default:
            let type = format.imageType ?? .png
            return try zip(names, sizes).map { name, pixels in
                let drawn = try drawn(image, pixels: pixels, options: options, name: icon.name)
                let data = try encoded(drawn, as: type, options, icon.name)
                return ExportFile(name: name, data: data)
            }
        }
    }

    /// A folder Xcode drags in whole: Contents.json beside the images. An SVG goes in as itself
    /// with its vector representation preserved; anything else as 1x/2x/3x PNGs of each picked
    /// size, through the same fill and background as a PNG export.
    @MainActor
    private static func imageset(
        for icon: Icon, source: URL, image: NSImage?, options: ExportOptions
    ) throws -> [ExportFile] {
        func contents(_ images: [[String: String]], vector: Bool) throws -> Data {
            var json: [String: Any] = [
                "images": images,
                "info": ["author": "xcode", "version": 1],
            ]
            if vector { json["properties"] = ["preserves-vector-representation": true] }
            return try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
        }
        let names = fileNames(for: icon, options: options)
        if icon.kind == .svg {
            var data = try Data(contentsOf: source)
            if options.svgCleanup.changesAnything {
                data = Data(SVGCleaner.clean(String(decoding: data, as: UTF8.self),
                                             options.svgCleanup).utf8)
            }
            let stem = (names[0] as NSString).deletingPathExtension
            return [
                ExportFile(name: "\(names[0])/Contents.json", data: try contents(
                    [["filename": "\(stem).svg", "idiom": "universal"]], vector: true
                )),
                ExportFile(name: "\(names[0])/\(stem).svg", data: data),
            ]
        }
        guard !options.pngSizes.isEmpty else { throw Failure.noSizes }
        guard let image else { throw Failure.unreadable(icon.name) }
        return try zip(names, options.pngSizes).flatMap { folder, base -> [ExportFile] in
            let stem = (folder as NSString).deletingPathExtension
            var images: [[String: String]] = []
            var files: [ExportFile] = []
            for scale in 1...3 {
                let fileName = "\(stem)\(scale == 1 ? "" : "@\(scale)x").png"
                let drawn = try drawn(
                    image, pixels: base * scale, options: options, name: icon.name
                )
                files.append(ExportFile(
                    name: "\(folder)/\(fileName)",
                    data: try encoded(drawn, as: .png, options, icon.name)
                ))
                images.append(["filename": fileName, "idiom": "universal", "scale": "\(scale)x"])
            }
            files.insert(
                ExportFile(name: "\(folder)/Contents.json",
                           data: try contents(images, vector: false)), at: 0
            )
            return files
        }
    }

    /// Writes into `folder`, never over an existing file. A name holding a slash is a file
    /// inside a folder, like an image set's Contents.json: a clash renames at that folder, so
    /// its contents stay together.
    @discardableResult
    static func write(_ files: [ExportFile], to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var renamed: [String: String] = [:]
        return try files.map { file in
            let url: URL
            if let slash = file.name.firstIndex(of: "/") {
                let top = String(file.name[..<slash])
                let rest = String(file.name[file.name.index(after: slash)...])
                let unique = renamed[top] ?? uniqueURL(for: top, in: folder).lastPathComponent
                renamed[top] = unique
                url = folder.appending(path: unique).appending(path: rest)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            } else {
                url = uniqueURL(for: file.name, in: folder)
            }
            try file.data.write(to: url, options: .withoutOverwriting)
            return url
        }
    }

    /// Finder's rule for a clash: "home.png" becomes "home 2.png", then "home 3.png".
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let first = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) else {
            return first
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            number += 1
        }
    }

    /// "/" and ":" cannot appear in a macOS file name, and a leading dot would hide the file.
    /// Control characters become spaces, and the name stops at 200 bytes: APFS allows 255, which
    /// leaves room for a size, a " 2" and an extension added after.
    static func safeFileName(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "\u{0}"..."\u{1F}"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        return cleaned.isEmpty ? "icon" : cleaned
    }

    /// `image` at `pixels` a side, with the fill and background applied.
    @MainActor
    private static func drawn(
        _ image: NSImage, pixels: Int, options: ExportOptions, name: String
    ) throws -> CGImage {
        guard var raster = Raster.render(image, pixels: pixels) else {
            throw Failure.unreadable(name)
        }
        if let fill = options.fill, let tinted = Raster.tinted(raster, fill.cgColor) {
            raster = tinted
        }
        // JPG has no transparency: without a background its clear pixels would come out black.
        let background = options.background ?? (options.format == .jpg ? .white : nil)
        if let background, let flat = Raster.flattened(raster, onto: background.cgColor) {
            raster = flat
        }
        return raster
    }

    private static func encoded(
        _ image: CGImage, as type: UTType, _ options: ExportOptions, _ name: String
    ) throws -> Data {
        let quality = type == .jpeg ? options.quality : nil
        guard let data = Raster.encode(image, as: type, quality: quality) else {
            throw Failure.unreadable(name)
        }
        return data
    }
}

enum Raster {
    /// Draws `image` aspect-fit and centred on a transparent square of `pixels` a side. An SVG is
    /// drawn as vectors at that size, so every export size is sharp rather than scaled.
    @MainActor
    static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard pixels > 0, image.size.width > 0, image.size.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: fitted(image.size, in: CGFloat(pixels)))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The one colour every visible pixel shares, or nil when there are several or none. Read from
    /// pixels rather than the SVG text, so CSS, `currentColor` and inherited fills all count.
    /// Antialiased edges keep their colour once un-premultiplied, so the tolerance only covers
    /// rounding; faint pixels are skipped because 8-bit rounding swamps their colour.
    static func singleColor(of image: CGImage) -> SIMD3<Double>? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var shared: SIMD3<Double>?
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3])
            guard alpha >= 64 else { continue }
            let color = SIMD3(
                Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2])
            ) / alpha
            guard let first = shared else {
                shared = color
                continue
            }
            let difference = color - first
            if max(abs(difference.x), abs(difference.y), abs(difference.z)) > 0.08 { return nil }
        }
        return shared
    }

    /// WCAG relative luminance of an sRGB colour, 0 for black to 1 for white.
    static func luminance(_ color: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    /// WCAG contrast ratio between two luminances, from 1:1 to 21:1.
    static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `image` with every visible pixel turned to `color`, its transparency kept.
    static func tinted(_ image: CGImage, _ color: CGColor) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        // Source-in keeps the colour only where the icon already was.
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage()
    }

    /// Where an image of `size` sits, aspect-fit and centred, in a square `side` across.
    static func fitted(_ size: CGSize, in side: CGFloat) -> CGRect {
        let scale = min(side / size.width, side / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
    }

    /// `image` on a solid `color`, for formats that can't be transparent or where a background
    /// was asked for.
    static func flattened(_ image: CGImage, onto color: CGColor) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// `quality` is the lossy compression quality, 0 to 1, for formats that have one.
    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A one-page PDF `side` points square. An SVG stays vector, since NSImage draws it as paths.
    @MainActor
    static func pdf(_ image: NSImage, side: Int) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: side, height: side)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: fitted(image.size, in: CGFloat(side)))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// Writes .ico files by hand rather than through ImageIO, whose ICO writer (measured on macOS 27)
/// refuses more than six images and stores every size under 256 as an uncompressed bitmap. Each
/// entry here is a PNG, which Windows has read inside .ico since Vista.
enum ICOEncoder {
    static func encode(_ images: [(pixels: Int, png: Data)]) -> Data {
        var data = Data()
        func u16(_ value: Int) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8 & 0xFF))
        }
        func u32(_ value: Int) {
            u16(value & 0xFFFF)
            u16(value >> 16 & 0xFFFF)
        }

        u16(0)  // reserved
        u16(1)  // type: icon
        u16(images.count)
        var offset = 6 + 16 * images.count
        for image in images {
            // One byte per side, where 0 means 256.
            let side = UInt8(image.pixels >= 256 ? 0 : image.pixels)
            data.append(side)
            data.append(side)
            data.append(0)  // palette size: none
            data.append(0)  // reserved
            u16(1)  // colour planes
            u16(32)  // bits per pixel
            u32(image.png.count)
            u32(offset)
            offset += image.png.count
        }
        for image in images { data.append(image.png) }
        return data
    }
}

/// Writes .icns files by hand for the same reason as ICOEncoder: ImageIO's ICNS writer (measured
/// on macOS 27) silently drops 64 and 1024 px, the sizes that only exist as @2x slots, and refuses
/// a lone 1024. An .icns is a big-endian length-prefixed list of typed chunks, each one PNG.
enum ICNSEncoder {
    /// The chunk types each pixel size fills. Where a size serves as both a 1x slot and the @2x
    /// slot of half its size, it is written under both, as `iconutil` does. 64 goes out only as
    /// 32@2x, again as `iconutil` does: the 64 px `icp6` chunk is read as 64 by NSImage but as a
    /// 48 px slot by `iconutil` (both measured), so it is left out.
    static let chunkTypes: [Int: [String]] = [
        16: ["icp4"],
        32: ["icp5", "ic11"],  // 32, and 16@2x
        64: ["ic12"],  // 32@2x
        128: ["ic07"],
        256: ["ic08", "ic13"],  // 256, and 128@2x
        512: ["ic09", "ic14"],  // 512, and 256@2x
        1024: ["ic10"],  // 512@2x
    ]

    static func encode(_ images: [(pixels: Int, png: Data)]) -> Data {
        var body = Data()
        for image in images {
            for type in chunkTypes[image.pixels] ?? [] {
                body.append(contentsOf: Array(type.utf8))
                body.append(bigEndian(8 + image.png.count))
                body.append(image.png)
            }
        }
        return Data("icns".utf8) + bigEndian(8 + body.count) + body
    }

    private static func bigEndian(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }
}

import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import Iconery

final class ExportTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var savedDefaults: UserDefaults!
    private var savedDragRoot: URL!
    private var savedOpenRoot: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "IconeryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Library.init empties both staging folders, which the installed app also uses.
        suiteName = "IconeryTests-\(UUID().uuidString)"
        savedDefaults = Library.defaults
        savedDragRoot = Exporter.dragRoot
        savedOpenRoot = Library.openRoot
        Library.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        Exporter.dragRoot = folder.appending(path: "Drag", directoryHint: .isDirectory)
        Library.openRoot = folder.appending(path: "Open", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        Library.defaults.removePersistentDomain(forName: suiteName)
        Library.defaults = savedDefaults
        Exporter.dragRoot = savedDragRoot
        Library.openRoot = savedOpenRoot
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testOneColourIsFoundButSeveralAreNot() throws {
        func color(_ name: String, _ body: String) throws -> SIMD3<Double>? {
            let url = try writeSVG(name, body)
            return NSImage(contentsOf: url)
                .flatMap { Raster.render($0, pixels: 64) }
                .flatMap(Raster.singleColor)
        }
        let black = try XCTUnwrap(try color("black", #"<path d="M3 10l9-7 9 7" stroke="black"/>"#))
        XCTAssertEqual(black.x + black.y + black.z, 0, accuracy: 0.05)
        XCTAssertNil(try color("two", #"<circle cx="12" cy="12" r="8" fill="red" stroke="blue"/>"#))
        XCTAssertNil(try color("fade", """
        <defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/>\
        <stop offset="1" stop-color="#000"/></linearGradient></defs>\
        <rect width="24" height="24" fill="url(#g)"/>
        """))
    }

    @MainActor
    func testFaintOneColourIconsAreRedrawnOnScreenOnly() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let set = library.createSet(named: "Set")
        let stroke = ##"<path d="M3 10l9-7 9 7v10H3z" stroke-width="3" stroke="#"##
        library.importItems([
            try writeSVG("pale", stroke + #"eeeeee"/>"#),
            try writeSVG("ink", stroke + #"111111"/>"#),
            try writeSVG("duo", ##"<circle cx="12" cy="12" r="8" fill="#111" stroke="#eee"/>"##),
            // Colours from the user's DevIcon set: React's cyan and JavaScript's yellow.
            try writeSVG("react", stroke + #"60D9FA"/>"#),
            try writeSVG("javascript", stroke + #"EFD94D"/>"#),
        ], into: set.id)
        func icon(_ name: String) throws -> Icon {
            try XCTUnwrap(library.icons.first { $0.name == name })
        }
        func shown(_ name: String, onDark: Bool, improve: Bool = true) throws -> SIMD3<Double>? {
            try library.thumbnail(
                for: icon(name), points: 32, scale: 2, onDark: onDark, improveContrast: improve
            ).flatMap(Raster.singleColor)
        }
        func brightness(_ color: SIMD3<Double>?) throws -> Double {
            let color = try XCTUnwrap(color)
            return (color.x + color.y + color.z) / 3
        }

        XCTAssertEqual(try brightness(shown("pale", onDark: false)), 0, accuracy: 0.05,
                       "pale grey on a light background is drawn black")
        XCTAssertEqual(try brightness(shown("pale", onDark: false, improve: false)), 0.93,
                       accuracy: 0.05, "and left alone with the setting off")
        XCTAssertEqual(try brightness(shown("pale", onDark: true)), 0.93, accuracy: 0.05,
                       "pale grey already stands out on a dark background")
        XCTAssertEqual(try brightness(shown("ink", onDark: true)), 1, accuracy: 0.05,
                       "near-black on a dark background is drawn white")
        XCTAssertEqual(try brightness(shown("ink", onDark: false)), 0.07, accuracy: 0.05)
        XCTAssertNil(try shown("duo", onDark: true), "two colours are never touched")
        XCTAssertEqual(try brightness(shown("react", onDark: false)), 0.74, accuracy: 0.05,
                       "a brand colour that is plainly visible keeps its colour (1.63:1)")
        XCTAssertEqual(try brightness(shown("javascript", onDark: false)), 0, accuracy: 0.05,
                       "one that nearly vanishes on white is drawn black (1.43:1)")

        var options = ExportOptions()
        options.pngSizes = [64]
        let pale = try icon("pale")
        let exported = try Exporter.files(
            for: pale, source: library.fileURL(for: pale), image: library.image(for: pale),
            options: options
        )
        let png = try XCTUnwrap(NSBitmapImageRep(data: exported[0].data)?.cgImage)
        XCTAssertEqual(try brightness(Raster.singleColor(of: png)), 0.93, accuracy: 0.05,
                       "exports keep the icon's own colour")
    }

    /// Preferences held in memory only, so a test never touches the real ones or leaves a file.
    @MainActor
    private func preferences(_ change: (Preferences) -> Void = { _ in }) -> Preferences {
        let preferences = Preferences(defaults: nil)
        change(preferences)
        return preferences
    }

    @MainActor
    private func writePNG(_ name: String) throws -> URL {
        let source = try writeSVG("\(name)-source", #"<rect width="10" height="10" fill="black"/>"#)
        let image = try XCTUnwrap(NSImage(contentsOf: source))
        let png = try XCTUnwrap(Raster.render(image, pixels: 32).flatMap {
            Raster.encode($0, as: .png)
        })
        let url = folder.appending(path: "\(name).png")
        try png.write(to: url)
        return url
    }

    /// `source` with a comment added, so it draws the same but is a different file.
    private func distinctCopy(of source: URL, marked mark: String, to destination: URL) throws {
        let svg = try String(contentsOf: source, encoding: .utf8)
        try Data((svg + "<!-- \(mark) -->").utf8).write(to: destination)
    }

    private func writeSVG(_ name: String, _ body: String) throws -> URL {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">"#
            + body + "</svg>"
        let url = folder.appending(path: "\(name).svg")
        try Data(svg.utf8).write(to: url)
        return url
    }

    @MainActor
    func testMovingTheLibraryTakesEverythingAlong() throws {
        let (_, source) = try makeSVGIcon()
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.importItems([source], into: library.createSet(named: "Set").id)
        let elsewhere = folder.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        try library.moveLibrary(into: elsewhere)

        XCTAssertEqual(library.folder.lastPathComponent, "Iconery Library")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)),
                        "icons are read from the new place")
        XCTAssertEqual(Library(folder: library.folder, preferences: preferences()).icons.count, 1)
        XCTAssertThrowsError(try library.moveLibrary(into: library.iconsFolder),
                             "a library can't move into itself")
    }

    @MainActor
    func testSwitchingOpensAnotherLibraryButNotAPlainFolder() throws {
        let (_, source) = try makeSVGIcon()
        let other = Library(folder: folder.appending(path: "Other"), preferences: preferences())
        other.importItems([source], into: other.createSet(named: "Theirs").id)
        let library = Library(folder: folder.appending(path: "Mine"), preferences: preferences())
        library.createSet(named: "Mine")

        try library.switchLibrary(to: other.folder)
        XCTAssertEqual(library.setPaths.map(\.path), ["Theirs"])
        XCTAssertEqual(library.icons.count, 1)
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)))

        XCTAssertThrowsError(try library.switchLibrary(to: folder))
        XCTAssertEqual(library.setPaths.map(\.path), ["Theirs"], "a refused switch changes nothing")
        let mine = Library(folder: folder.appending(path: "Mine"), preferences: preferences())
        XCTAssertEqual(mine.setPaths.map(\.path), ["Mine"],
                       "the library switched away from was saved")
    }

    @MainActor
    func testBackUpWritesDatedZipsOutsideTheLibrary() async throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.createSet(named: "Set")
        let backups = folder.appending(path: "Backups")

        let first = try await library.backUp(into: backups)
        let second = try await library.backUp(into: backups)

        XCTAssertTrue(first.lastPathComponent.hasPrefix("Iconery Backup "))
        XCTAssertEqual(first.pathExtension, "iconerybackup")
        XCTAssertNotEqual(first, second, "two backups in the same second don't overwrite")
        XCTAssertNotNil(library.lastBackup)
        let inside = library.folder.appending(path: "Backups")
        do {
            try await library.backUp(into: inside)
            XCTFail("a backup was written inside the library it backs up")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, Library.Problem.backupInsideLibrary.errorDescription
            )
        }
        XCTAssertThrowsError(try library.changeBackupFolder(to: inside))
    }

    func testICOHeaderAndDirectory() {
        let data = ICOEncoder.encode([
            (pixels: 16, png: Data([1, 2, 3])), (pixels: 256, png: Data([4, 5])),
        ])
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[0..<6]), [0, 0, 1, 0, 2, 0], "reserved, type icon, two images")
        XCTAssertEqual(bytes[6], 16, "first entry width")
        XCTAssertEqual(bytes[22], 0, "256 is stored as 0")
        let headerSize = 6 + 16 * 2
        XCTAssertEqual(Array(bytes[18..<22]), [UInt8(headerSize), 0, 0, 0], "first image offset")
        XCTAssertEqual(Array(bytes[headerSize..<headerSize + 3]), [1, 2, 3])
        XCTAssertEqual(bytes.count, headerSize + 5)
    }

    @MainActor
    func testExportedICOReadsBackWithEverySize() throws {
        let (icon, source) = try makeSVGIcon()
        var options = ExportOptions()
        options.format = .ico
        options.icoSizes = ExportOptions.icoChoices
        let files = try Exporter.files(
            for: icon, source: source, image: NSImage(contentsOf: source), options: options
        )
        XCTAssertEqual(files.map(\.name), ["home.ico"])

        let image = try XCTUnwrap(CGImageSourceCreateWithData(files[0].data as CFData, nil))
        let widths = (0..<CGImageSourceGetCount(image)).compactMap {
            let properties = CGImageSourceCopyPropertiesAtIndex(image, $0, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int
        }
        XCTAssertEqual(widths.sorted(), ExportOptions.icoChoices)
    }

    @MainActor
    func testPNGSizesAreDrawnAtSize() throws {
        let (icon, source) = try makeSVGIcon()
        var options = ExportOptions()
        options.pngSizes = [16, 512]
        let files = try Exporter.files(
            for: icon, source: source, image: NSImage(contentsOf: source), options: options
        )
        XCTAssertEqual(files.map(\.name), ["home-16.png", "home-512.png"])
        let big = try XCTUnwrap(NSBitmapImageRep(data: files[1].data))
        XCTAssertEqual(big.pixelsWide, 512)
        XCTAssertEqual(big.pixelsHigh, 512)
    }

    func testFileNames() {
        let icon = Icon(name: "arrow/left", setID: UUID(), kind: .png)
        var options = ExportOptions()
        options.pngSizes = [32]
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["arrow-left.png"])
        options.format = .svg
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["arrow-left.png"],
                       "a PNG icon has no SVG, so it keeps its own format")
        XCTAssertEqual(Exporter.safeFileName("..."), "icon")
    }

    func testWriteNeverOverwrites() throws {
        let file = ExportFile(name: "a.png", data: Data([1]))
        let first = try Exporter.write([file], to: folder)
        let second = try Exporter.write([file, file], to: folder)
        XCTAssertEqual(first.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["a 2.png", "a 3.png"])
    }

    @MainActor
    func testFolderImportBecomesASet() throws {
        let (_, source) = try makeSVGIcon()
        let incoming = folder.appending(path: "Arrows")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: incoming.appending(path: "up.svg"))
        try Data("not an icon".utf8).write(to: incoming.appending(path: "README.md"))

        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let report = library.importItems([incoming], into: nil)

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.skipped, [], "files that aren't icons are ignored inside a folder")
        XCTAssertEqual(library.sets.map(\.name), ["Arrows"])
        XCTAssertEqual(library.icons.map(\.name), ["up"])

        let reopened = Library(
            folder: folder.appending(path: "Library"), preferences: preferences()
        )
        XCTAssertEqual(reopened.icons.map(\.name), ["up"], "the library survives a relaunch")
    }

    @MainActor
    func testICNSHoldsEverySlot() throws {
        let (icon, source) = try makeSVGIcon()
        var options = ExportOptions()
        options.format = .icns
        let files = try Exporter.files(
            for: icon, source: source, image: NSImage(contentsOf: source), options: options
        )
        XCTAssertEqual(files.map(\.name), ["home.icns"])

        let bytes = [UInt8](files[0].data)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "icns")
        XCTAssertEqual(bigEndian(bytes, at: 4), bytes.count, "header length is the whole file")
        var types: [String] = []
        var offset = 8
        while offset < bytes.count {
            types.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            let length = bigEndian(bytes, at: offset + 4)
            XCTAssertEqual(Array(bytes[offset + 9..<offset + 12]), Array("PNG".utf8))
            offset += length
        }
        XCTAssertEqual(offset, bytes.count, "chunks tile the file exactly")
        XCTAssertEqual(Set(types), [
            "icp4", "icp5", "ic11", "ic12", "ic07", "ic08", "ic13", "ic09", "ic14", "ic10",
        ])
    }

    @MainActor
    func testNestedFoldersBecomeNestedSets() throws {
        let (_, source) = try makeSVGIcon()
        let lucide = folder.appending(path: "Lucide")
        let layout = [("", "logo.svg"), ("Outline", "a.svg"), ("Outline/Small", "b.svg")]
        for (subfolder, file) in layout {
            let directory = subfolder.isEmpty ? lucide : lucide.appending(path: subfolder)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Each a different icon, as real ones are; identical files would be skipped as
            // duplicates.
            try distinctCopy(of: source, marked: file, to: directory.appending(path: file))
        }
        try FileManager.default.createDirectory(
            at: lucide.appending(path: "Empty"), withIntermediateDirectories: true
        )

        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([lucide], into: nil)

        XCTAssertEqual(
            library.setPaths.map(\.path),
            ["Lucide", "Lucide › Outline", "Lucide › Outline › Small"],
            "a folder with no icons anywhere inside makes no set"
        )
        let root = try XCTUnwrap(library.setPaths.first?.set)
        XCTAssertEqual(library.icons(in: .set(root.id)).map(\.name), ["a", "b", "logo"],
                       "a set shows the icons of the sets inside it")
        XCTAssertEqual(library.count(in: .set(root.id)), 3)
    }

    @MainActor
    func testDeletingASetDeletesWhatIsInsideIt() throws {
        let (_, source) = try makeSVGIcon()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)
        let other = library.createSet(named: "Other")
        library.importItems([source], into: inner.id)
        let another = folder.appending(path: "another.svg")
        try distinctCopy(of: source, marked: "another", to: another)
        library.importItems([another], into: other.id)

        library.perform(.set(outer, iconCount: 1, setCount: 1))

        XCTAssertEqual(library.sets.map(\.name), ["Other"])
        XCTAssertEqual(library.icons.count, 1)
        XCTAssertEqual(library.icons.first?.setID, other.id)
    }

    @MainActor
    func testASetCannotMoveIntoItself() {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)

        library.moveSet(outer.id, into: inner.id)
        XCTAssertNil(library.sets.first { $0.id == outer.id }?.parentID, "would have made a loop")

        library.moveSet(inner.id, into: nil)
        XCTAssertEqual(library.children(of: nil).map(\.name), ["Inner", "Outer"])
    }

    @MainActor
    func testLibrarySavedBeforeNestingStillLoads() throws {
        let libraryFolder = folder.appending(path: "Library")
        try FileManager.default.createDirectory(
            at: libraryFolder, withIntermediateDirectories: true
        )
        // Exactly what the app wrote at 08:05 on 2026-10-02, before sets had parents.
        let saved = #"{"icons":[],"sets":[{"id":"3C93B1B0-C34D-42FB-AB1C-C5A93E3BB3BE",""#
            + #"name":"MacOS"}]}"#
        try Data(saved.utf8).write(to: libraryFolder.appending(path: "library.json"))

        let library = Library(folder: libraryFolder, preferences: preferences())
        XCTAssertNil(library.notice)
        XCTAssertEqual(library.setPaths.map(\.path), ["MacOS"])
    }

    @MainActor
    func testEveryFormatWritesItsOwnKindOfFile() throws {
        let (icon, source) = try makeSVGIcon()
        let magic: [ExportFormat: [UInt8]] = [
            .png: [0x89, 0x50, 0x4E, 0x47], .jpg: [0xFF, 0xD8, 0xFF], .gif: Array("GIF8".utf8),
            .pdf: Array("%PDF".utf8), .ico: [0, 0, 1, 0], .icns: Array("icns".utf8),
        ]
        for format in ExportFormat.allCases {
            var options = ExportOptions()
            options.format = format
            let files = try Exporter.files(
                for: icon, source: source, image: NSImage(contentsOf: source), options: options
            )
            let bytes = [UInt8](try XCTUnwrap(files.first).data)
            switch format {
            case .tiff:
                let littleEndian = bytes.starts(with: [0x49, 0x49, 0x2A, 0])
                XCTAssertTrue(littleEndian || bytes.starts(with: [0x4D, 0x4D, 0, 0x2A]))
            case .svg, .original:
                XCTAssertEqual(files[0].data, try Data(contentsOf: source), "\(format): as is")
            case .imageset:
                XCTAssertTrue(
                    String(decoding: files[0].data, as: UTF8.self).contains("\"images\""),
                    "imageset: Contents.json first"
                )
            default:
                XCTAssertTrue(bytes.starts(with: try XCTUnwrap(magic[format])), "\(format)")
            }
            // An image set's files live inside the named folder; everything else is the name.
            XCTAssertTrue(
                files[0].name.hasPrefix(Exporter.fileNames(for: icon, options: options)[0]),
                "\(format)"
            )
        }
    }

    @MainActor
    func testFillAndBackgroundColourBitmaps() throws {
        let (icon, source) = try makeSVGIcon()
        let image = NSImage(contentsOf: source)
        func exported(_ change: (inout ExportOptions) -> Void) throws -> NSBitmapImageRep {
            var options = ExportOptions()
            options.pngSizes = [64]
            change(&options)
            let file = try Exporter.files(for: icon, source: source, image: image, options: options)
            return try XCTUnwrap(NSBitmapImageRep(data: file[0].data))
        }

        let red = ExportColor(red: 1, green: 0, blue: 0)
        let filled = try XCTUnwrap(try exported { $0.fill = red }.cgImage)
        let color = try XCTUnwrap(Raster.singleColor(of: filled))
        XCTAssertEqual(color.x, 1, accuracy: 0.03, "the black house is drawn red")
        XCTAssertEqual(color.y + color.z, 0, accuracy: 0.05)

        let corner = { (rep: NSBitmapImageRep) in try XCTUnwrap(rep.colorAt(x: 0, y: 0)) }
        XCTAssertEqual(try corner(exported { _ in }).alphaComponent, 0, "transparent by default")
        let blue = try corner(exported { $0.background = ExportColor(red: 0, green: 0, blue: 1) })
        XCTAssertEqual(blue.alphaComponent, 1)
        XCTAssertEqual(blue.blueComponent, 1, accuracy: 0.02)
        let jpg = try corner(exported { $0.format = .jpg })
        XCTAssertEqual(jpg.redComponent + jpg.greenComponent + jpg.blueComponent, 3, accuracy: 0.05,
                       "JPG can't be transparent, so it gets white rather than black")
    }

    func testFileNamesTakePrefixSuffixAndSize() {
        let icon = Icon(name: "home", setID: UUID(), kind: .svg)
        var options = ExportOptions()
        options.prefix = "ic_"
        options.suffix = "_24"
        options.pngSizes = [32]
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["ic_home_24.png"])
        options.includeSize = true
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["ic_home_24-32.png"])
        options.format = .ico
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["ic_home_24.ico"],
                       "one file holds every size, so no size in its name")
        options.format = .original
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["ic_home_24.svg"])
    }

    @MainActor
    func testLicencesStartWithIconJarsAndLeaveIconsWhenRemoved() throws {
        let (_, source) = try makeSVGIcon()
        let folder = self.folder.appending(path: "Library")
        let library = Library(folder: folder, preferences: preferences())
        XCTAssertEqual(library.licenses.first?.name, "MIT")
        XCTAssertEqual(library.licenses.count, 9)
        library.importItems([source], into: library.createSet(named: "Set").id)
        let icon = try XCTUnwrap(library.icons.first)
        let mit = try XCTUnwrap(library.licenses.first)
        library.setLicense([icon.id], mit.id)
        library.setInfo(icon.id, "  A house.  ")
        library.setTags(icon.id, ["home", " building ", ""])

        let reopened = Library(folder: folder, preferences: preferences())
        let saved = try XCTUnwrap(reopened.icons.first)
        XCTAssertEqual(reopened.license(of: saved)?.name, "MIT")
        XCTAssertEqual(saved.info, "A house.")
        XCTAssertEqual(saved.tags, ["home", "building"])

        reopened.removeLicense(mit.id)
        XCTAssertNil(reopened.icons.first?.licenseID)
        XCTAssertEqual(Library(folder: folder, preferences: preferences()).licenses.count, 8)
    }

    @MainActor
    func testAppIconPresetWritesAppleSizesUnderTheirNames() throws {
        let (icon, source) = try makeSVGIcon()
        let preset = try XCTUnwrap(ExportPreset.builtIn.first { $0.name == "App Icon" })
        let files = try ExportOptions().outputs(of: preset).flatMap {
            try Exporter.files(
                for: icon, source: source, image: NSImage(contentsOf: source), options: $0
            )
        }
        XCTAssertEqual(files.map(\.name), [
            "16x16-home.png", "16x16-home@2x.png", "32x32-home.png", "32x32-home@2x.png",
            "128x128-home.png", "128x128-home@2x.png", "256x256-home.png", "256x256-home@2x.png",
            "512x512-home.png", "512x512-home@2x.png",
        ])
        let widths = files.compactMap { NSBitmapImageRep(data: $0.data)?.pixelsWide }
        XCTAssertEqual(widths, [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])
    }

    func testBuiltInPresetsNameTheirFilesLikeIconJar() throws {
        let icon = Icon(name: "home", setID: UUID(), kind: .svg)
        func preset(_ name: String) throws -> ExportPreset {
            try XCTUnwrap(ExportPreset.builtIn.first { $0.name == name })
        }
        func names(_ name: String) throws -> [String] {
            try ExportOptions().outputs(of: preset(name)).flatMap {
                Exporter.fileNames(for: icon, options: $0)
            }
        }
        XCTAssertEqual(ExportPreset.builtIn.count, 11)
        XCTAssertEqual(try names("Tab Bar Icon"), ["home.png", "home@2x.png", "home@3x.png"])
        XCTAssertEqual(try preset("Tab Bar Icon").outputs.map(\.sizes), [[25], [50], [75]])
        XCTAssertEqual(try names("Action Bar, Dialog & Tab Icons"), [
            "home-mdpi.png", "home-hdpi.png", "home-xhdpi.png", "home-xxhdpi.png",
            "home-xxxhdpi.png",
        ])
        XCTAssertEqual(try preset("Notification Icons").outputs.flatMap(\.sizes),
                       [22, 33, 44, 66, 88])
        XCTAssertEqual(try names("Toolbar Icon"), ["home-19.png", "home-24.png"],
                       "two outputs that would share a name get their sizes")
        XCTAssertEqual(try names("Favicon"), ["home.ico"])
    }

    @MainActor
    func testSavingAPresetKeepsTheCurrentSettings() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.export = ExportOptions()
        library.export.format = .jpg
        library.export.sizes = [48, 96]
        library.export.prefix = "ic_"
        library.savePreset(named: "Web JPGs")

        let preset = try XCTUnwrap(library.activePreset)
        XCTAssertEqual(preset.name, "Web JPGs")
        XCTAssertFalse(preset.isBuiltIn)
        let icon = Icon(name: "home", setID: UUID(), kind: .svg)
        let names = library.export.outputs(of: preset).flatMap {
            Exporter.fileNames(for: icon, options: $0)
        }
        XCTAssertEqual(names, ["ic_home-48.jpg", "ic_home-96.jpg"])
        XCTAssertEqual(ExportPreset.loadSaved().map(\.name), ["Web JPGs"], "kept for next launch")

        library.deletePreset(preset.id)
        XCTAssertNil(library.activePreset)
        XCTAssertTrue(ExportPreset.loadSaved().isEmpty)
    }

    func testSearchMatchesEveryWordAcrossTheChosenFields() {
        var icon = Icon(name: "arrow-left", setID: UUID(), kind: .svg)
        icon.tags = ["navigation"]
        icon.info = "Points back"
        func finds(_ query: String, _ scope: SearchScope = SearchScope()) -> Bool {
            iconMatches(icon, query: query, setPath: "Lucide › Outline", scope: scope)
        }
        XCTAssertTrue(finds("row"), "anywhere in a word")
        XCTAssertTrue(finds("ARROW nav"), "every word, in any searched field, in any case")
        XCTAssertFalse(finds("arrow right"), "every word has to match")
        XCTAssertFalse(finds("lucide"), "set names are off by default")
        XCTAssertTrue(finds("lucide", SearchScope(setNames: true)), "the whole set path counts")
        XCTAssertFalse(finds("navigation", SearchScope(tags: false)))
        XCTAssertTrue(finds("back", SearchScope(descriptions: true)))
        XCTAssertTrue(finds("   "))
    }

    @MainActor
    func testGridSortsByNameTypeOrDate() throws {
        let preferences = preferences()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        let set = library.createSet(named: "Set")
        // Imported b, then a, then c, so Date Added (newest first) reads c, a, b.
        library.importItems([try writePNG("b")], into: set.id)
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: set.id)
        library.importItems([try writeSVG("c", #"<path d="M2 2h4"/>"#)], into: set.id)
        func order() -> [String] { library.icons(in: .set(set.id)).map(\.name) }

        XCTAssertEqual(order(), ["a", "b", "c"])
        preferences.sort = .fileType
        XCTAssertEqual(order(), ["b", "a", "c"], "PNG before SVG, then by name")
        preferences.sort = .dateAdded
        XCTAssertEqual(order(), ["c", "a", "b"], "a date sort starts newest first")
        preferences.sortDescending = false
        XCTAssertEqual(order(), ["b", "a", "c"], "flipped by the direction setting")
        preferences.sort = .dateUsed
        library.update([try XCTUnwrap(library.icons.first { $0.name == "b" }).id]) {
            $0.lastUsed = .now
        }
        XCTAssertEqual(order(), ["b", "a", "c"], "the used icon first, the never-used by name")
        preferences.sort = .name
        XCTAssertFalse(preferences.sortDescending, "picking a key resets the direction")
        XCTAssertEqual(order(), ["a", "b", "c"])
    }

    @MainActor
    func testBatchRenameReplacesAddsAndSequences() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let set = library.createSet(named: "Set")
        library.importItems(
            [
                try writeSVG("Arrow-Left", #"<path d="M1 1h4"/>"#),
                try writeSVG("arrow-right", #"<path d="M2 1h4"/>"#),
                try writeSVG("star", #"<path d="M3 1h4"/>"#),
            ], into: set.id
        )
        let all = Set(library.icons.map(\.id))
        func names() -> [String] { library.visibleIcons.map(\.name) }

        // Replace ignores case, swaps every occurrence, and leaves non-matches alone.
        var rename = BatchRename()
        rename.mode = .replace
        rename.find = "ARROW"
        rename.replacement = "nav"
        library.batchRename(all, applying: rename)
        XCTAssertEqual(names(), ["nav-Left", "nav-right", "star"])

        // Add wraps every name.
        rename = BatchRename()
        rename.mode = .add
        rename.suffix = "-24"
        library.batchRename(all, applying: rename)
        XCTAssertEqual(names(), ["nav-Left-24", "nav-right-24", "star-24"])

        // Sequence numbers in grid order from the chosen start.
        rename = BatchRename()
        rename.mode = .sequence
        rename.base = "Glyph"
        rename.startsAt = 3
        library.batchRename(all, applying: rename)
        XCTAssertEqual(names(), ["Glyph 3", "Glyph 4", "Glyph 5"])

        // Empty inputs change nothing.
        library.batchRename(all, applying: BatchRename())
        XCTAssertEqual(names(), ["Glyph 3", "Glyph 4", "Glyph 5"])
    }

    @MainActor
    func testCheckLibraryFindsDuplicatesMissingFilesAndOrphans() async throws {
        // Duplicates have to get in, so import-time skipping is off.
        let preferences = preferences { $0.skipsDuplicates = false }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        let set = library.createSet(named: "Set")
        let body = #"<path d="M3 10l9-7 9 7"/>"#
        let original = try writeSVG("house", body)
        let copy = folder.appending(path: "house copy.svg")
        try FileManager.default.copyItem(at: original, to: copy)
        library.importItems([original, copy, try writeSVG("solo", #"<circle r="5"/>"#)], into: set.id)
        XCTAssertEqual(library.icons.count, 3)

        // One icon loses its file; one stray file appears beside the others.
        let lost = try XCTUnwrap(library.icons.first { $0.name == "solo" })
        let iconsFolder = library.fileURL(for: lost).deletingLastPathComponent()
        try FileManager.default.removeItem(at: library.fileURL(for: lost))
        let stray = iconsFolder.appending(path: "stray.svg")
        try Data(body.utf8).write(to: stray)

        await library.checkLibrary()
        let check = try XCTUnwrap(library.check)
        XCTAssertEqual(check.duplicateGroups.count, 1)
        XCTAssertEqual(check.duplicateGroups.first?.count, 2)
        XCTAssertEqual(check.missing.map(\.name), ["solo"])
        XCTAssertEqual(check.orphans.map(\.lastPathComponent), ["stray.svg"])

        library.deleteDuplicates()
        XCTAssertEqual(library.icons.count { $0.name.hasPrefix("house") }, 1, "oldest kept")
        library.removeMissingRecords()
        XCTAssertFalse(library.icons.contains { $0.name == "solo" })
        library.trashOrphans()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stray.path(percentEncoded: false))
        )

        await library.checkLibrary()
        XCTAssertEqual(library.check?.isClean, true)
    }

    @MainActor
    func testSmartSetsTagRowsAndFieldPrefixes() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let set = library.createSet(named: "Lucide")
        library.importItems(
            [
                try writeSVG("arrow-left", #"<path d="M1 1h4"/>"#),
                try writePNG("banana"),
            ], into: set.id
        )
        let arrow = try XCTUnwrap(library.icons.first { $0.name == "arrow-left" })
        library.addTags([arrow.id], ["navigation"])

        // A word can name its field, whatever the scope says.
        func matches(_ icon: Icon, _ query: String) -> Bool {
            iconMatches(icon, query: query, setPath: "Lucide", scope: SearchScope())
        }
        let banana = try XCTUnwrap(library.icons.first { $0.name == "banana" })
        XCTAssertTrue(matches(library.icons[0], "kind:svg") != matches(banana, "kind:svg"))
        XCTAssertTrue(matches(try XCTUnwrap(library.icons.first { $0.id == arrow.id }), "tag:nav"))
        XCTAssertFalse(matches(banana, "tag:nav"))
        XCTAssertTrue(matches(banana, "set:lucide"))
        XCTAssertFalse(matches(banana, "arrow"))

        // The tag row shows just its icons.
        XCTAssertEqual(library.tagCounts.map(\.tag), ["navigation"])
        XCTAssertEqual(library.icons(in: .tag("navigation")).map(\.id), [arrow.id])
        XCTAssertEqual(library.count(in: .tag("navigation")), 1)

        // A saved search becomes a sidebar item run against the live library.
        library.searchText = "kind:svg"
        library.saveSearchAsSmartSet()
        let smart = try XCTUnwrap(library.smartSets.first)
        XCTAssertEqual(library.sidebar, .smart(smart.id))
        XCTAssertTrue(library.searchText.isEmpty, "the search moved into the smart set")
        XCTAssertEqual(library.icons(in: .smart(smart.id)).map(\.id), [arrow.id])
        XCTAssertEqual(library.count(in: .smart(smart.id)), 1)
        library.importItems([try writeSVG("circle", #"<circle r="4"/>"#)], into: set.id)
        XCTAssertEqual(library.count(in: .smart(smart.id)), 2, "live: new icons join it")

        library.deleteSmartSet(smart.id)
        XCTAssertTrue(library.smartSets.isEmpty)
        XCTAssertEqual(library.sidebar, .all, "the deleted smart set was showing")
    }

    @MainActor
    func testUndoRestoresEditsDeletionsAndImports() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let undo = UndoManager()
        // One group per action, opened by hand: the implicit per-event grouping needs a run
        // loop, and a test turn has none.
        undo.groupsByEvent = false
        library.undoManager = undo
        func grouped<T>(_ body: () throws -> T) rethrows -> T {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            return try body()
        }
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        let set = grouped { library.createSet(named: "Set") }
        let home = try writeSVG("home", #"<path d="M3 10l9-7 9 7"/>"#)
        grouped { library.importItems([home], into: set.id) }
        let icon = try XCTUnwrap(library.icons.first)
        let file = library.fileURL(for: icon)

        grouped { library.rename(icon.id, to: "hut") }
        XCTAssertEqual(undo.undoActionName, "Rename")
        undo.undo()
        XCTAssertEqual(library.icons.first?.name, "home")
        undo.redo()
        XCTAssertEqual(library.icons.first?.name, "hut")

        XCTAssertTrue(exists(file))
        grouped { library.perform(.icons([icon.id])) }
        XCTAssertTrue(library.icons.isEmpty, "deleted")
        XCTAssertFalse(exists(file), "its file went to the Trash")
        undo.undo()
        XCTAssertEqual(library.icons.first?.name, "hut", "undo brings the icon back")
        XCTAssertTrue(exists(file), "and its file with it")

        // Undoing an import takes the copies out of the library; redo returns them.
        undo.undo()  // the rename, back to "home", so the import is next on the stack
        undo.undo()
        XCTAssertTrue(library.icons.isEmpty, "the import is undone")
        XCTAssertFalse(exists(file))
        undo.redo()
        XCTAssertEqual(library.icons.first?.name, "home")
        XCTAssertTrue(exists(file))

        // Deleting the set takes the tree and its icons; undo rebuilds it whole.
        let kept = try XCTUnwrap(library.sets.first)
        grouped { library.perform(.set(kept, iconCount: 1, setCount: 0)) }
        XCTAssertTrue(library.sets.isEmpty)
        XCTAssertTrue(library.icons.isEmpty)
        undo.undo()
        XCTAssertEqual(library.sets.first?.name, "Set")
        XCTAssertEqual(library.icons.first?.name, "home")
        XCTAssertTrue(exists(file))
    }

    @MainActor
    func testKeyboardSelectionExtendsAndTypesAhead() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let set = library.createSet(named: "Set")
        library.importItems(
            [
                try writeSVG("apple", #"<path d="M1 1h4"/>"#),
                try writeSVG("banana", #"<path d="M2 1h4"/>"#),
                try writeSVG("cherry", #"<path d="M3 1h4"/>"#),
            ], into: set.id
        )
        func chosen() -> [String] { library.selectedIcons.map(\.name) }

        XCTAssertEqual(library.moveSelection(by: 1), library.visibleIcons.first?.id)
        XCTAssertEqual(chosen(), ["apple"], "nothing selected: the first icon")
        _ = library.moveSelection(by: 1, extending: true)
        XCTAssertEqual(chosen(), ["apple", "banana"])
        _ = library.moveSelection(by: 1, extending: true)
        XCTAssertEqual(chosen(), ["apple", "banana", "cherry"])
        _ = library.moveSelection(by: -1, extending: true)
        XCTAssertEqual(chosen(), ["apple", "banana"], "stepping back shrinks the range")
        _ = library.selectEnd(true)
        XCTAssertEqual(chosen(), ["cherry"])
        _ = library.selectEnd(false, extending: true)
        XCTAssertEqual(chosen(), ["apple", "banana", "cherry"], "Home with ⇧ reaches the top")
        _ = library.typeToSelect("b")
        XCTAssertEqual(chosen(), ["banana"])
        _ = library.typeToSelect("a")
        XCTAssertEqual(chosen(), ["banana"], "a second letter joins the prefix: 'ba'")
    }

    @MainActor
    func testRecentlyUsedKeepsAsManyAsSettingsSay() throws {
        let preferences = preferences { $0.recentLimit = 25 }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        let files = try (0..<30).map { try writeSVG("icon\($0)", #"<path d="M\#($0) 1h4"/>"#) }
        library.importItems(files, into: library.createSet(named: "Set").id)
        library.update(Set(library.icons.map(\.id))) { $0.lastUsed = .now }
        XCTAssertEqual(library.count(in: .recent), 25)
        XCTAssertEqual(library.icons(in: .recent).count, 25)
    }

    @MainActor
    func testDuplicatesAreLeftOutByContent() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let set = library.createSet(named: "Set")
        let original = try writeSVG("house", #"<path d="M3 10l9-7 9 7"/>"#)
        let renamed = folder.appending(path: "renamed.svg")
        try FileManager.default.copyItem(at: original, to: renamed)
        library.importItems([original], into: set.id)
        let report = library.importItems([renamed], into: set.id)
        XCTAssertEqual(report.duplicates, 1, "a renamed copy is the same file")
        XCTAssertEqual(library.icons.count, 1)

        let copies = folder.appending(path: "Copies")
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copies.appending(path: "x.svg"))
        XCTAssertEqual(library.importItems([copies], into: nil).duplicates, 1)
        XCTAssertEqual(library.sets.map(\.name), ["Set"], "no empty set left behind")

        let allowing = Library(
            folder: folder.appending(path: "Other"),
            preferences: preferences { $0.skipsDuplicates = false }
        )
        allowing.importItems([original, renamed], into: allowing.createSet(named: "Set").id)
        XCTAssertEqual(allowing.icons.count, 2)
    }

    @MainActor
    func testAnSVGsTitleNamesTheIcon() throws {
        let titled = try writeSVG(
            "file-name", #"<title>Home &amp; Garden</title><desc>A house</desc><path d="M1 1h9"/>"#
        )
        let sketch = try writeSVG(
            "sketch", #"<title>bell</title><desc>Created with Sketch.</desc><path d="M2 2h9"/>"#
        )
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([titled, sketch], into: library.createSet(named: "Set").id)
        let home = try XCTUnwrap(library.icons.first { $0.originalName == "file-name" })
        XCTAssertEqual(home.name, "Home & Garden")
        XCTAssertEqual(home.info, "A house")
        let bell = try XCTUnwrap(library.icons.first { $0.originalName == "sketch" })
        XCTAssertEqual(bell.name, "bell")
        XCTAssertNil(bell.info, "an editor's “Created with” line describes nothing")

        let plain = Library(
            folder: folder.appending(path: "Plain"),
            preferences: preferences { $0.readsSVGTitles = false }
        )
        plain.importItems([titled], into: plain.createSet(named: "Set").id)
        XCTAssertEqual(plain.icons.first?.name, "file-name")
    }

    @MainActor
    func testLooseFilesGoWhereSettingsSay() throws {
        let preferences = preferences()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        let inbox = library.createSet(named: "Inbox")
        preferences.looseFilesSetID = inbox.id
        library.importItems([try writeSVG("loose", #"<path d="M1 1h9"/>"#)], into: nil)
        XCTAssertEqual(library.icons.first?.setID, inbox.id)
        XCTAssertFalse(library.sets.contains { $0.name == "Unsorted" })
    }

    @MainActor
    func testDeletingAsksOnlyWhenSettingsSay() throws {
        let preferences = preferences { $0.confirmsIconDeletion = false }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        let set = library.createSet(named: "Set")
        library.importItems([try writeSVG("one", #"<path d="M1 1h9"/>"#)], into: set.id)
        library.requestDeleteIcons(Set(library.icons.map(\.id)))
        XCTAssertTrue(library.icons.isEmpty)
        XCTAssertNil(library.pendingDeletion)

        preferences.confirmsIconDeletion = true
        library.importItems([try writeSVG("two", #"<path d="M2 2h9"/>"#)], into: set.id)
        library.requestDeleteIcons(Set(library.icons.map(\.id)))
        XCTAssertEqual(library.icons.count, 1, "waits for the answer")
        XCTAssertNotNil(library.pendingDeletion)
    }

    func testSVGCleanupChangesOnlyWhatIsAskedFor() {
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Generator: Example -->
        <svg xmlns="http://www.w3.org/2000/svg" width="24px" height="24">
          <path stroke-width="2" d="M1 1h9"/>
        </svg>
        """
        XCTAssertEqual(SVGCleaner.clean(svg, SVGCleanup()), svg, "nothing asked, nothing changed")
        let everything = SVGCleanup(
            removesSize: true, removesComments: true, removesDeclaration: true, compresses: true
        )
        XCTAssertEqual(
            SVGCleaner.clean(svg, everything),
            #"<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">"#
                + #"<path stroke-width="2" d="M1 1h9"/></svg>"#,
            "a viewBox from the size it replaces; stroke-width untouched"
        )
        let sizeOnly = SVGCleanup(removesSize: true)
        let boxed = #"<svg viewBox="0 0 16 16" width="16" height="16"/>"#
        XCTAssertEqual(SVGCleaner.clean(boxed, sizeOnly), #"<svg viewBox="0 0 16 16"/>"#)
        let fluid = #"<svg width="100%" height="100%"><path d="M1 1"/></svg>"#
        XCTAssertEqual(SVGCleaner.clean(fluid, sizeOnly), fluid,
                       "no viewBox and no numbers to make one from, so it is left alone")
        let commented = #"<!-- was <svg width="1" height="1"> --><svg width="24" height="24">"#
            + "</svg>"
        XCTAssertEqual(
            SVGCleaner.clean(commented, sizeOnly),
            #"<!-- was <svg width="1" height="1"> --><svg viewBox="0 0 24 24"></svg>"#,
            "the root element loses its size, not an <svg> written inside a comment"
        )
        let words = #"<svg viewBox="0 0 9 9"> <text><tspan>Hello</tspan> <tspan>World</tspan>"#
            + "</text>\n</svg>"
        XCTAssertEqual(
            SVGCleaner.clean(words, SVGCleanup(compresses: true)),
            #"<svg viewBox="0 0 9 9"><text><tspan>Hello</tspan> <tspan>World</tspan></text>"#
                + "</svg>",
            "the space between two words in a text element stays"
        )
    }

    func testFileNamesAreSafeAndShortEnough() {
        XCTAssertEqual(Exporter.safeFileName("a/b:c"), "a-b-c")
        XCTAssertEqual(Exporter.safeFileName("..hidden"), "hidden")
        XCTAssertEqual(Exporter.safeFileName("two\nlines\u{0}"), "two lines")
        XCTAssertEqual(Exporter.safeFileName(" "), "icon")
        // "é" is two bytes, so 300 of them are 600: cut to 200 bytes, between characters.
        let long = Exporter.safeFileName(String(repeating: "é", count: 300))
        XCTAssertEqual(long.utf8.count, 200)
        XCTAssertEqual(long, String(repeating: "é", count: 100))
    }

    @MainActor
    func testImagesetExportsVectorSVGAndScaledBitmaps() throws {
        var options = ExportOptions()
        options.format = .imageset
        options.pngSizes = [32]

        // An SVG goes in as itself, marked to keep its vector representation.
        let svgSource = try writeSVG("home", #"<path d="M3 10l9-7 9 7"/>"#)
        let svgIcon = Icon(name: "home", setID: UUID(), kind: .svg)
        let vector = try Exporter.files(
            for: svgIcon, source: svgSource, image: NSImage(contentsOf: svgSource),
            options: options
        )
        XCTAssertEqual(
            vector.map(\.name), ["home.imageset/Contents.json", "home.imageset/home.svg"]
        )
        let json = String(decoding: vector[0].data, as: UTF8.self)
        XCTAssertTrue(json.contains("preserves-vector-representation"))

        // Anything else becomes 1x, 2x and 3x PNGs of the picked size.
        let pngSource = try writePNG("photo")
        let pngIcon = Icon(name: "photo", setID: UUID(), kind: .png)
        let bitmap = try Exporter.files(
            for: pngIcon, source: pngSource, image: NSImage(contentsOf: pngSource),
            options: options
        )
        XCTAssertEqual(bitmap.map(\.name), [
            "photo.imageset/Contents.json", "photo.imageset/photo.png",
            "photo.imageset/photo@2x.png", "photo.imageset/photo@3x.png",
        ])
        let widths = bitmap.dropFirst().compactMap { NSBitmapImageRep(data: $0.data)?.pixelsWide }
        XCTAssertEqual(widths, [32, 64, 96])
        XCTAssertFalse(
            String(decoding: bitmap[0].data, as: UTF8.self)
                .contains("preserves-vector-representation")
        )

        // A clash renames at the folder, so a set's contents stay together.
        let out = folder.appending(path: "Out")
        try Exporter.write(vector, to: out)
        try Exporter.write(vector, to: out)
        let listed = try FileManager.default.contentsOfDirectory(atPath:
            out.path(percentEncoded: false)).sorted()
        XCTAssertEqual(listed, ["home 2.imageset", "home.imageset"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: out.appending(path: "home 2.imageset/Contents.json")
                .path(percentEncoded: false)
        ))
    }

    func testExportNamesFollowTheNamingSetting() {
        var icon = Icon(name: "Home", setID: UUID(), kind: .svg)
        icon.originalName = "ic_home_24"
        icon.tags = ["house", "building"]
        var options = ExportOptions()
        options.pngSizes = [32]
        options.naming = .originalFileName
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["ic_home_24.png"])
        options.naming = .tags
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["house-building.png"])
        icon.tags = []
        icon.originalName = nil
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["Home.png"])
        options.naming = .originalFileName
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["Home.png"],
                       "icons from before original names were kept use their name")
    }

    @MainActor
    func testExportCanKeepSetFoldersAndAddFinderTags() throws {
        let preferences = preferences {
            $0.keepsSetFolders = true
            $0.addsFinderTags = true
        }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        library.export = ExportOptions()
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)
        let (_, source) = try makeSVGIcon()
        library.importItems([source], into: inner.id)
        let icon = try XCTUnwrap(library.icons.first)
        library.setTags(icon.id, ["house"])

        let result = library.export(library.icons, to: folder.appending(path: "Out"))
        XCTAssertEqual(result.problems, [])
        let file = try XCTUnwrap(result.written.first)
        XCTAssertEqual(file.pathComponents.suffix(4), ["Out", "Outer", "Inner", "home.png"])
        XCTAssertEqual(try file.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["house"])
    }

    func testOnlyTheNewestBackupsAreKept() throws {
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for name in [
            "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup",
            "Iconery Backup 2026-09-01 at 10.00.00.zip",
            "Iconery Backup 2026-09-03 at 10.00.00.iconerybackup",
            "Iconery Backup 2026-09-04 at 10.00.00.iconerybackup",
            "Notes.zip", "Iconery Backup.txt",
        ] {
            try Data().write(to: backups.appending(path: name))
        }
        let owned = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path()))
        XCTAssertEqual(
            Library.backupsToPrune(in: backups, keeping: 2, owned: owned).map(\.lastPathComponent),
            [
                "Iconery Backup 2026-09-01 at 10.00.00.zip",
                "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup",
            ],
            "only the oldest of this app's backups, old .zip ones included; other files are "
                + "never touched"
        )
        XCTAssertEqual(
            Library.backupsToPrune(in: backups, keeping: 0, owned: owned), [], "0 keeps everything"
        )
    }

    @MainActor
    func testPruningReadsTheDateInTheNameNotPlainTextOrder() throws {
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for name in [
            "Iconery Backup 2026-09-01 at 10.00.00.iconerybackup",
            // Two in the same second: the " 2" uniqueURL adds sorts before the dot as plain
            // text, which used to make the newer file the first one trashed.
            "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup",
            "Iconery Backup 2026-09-02 at 10.00.00 2.iconerybackup",
            // Starts with the prefix but isn't a backup; it used to count as the newest.
            "Iconery Backup keep.zip",
            "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup.partial",
        ] {
            try Data().write(to: backups.appending(path: name))
        }
        // One a dead app left, not one still being written.
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-2 * 3600)],
            ofItemAtPath: backups.appending(
                path: "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup.partial"
            ).path(percentEncoded: false)
        )
        let owned = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path()))
        XCTAssertEqual(
            Library.backupsToPrune(in: backups, keeping: 2, owned: owned).map(\.lastPathComponent),
            ["Iconery Backup 2026-09-01 at 10.00.00.iconerybackup"],
            "the same-second pair counts \" 2\" as newer, and only real backup names count"
        )
        Library.pruneBackups(in: backups, keeping: 2, owned: owned)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: backups.path()).sorted(),
            [
                "Iconery Backup 2026-09-02 at 10.00.00 2.iconerybackup",
                "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup",
                "Iconery Backup keep.zip",
            ],
            "pruning also clears a .partial a dead app left behind, and keeps the user's file"
        )
    }

    @MainActor
    func testSavingFollowsALibraryFolderMovedInFinder() throws {
        let (_, source) = try makeSVGIcon()
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.importItems([source], into: library.createSet(named: "Set").id)

        // What Finder's rename or move amounts to on disk, mid-session.
        let moved = folder.appending(path: "Renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        library.createSet(named: "After")

        // By name, not URL: the bookmark resolves through /private, which /var symlinks to.
        XCTAssertEqual(library.folder.lastPathComponent, "Renamed",
                       "the library carries on in the moved folder")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: original.path(percentEncoded: false)),
            "nothing recreates the old path: that would split the library in two"
        )
        let reopened = Library(folder: moved, preferences: preferences())
        XCTAssertEqual(reopened.setPaths.map(\.path), ["After", "Set"])
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)))
    }

    @MainActor
    func testCheckLibraryActionsIgnoreWhatChangedDuringTheScan() async throws {
        let (_, source) = try makeSVGIcon()
        // Import-time duplicate skipping off, or the identical "copy" below never gets in.
        let library = Library(
            folder: folder.appending(path: "Library"),
            preferences: preferences { $0.skipsDuplicates = false }
        )
        library.importItems([source], into: nil)
        await library.checkLibrary()
        XCTAssertEqual(library.check?.orphans, [])

        // An icon imported after the scan: its file is an orphan to the scan's snapshot.
        let late = try writeSVG("late", #"<circle cx="12" cy="12" r="9"/>"#)
        library.importItems([late], into: nil)
        library.check?.orphans = try FileManager.default.contentsOfDirectory(
            at: library.iconsFolder, includingPropertiesForKeys: nil
        )
        library.trashOrphans()
        for icon in library.icons {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: library.fileURL(for: icon).path(percentEncoded: false)
                ),
                "“\(icon.name)” is live, so its file is not an orphan to trash"
            )
        }

        // A duplicate group whose oldest copy went after the scan keeps its oldest survivor.
        let copy = try writeSVG("copy", #"<circle cx="12" cy="12" r="9"/>"#)
        library.importItems([copy], into: nil)
        await library.checkLibrary()
        let group = try XCTUnwrap(library.check?.duplicateGroups.first)
        XCTAssertEqual(group.count, 2)
        library.perform(.icons([try XCTUnwrap(group.first).id]))
        library.deleteDuplicates()
        XCTAssertEqual(
            library.icons.filter { $0.name == "copy" || $0.name == "late" }.count, 1,
            "the remaining copy survives; deleting it too would wipe the whole group"
        )
    }

    @MainActor
    func testUndoKeepsARecentlyUsedStampMadeAfterTheStep() throws {
        let (_, source) = try makeSVGIcon()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let undoManager = UndoManager()
        // One group per action, opened by hand: the implicit per-event grouping needs a run
        // loop, and a test turn has none.
        undoManager.groupsByEvent = false
        library.undoManager = undoManager
        func act(_ change: () -> Void) {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            change()
        }
        act { library.importItems([source], into: nil) }
        let id = try XCTUnwrap(library.icons.first).id

        act { library.rename(id, to: "Renamed") }
        // A copy stamps Recently Used outside any undo step.
        library.update([id]) { $0.lastUsed = .now }
        let stamped = try XCTUnwrap(library.icons.first?.lastUsed)
        undoManager.undo()

        XCTAssertNotEqual(library.icons.first?.name, "Renamed")
        XCTAssertEqual(library.icons.first?.lastUsed, stamped,
                       "undoing the rename doesn't revert the later stamp")
        act { library.clearRecents() }
        undoManager.undo()
        XCTAssertEqual(library.icons.first?.lastUsed, stamped,
                       "undoing Clear Recently Used puts the dates back")
    }

    @MainActor
    func testScheduledBackupRunsOnlyWhenDue() async throws {
        let preferences = preferences { $0.backupSchedule = .daily }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        library.createSet(named: "Set")
        let backups = folder.appending(path: "Backups")
        try library.changeBackupFolder(to: backups)
        func count() -> Int { names(in: backups).count }

        await library.backUpIfDue()
        XCTAssertNil(library.notice)
        XCTAssertEqual(count(), 1, "never backed up, so one is due")
        await library.backUpIfDue()
        XCTAssertEqual(count(), 1, "the next isn't due for a day")
    }

    func testExportOptionsSavedBeforeICNSKeepTheirSizes() throws {
        let saved = #"{"format":"ico","pngSizes":[64],"icoSizes":[16,32]}"#
        let options = try JSONDecoder().decode(ExportOptions.self, from: Data(saved.utf8))
        XCTAssertEqual(options.format, .ico)
        XCTAssertEqual(options.icoSizes, [16, 32])
        XCTAssertEqual(options.icnsSizes, ExportOptions.icnsChoices)
        XCTAssertNil(options.fill)
        XCTAssertEqual(options.prefix, "")
        XCTAssertFalse(options.includeSize)
    }

    @MainActor
    func testBackupUnzipsToTheSameLibrary() async throws {
        let (_, source) = try makeSVGIcon()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)
        library.importItems([source], into: inner.id)
        library.toggleStar(Set(library.icons.map(\.id)))

        let backup = folder.appending(path: "Backup.iconerybackup")
        try await library.writeBackup(to: backup)

        let unpacked = folder.appending(path: "Unpacked")
        let unzip = try Process.run(
            URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", backup.path(percentEncoded: false),
                        unpacked.path(percentEncoded: false)]
        )
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)

        let restored = Library(
            folder: unpacked.appending(path: "Library"), preferences: preferences()
        )
        // Against a fresh load, not `library`: the index stores dates to the second, so the
        // in-memory `added` carries fractions that never reach disk.
        let saved = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        XCTAssertEqual(restored.setPaths.map(\.path), ["Outer", "Outer › Inner"])
        XCTAssertEqual(restored.icons, saved.icons, "names, sets, tags and stars all survive")
        XCTAssertEqual(restored.icons.map(\.starred), [true])
        XCTAssertNotNil(restored.image(for: try XCTUnwrap(restored.icons.first)),
                        "and the icon file itself came along")
    }

    @MainActor
    func testAFailedBackupLeavesNoPartOfAZip() async throws {
        let (_, source) = try makeSVGIcon()
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([source], into: nil)
        // The snapshot copy clones, which writes nothing, but ditto has to write the zip: with
        // files capped well below the library's size it stops part way with a zip begun, which
        // is what the cleanup under test is for.
        try Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
            .write(to: library.iconsFolder.appending(path: "filler.bin"))
        let restore = capFileSize(at: 64 * 1024)
        defer { restore() }
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        do {
            try await library.writeBackup(to: backups.appending(path: "Iconery Backup x.zip"))
            XCTFail("the backup can't succeed under the cap")
        } catch {
            XCTAssertTrue(error is Library.Problem, "ditto is what failed, not the copy: \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path()), [],
                       "nothing is left for pruning to count as a backup")
    }

    @MainActor
    func testAnUnreadableLibraryIsNeverSavedOver() throws {
        let (_, source) = try makeSVGIcon()
        let libraryFolder = folder.appending(path: "Library")
        Library(folder: libraryFolder, preferences: preferences()).importItems([source], into: nil)
        let index = libraryFolder.appending(path: "library.json")
        let before = try Data(contentsOf: index)
        let path = index.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let readable: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        defer { try? FileManager.default.setAttributes(readable, ofItemAtPath: path) }

        let library = Library(folder: libraryFolder, preferences: preferences())
        XCTAssertNotNil(library.notice, "says it couldn't read the library")
        library.createSet(named: "New")

        try FileManager.default.setAttributes(readable, ofItemAtPath: path)
        XCTAssertEqual(try Data(contentsOf: index), before, "and wrote nothing over it")
    }

    @MainActor
    func testALoopOfParentSetsStillOpens() throws {
        let libraryFolder = folder.appending(path: "Library")
        try FileManager.default.createDirectory(
            at: libraryFolder, withIntermediateDirectories: true
        )
        // No Iconery writes this, but a damaged or hand-edited file could: A inside B inside A.
        let a = "3C93B1B0-C34D-42FB-AB1C-C5A93E3BB3BE"
        let b = "5B0F3E4C-9A47-4C55-9D3B-6A8F1E2D7C10"
        let saved = #"{"icons":[],"sets":[{"id":"\#(a)","name":"A","parentID":"\#(b)"},"#
            + #"{"id":"\#(b)","name":"B","parentID":"\#(a)"}]}"#
        try Data(saved.utf8).write(to: libraryFolder.appending(path: "library.json"))

        let library = Library(folder: libraryFolder, preferences: preferences())
        XCTAssertEqual(library.setPaths.map(\.path), ["A", "A › B"],
                       "cut where the loop closes, so both sets show")
        XCTAssertEqual(library.subtree(of: try XCTUnwrap(UUID(uuidString: a))).count, 2)
    }

    @MainActor
    func testTheGridAndSidebarFollowEveryChange() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)
        library.importItems([try writeSVG("b", #"<path d="M1 1h4"/>"#)], into: inner.id)
        library.importItems([try writeSVG("a", #"<path d="M2 2h4"/>"#)], into: outer.id)
        func names() -> [String] { library.visibleIcons.map(\.name) }

        XCTAssertEqual(names(), ["a", "b"])
        XCTAssertEqual(library.count(in: .set(outer.id)), 2, "a set counts the sets inside it")
        let b = try XCTUnwrap(library.icons.first { $0.name == "b" })
        library.rename(b.id, to: "0")
        XCTAssertEqual(names(), ["0", "a"], "a rename sorts again")
        library.searchText = "a"
        XCTAssertEqual(names(), ["a"])
        library.searchText = ""
        library.sidebar = .set(inner.id)
        XCTAssertEqual(names(), ["0"])
        library.moveSet(inner.id, into: nil)
        XCTAssertEqual(library.count(in: .set(outer.id)), 1, "a set moved out stops counting")
        library.perform(.icons([b.id]))
        XCTAssertEqual(names(), [])
    }

    @MainActor
    func testAlertsWaitTheirTurn() async throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.notice = Notice(title: "First", message: "")
        library.notice = Notice(title: "Second", message: "")
        XCTAssertEqual(library.notice?.title, "First", "a second alert doesn't replace the first")
        library.notice = nil
        XCTAssertNil(library.notice, "the first closes before the next opens")
        for _ in 0..<10 where library.notice == nil { await Task.yield() }
        XCTAssertEqual(library.notice?.title, "Second")
        library.notice = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(library.notice)
    }

    @MainActor
    func testIconJarLibraryImportsWithItsStructure() throws {
        let (_, svg) = try makeSVGIcon()
        let jar = folder.appending(path: "Mine.ijlibrary")
        for setFolder in ["F-DEV", "F-LOOSE", "F-STAR"] {
            try FileManager.default.createDirectory(
                at: jar.appending(path: "Sets/\(setFolder)"), withIntermediateDirectories: true
            )
        }
        let devFile = jar.appending(path: "Sets/F-DEV/insomnia.svg")
        try FileManager.default.copyItem(at: svg, to: devFile)
        try FileManager.default.copyItem(at: svg, to: jar.appending(path: "Sets/F-LOOSE/box.svg"))
        try Data("GIF89a".utf8).write(to: jar.appending(path: "Sets/F-LOOSE/spin.gif"))
        // IconJar saved one real ICNS on this Mac as "onyx-dark-alt.-null-"; its type column knew.
        let oddFile = jar.appending(path: "Sets/F-LOOSE/odd.-null-")
        try FileManager.default.copyItem(at: svg, to: oddFile)

        // The columns Iconery reads, as IconJar 2.11.4 names them. Group 2 sits inside group 1.
        let groupID = "78E15925-0C0A-4BF5-87AB-83BC99CEB987"
        let devID = "14648FDC-E3B7-4B8D-9B1F-B068032C00E2"
        let iconID = "D122537C-71C1-4718-AE53-8B8D397DB80B"
        try sqlite(jar.appending(path: "Jars.db"), """
        CREATE TABLE ZIJGROUP (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZNAME TEXT, ZGROUP INTEGER);
        CREATE TABLE ZIJCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZIDENTIFIER TEXT,
            ZNAME TEXT, ZGROUP INTEGER, ZTYPE INTEGER);
        CREATE TABLE ZIJITEM (ZUUID TEXT, ZNAME TEXT, ZNEWFILENAME TEXT, ZTAGSSTRING TEXT,
            ZSTARRED INTEGER, ZDATE REAL, ZLASTUSEDDATE REAL, ZCOLLECTION INTEGER, ZTYPE INTEGER);
        INSERT INTO ZIJGROUP VALUES (1, '\(groupID)', 'Mac Icons', NULL);
        INSERT INTO ZIJGROUP VALUES (2, '5B0F3E4C-9A47-4C55-9D3B-6A8F1E2D7C10', 'Apps', 1);
        INSERT INTO ZIJCOLLECTION VALUES (1, '\(devID)', 'F-DEV', 'DevIcon', 2, 0);
        INSERT INTO ZIJCOLLECTION VALUES (2, '__ij_const-starred', 'F-STAR', 'Starred', NULL, 3);
        INSERT INTO ZIJCOLLECTION VALUES (3, '0E2B5D7A-1C3F-4E6B-8A9D-2F4C6E8A0B13', 'F-LOOSE',
            'Loose', NULL, 0);
        INSERT INTO ZIJITEM VALUES ('\(iconID)', 'Insomnia', 'insomnia.svg', 'Insomnia,Alt', 1,
            652987880.86, NULL, 1, 0);
        INSERT INTO ZIJITEM VALUES ('6C1D9E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F', NULL, 'box.svg', NULL,
            0, NULL, NULL, 3, 0);
        INSERT INTO ZIJITEM VALUES ('9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A', 'Spinner', 'spin.gif',
            NULL, 0, NULL, NULL, 3, 2);
        INSERT INTO ZIJITEM VALUES ('2A3B4C5D-6E7F-4081-9203-A4B5C6D7E8F9', 'Odd', 'odd.-null-',
            NULL, 0, NULL, NULL, 3, 0);
        INSERT INTO ZIJITEM VALUES ('7B8C9D0E-1F2A-4B3C-8D4E-5F6A7B8C9D0E', 'Escape',
            '../../../home.svg', NULL, 0, NULL, NULL, 3, 0);
        INSERT INTO ZIJITEM VALUES ('8C9D0E1F-2A3B-4C4D-9E5F-6A7B8C9D0E1F', 'No File', NULL, NULL,
            0, NULL, NULL, 3, 0);
        """)

        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let report = try library.importIconJar(jar, into: nil)

        XCTAssertEqual(report.imported, 3)
        // "../../../home.svg" from Sets/F-LOOSE is the test's own home.svg, a real file.
        XCTAssertEqual(report.skipped, ["spin.gif", "../../../home.svg (outside the library)"])
        XCTAssertEqual(report.incomplete, 1, "the record with no file is counted, not lost")
        XCTAssertEqual(
            library.setPaths.map(\.path),
            ["Loose", "Mac Icons", "Mac Icons › Apps", "Mac Icons › Apps › DevIcon"],
            "groups nest, and IconJar's own Starred set is left behind"
        )
        let insomnia = try XCTUnwrap(library.icons.first { $0.id.uuidString == iconID })
        XCTAssertEqual(insomnia.name, "Insomnia")
        XCTAssertEqual(insomnia.tags, ["Insomnia", "Alt"])
        XCTAssertTrue(insomnia.starred)
        XCTAssertEqual(insomnia.added, Date(timeIntervalSinceReferenceDate: 652987880.86))
        XCTAssertEqual(insomnia.setID.uuidString, devID)
        XCTAssertEqual(library.icons.first { $0.name == "box" }?.kind, .svg,
                       "a nameless icon takes its file name")
        XCTAssertEqual(library.icons.first { $0.name == "Odd" }?.kind, .svg,
                       "a broken extension falls back to IconJar's recorded type")
        XCTAssertNotNil(library.image(for: insomnia), "the file was copied in")

        let again = try library.importIconJar(jar, into: nil)
        XCTAssertEqual(again.imported, 0, "a second import adds nothing that is already here")
        XCTAssertEqual(library.sets.count, 4)
        XCTAssertEqual(library.icons.count, 3)
    }

    func testBothIconJarExtensionsAreRecognised() throws {
        XCTAssertTrue(IconJarLibrary.isLibrary(URL(filePath: "/x/IconJar-backup.ijlibrary")))
        XCTAssertTrue(IconJarLibrary.isLibrary(URL(filePath: "/x/Old.IconJarLibrary")))
        XCTAssertFalse(IconJarLibrary.isLibrary(URL(filePath: "/x/icons")))
        guard let type = IconJarLibrary.libraryType else { throw XCTSkip("IconJar not installed") }
        XCTAssertTrue(type.conforms(to: .package), "the open panel shows a library as one file")
    }

    @MainActor
    func testFolderWithoutJarsDBIsNotAnIconJarLibrary() {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        XCTAssertThrowsError(try library.importIconJar(folder, into: nil))
    }

    private func sqlite(_ url: URL, _ script: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path(percentEncoded: false), &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, script, nil, nil, &error)
        XCTAssertEqual(result, SQLITE_OK, error.map { String(cString: $0) } ?? "")
    }

    private func bigEndian(_ bytes: [UInt8], at offset: Int) -> Int {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    private func makeSVGIcon() throws -> (Icon, URL) {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" \
        stroke-width="2"><path d="M3 10l9-7 9 7v10H3z"/></svg>
        """
        let url = folder.appending(path: "home.svg")
        try Data(svg.utf8).write(to: url)
        return (Icon(name: "home", setID: UUID(), kind: .svg), url)
    }

    // MARK: Fixes 2026-10-09: library folder and backups

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func names(in directory: URL) -> [String] {
        let listing = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )
        // Without the hidden marker a backup folder gets, which isn't one of the backups.
        return (listing ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// An undo manager that groups by hand: the implicit per-event grouping needs a run loop,
    /// and a test turn has none.
    @MainActor
    private func manualUndo(for library: Library) -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        library.undoManager = undoManager
        return undoManager
    }

    @MainActor
    private func act(_ undoManager: UndoManager, _ change: () -> Void) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        change()
    }

    /// Finder's Move to Trash, with the result removed from the real Trash when the test ends.
    private func moveToTrash(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        let trashed = try XCTUnwrap(landed) as URL
        addTeardownBlock { try? FileManager.default.removeItem(at: trashed) }
        return trashed
    }

    @MainActor
    private func iconJarWithOneIcon() throws -> URL {
        let svg = try writeSVG("insomnia", #"<path d="M1 1h4"/>"#)
        let jar = folder.appending(path: "Mine.ijlibrary")
        try FileManager.default.createDirectory(
            at: jar.appending(path: "Sets/F-DEV"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: svg, to: jar.appending(path: "Sets/F-DEV/insomnia.svg")
        )
        try sqlite(jar.appending(path: "Jars.db"), """
        CREATE TABLE ZIJGROUP (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZNAME TEXT, ZGROUP INTEGER);
        CREATE TABLE ZIJCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZIDENTIFIER TEXT,
            ZNAME TEXT, ZGROUP INTEGER, ZTYPE INTEGER);
        CREATE TABLE ZIJITEM (ZUUID TEXT, ZNAME TEXT, ZNEWFILENAME TEXT, ZTAGSSTRING TEXT,
            ZSTARRED INTEGER, ZDATE REAL, ZLASTUSEDDATE REAL, ZCOLLECTION INTEGER, ZTYPE INTEGER);
        INSERT INTO ZIJCOLLECTION VALUES (1, '14648FDC-E3B7-4B8D-9B1F-B068032C00E2', 'F-DEV',
            'DevIcon', NULL, 0);
        INSERT INTO ZIJITEM VALUES ('D122537C-71C1-4718-AE53-8B8D397DB80B', 'Insomnia',
            'insomnia.svg', NULL, 0, NULL, NULL, 1, 0);
        """)
        return jar
    }

    @MainActor
    func testCheckLibraryAfterAFinderMoveFindsNothingMissing() async throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        let files = [
            try writeSVG("a", #"<path d="M1 1h4"/>"#),
            try writeSVG("b", #"<path d="M2 1h4"/>"#),
            try writeSVG("c", #"<path d="M3 1h4"/>"#),
        ]
        library.importItems(files, into: library.createSet(named: "Set").id)
        let undoManager = manualUndo(for: library)

        // Checked once at the old place, so there are results that a move makes stale.
        await library.checkLibrary()
        XCTAssertNotNil(library.check)
        let moved = folder.appending(path: "Renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        act(undoManager) { library.createSet(named: "After") }
        XCTAssertNil(library.check, "following a move drops results about the old place")

        await library.checkLibrary()
        XCTAssertEqual(library.check?.missing.count, 0, "nothing is missing: it only moved")
        act(undoManager) { library.removeMissingRecords() }
        XCTAssertEqual(library.icons.count, 3, "no record is dropped")
        XCTAssertEqual(names(in: moved.appending(path: "Icons")).count, 3, "no file is trashed")
        XCTAssertFalse(exists(original))
    }

    @MainActor
    func testCheckLibraryFollowsAMoveBeforeScanning() async throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        try FileManager.default.moveItem(at: original, to: folder.appending(path: "Renamed"))

        await library.checkLibrary()
        XCTAssertEqual(library.check?.missing.count, 0)
        XCTAssertEqual(library.folder.lastPathComponent, "Renamed")
    }

    @MainActor
    func testImportAfterAFinderMoveWritesIntoTheMovedFolder() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.createSet(named: "Set")
        let moved = folder.appending(path: "Renamed")
        try FileManager.default.moveItem(at: original, to: moved)

        library.importItems([try writeSVG("late", #"<path d="M1 1h4"/>"#)], into: nil)

        XCTAssertFalse(exists(original), "the icon file didn't recreate the old path")
        XCTAssertEqual(names(in: moved.appending(path: "Icons")).count, 1)
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)))
    }

    @MainActor
    func testIconJarImportAfterAFinderMoveStaysInTheMovedFolder() throws {
        let jar = try iconJarWithOneIcon()
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.createSet(named: "Before")
        let moved = folder.appending(path: "Renamed")
        try FileManager.default.moveItem(at: original, to: moved)

        _ = try library.importIconJar(jar, into: nil)

        XCTAssertFalse(exists(original), "the old path must not be recreated")
        let reopened = Library(folder: moved, preferences: preferences())
        XCTAssertTrue(reopened.setPaths.map(\.path).contains("DevIcon"))
        XCTAssertNotNil(reopened.image(for: try XCTUnwrap(reopened.icons.first)))
    }

    @MainActor
    func testUndoAfterAFinderMoveRestoresTheFileIntoTheMovedFolder() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        let undoManager = manualUndo(for: library)
        var set: IconSet!
        act(undoManager) { set = library.createSet(named: "Set") }
        act(undoManager) {
            library.importItems([try! writeSVG("home", #"<path d="M1 1h4"/>"#)], into: set.id)
        }
        let icon = try XCTUnwrap(library.icons.first)
        act(undoManager) { library.perform(.icons([icon.id])) }
        XCTAssertTrue(library.icons.isEmpty)

        let moved = folder.appending(path: "Renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        undoManager.undo()

        let file = moved.appending(path: "Icons").appending(path: icon.fileName)
        XCTAssertTrue(exists(file), "the undone delete brought its file back into the moved folder")
        XCTAssertFalse(exists(original))
        undoManager.redo()
        undoManager.undo()
        XCTAssertTrue(exists(file), "and it can be done again")
    }

    @MainActor
    func testAppBecomingActiveFollowsAMovedFolder() async throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        try FileManager.default.moveItem(at: original, to: folder.appending(path: "Renamed"))

        // Finder moves deactivate the app first; reads such as thumbnails follow on return.
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        for _ in 0..<50 where library.folder.lastPathComponent != "Renamed" {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(library.folder.lastPathComponent, "Renamed")
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)))
    }

    @MainActor
    func testFailedUndoMoveKeepsWhereTheTrashedFileIs() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let undoManager = manualUndo(for: library)
        act(undoManager) {
            library.importItems([try! writeSVG("home", #"<path d="M1 1h4"/>"#)], into: nil)
        }
        let icon = try XCTUnwrap(library.icons.first)
        let file = library.fileURL(for: icon)
        let contents = try Data(contentsOf: file)
        act(undoManager) { library.perform(.icons([icon.id])) }
        XCTAssertFalse(exists(file))

        // Something already sits where the file belongs, so moving it back fails.
        try Data("in the way".utf8).write(to: file)
        undoManager.undo()
        XCTAssertEqual(library.notice?.title, "Some icons came back without their files")
        try FileManager.default.removeItem(at: file)

        // Redo and undo again: the file can still be found in the Trash.
        undoManager.redo()
        undoManager.undo()
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    @MainActor
    func testALibraryInTheTrashIsNeitherFollowedNorWrittenTo() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.createSet(named: "Set")
        let landed = try moveToTrash(original)

        library.createSet(named: "While away")
        let report = library.importItems([try writeSVG("late", #"<path d="M1 1h4"/>"#)], into: nil)

        XCTAssertEqual(report.imported, 0, "an import is refused rather than recreating the path")
        XCTAssertEqual(library.folder, original, "the Trash is not followed")
        XCTAssertFalse(exists(original))
        XCTAssertEqual(library.notice?.title, "Your library is in the Trash")
        XCTAssertTrue(library.notice?.message.contains("Put Back") == true)
        library.notice = nil
        library.createSet(named: "Again")
        XCTAssertNil(library.notice, "said once, not on every edit")
        XCTAssertEqual(
            Library(folder: landed, preferences: preferences()).setPaths.map(\.path), ["Set"],
            "nothing was saved into the Trash"
        )

        // Put Back: saving resumes by itself, with what was changed meanwhile.
        try FileManager.default.moveItem(at: landed, to: original)
        library.createSet(named: "Back")
        XCTAssertEqual(
            Set(Library(folder: original, preferences: preferences()).setPaths.map(\.path)),
            ["Set", "While away", "Again", "Back"]
        )
    }

    @MainActor
    func testUndoInATrashedLibraryDropsThatStepAndKeepsTheRest() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        let undoManager = manualUndo(for: library)
        act(undoManager) {
            library.importItems([try! writeSVG("home", #"<path d="M1 1h4"/>"#)], into: nil)
        }
        act(undoManager) {
            library.importItems([try! writeSVG("star", #"<path d="M2 1h4"/>"#)], into: nil)
        }
        act(undoManager) {
            library.importItems([try! writeSVG("moon", #"<path d="M3 1h4"/>"#)], into: nil)
        }
        let landed = try moveToTrash(original)

        undoManager.undo()

        XCTAssertFalse(exists(original), "undo didn't recreate the old path")
        XCTAssertEqual(
            library.icons.map(\.name).sorted(), ["home", "moon", "star"], "and changed nothing"
        )
        XCTAssertEqual(library.notice?.title, "Your library is in the Trash")
        XCTAssertTrue(
            library.notice?.message.contains("can no longer be undone") == true,
            "it says the step is gone"
        )
        XCTAssertFalse(undoManager.canRedo, "the refused step isn't left to redo as an undo")
        XCTAssertTrue(undoManager.canUndo, "the older steps are still there")
        // Every refusal says so, not just the first.
        library.notice = nil
        undoManager.undo()
        XCTAssertEqual(library.notice?.title, "Your library is in the Trash")
        XCTAssertFalse(undoManager.canRedo)
        library.notice = nil

        try FileManager.default.moveItem(at: landed, to: original)
        undoManager.undo()
        XCTAssertEqual(
            library.icons.map(\.name).sorted(), ["moon", "star"],
            "the one step left undid, the two refused ones are gone"
        )
        XCTAssertTrue(undoManager.canRedo)
    }

    @MainActor
    func testImportsIntoATrashedLibrarySayWhyEveryTime() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.createSet(named: "Set")
        _ = try moveToTrash(original)
        library.createSet(named: "While away")  // the once-only notice goes up here
        library.notice = nil
        let file = try writeSVG("home", #"<path d="M1 1h4"/>"#)

        for _ in 1...2 {
            XCTAssertFalse(library.importAndReport([file], into: nil))
            XCTAssertEqual(library.notice?.title, "Your library is in the Trash")
            library.notice = nil
        }
        let jar = library.importIconJarWithNotice(folder.appending(path: "x.ijlibrary"), into: nil)
        XCTAssertEqual(jar.title, "Your library is in the Trash", "not “Imported 0 icons”")
        XCTAssertTrue(library.icons.isEmpty)
    }

    @MainActor
    func testALibraryMovedOutOfTheTrashIsFollowed() throws {
        let original = folder.appending(path: "Library")
        let library = Library(folder: original, preferences: preferences())
        library.createSet(named: "Set")
        let landed = try moveToTrash(original)
        let rescued = folder.appending(path: "Rescued")
        try FileManager.default.moveItem(at: landed, to: rescued)

        library.createSet(named: "After")

        XCTAssertEqual(library.folder.lastPathComponent, "Rescued")
        XCTAssertFalse(exists(original))
        XCTAssertEqual(Library(folder: rescued, preferences: preferences()).setPaths.count, 2)
    }

    @MainActor
    func testScheduledBackupSitsOutWhileTheLibraryIsInTheTrash() async throws {
        let original = folder.appending(path: "Library")
        let library = Library(
            folder: original, preferences: preferences { $0.backupSchedule = .daily }
        )
        library.createSet(named: "Set")
        let backups = folder.appending(path: "Backups")
        try library.changeBackupFolder(to: backups)
        _ = try moveToTrash(original)

        await library.backUpIfDue()

        XCTAssertFalse(exists(backups), "no backup was written")
        XCTAssertNil(library.lastBackup)
    }

    @MainActor
    func testPruningLeavesAPartialStillBeingWritten() throws {
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stem = "Iconery Backup 2026-09-0"
        let live = backups.appending(path: stem + "2 at 10.00.00.iconerybackup.partial")
        let dead = backups.appending(path: stem + "1 at 10.00.00.iconerybackup.partial")
        for url in [live, dead] { try Data().write(to: url) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-3 * 3600)],
            ofItemAtPath: dead.path(percentEncoded: false)
        )

        Library.pruneBackups(in: backups, keeping: 2, owned: [])

        XCTAssertTrue(exists(live), "another Mac's backup in progress is not ours to trash")
        XCTAssertFalse(exists(dead), "one nothing has touched for hours is")
    }

    @MainActor
    func testABackupFolderInTheTrashCountsAsMissing() async throws {
        let libraryFolder = folder.appending(path: "Library")
        let chosen = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let setup = Library(folder: libraryFolder, preferences: preferences())
        try setup.changeBackupFolder(to: chosen)
        let landed = try moveToTrash(chosen)

        let library = Library(
            folder: libraryFolder, preferences: preferences { $0.backupSchedule = .daily }
        )

        XCTAssertEqual(library.notice?.title, "Your backup folder couldn't be found")
        await library.backUpIfDue()
        XCTAssertNil(library.lastBackup, "the schedule is paused, not writing into the Trash")
        XCTAssertTrue(exists(landed))
        XCTAssertTrue(names(in: landed).isEmpty)
        do {
            try await library.backUp(into: landed)
            XCTFail("a backup was written into the Trash")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, Library.Problem.backupInTrash.errorDescription
            )
        }
        XCTAssertTrue(names(in: landed).isEmpty)
    }

    @MainActor
    func testBackupsListForgetsFilesDeletedByHand() async throws {
        let backups = folder.appending(path: "Backups")
        let library = Library(
            folder: folder.appending(path: "Library"),
            preferences: preferences { $0.backupsKept = 10 }
        )
        library.createSet(named: "Set")
        let first = try await library.backUp(into: backups)
        let second = try await library.backUp(into: backups)
        try FileManager.default.removeItem(at: first)
        // A name freed in the same second would be handed out again by the next backup.
        try await Task.sleep(for: .seconds(1.1))

        let third = try await library.backUp(into: backups)

        let index = try Data(contentsOf: library.folder.appending(path: "library.json"))
        let kept = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: index) as? [String: Any])?["backups"]
                as? [String]
        )
        XCTAssertEqual(
            kept.sorted(), [second, third].map(\.lastPathComponent).sorted(),
            "the name of the file deleted in Finder is no longer kept"
        )
    }

    @MainActor
    func testTheOldSharedLastBackupIsNotGivenToABrandNewLibrary() {
        Library.defaults.set(Date.now.addingTimeInterval(-3600), forKey: Library.lastBackupKey)

        let library = Library(folder: folder.appending(path: "Fresh"), preferences: preferences())

        XCTAssertNil(library.lastBackup, "a library with no index has no backups behind it")
        XCTAssertNotNil(
            Library.defaults.object(forKey: Library.lastBackupKey),
            "and the date stays for the library it belongs to"
        )
    }

    @MainActor
    func testSwitchingLibrariesDropsTheOldLibrarysCheck() async throws {
        let other = folder.appending(path: "Other")
        Library(folder: other, preferences: preferences()).createSet(named: "Theirs")
        let library = Library(folder: folder.appending(path: "Mine"), preferences: preferences())
        library.importItems([try writeSVG("x", #"<path d="M1 1h4"/>"#)], into: nil)
        await library.checkLibrary()
        library.importItems([try writeSVG("y", #"<path d="M2 1h4"/>"#)], into: nil)
        let live = library.fileURL(for: try XCTUnwrap(library.icons.first { $0.name == "y" }))
        // As if "y" had been imported while the scan ran: an orphan to the scan's snapshot.
        library.check?.orphans = [live]

        try library.switchLibrary(to: other)
        XCTAssertNil(library.check, "the old library's results don't survive a switch")
        library.trashOrphans()
        XCTAssertTrue(exists(live))
    }

    @MainActor
    func testACheckThatFinishesAfterASwitchIsThrownAway() async throws {
        let other = folder.appending(path: "Other")
        Library(folder: other, preferences: preferences()).createSet(named: "Theirs")
        let library = Library(folder: folder.appending(path: "Mine"), preferences: preferences())
        library.importItems([try writeSVG("x", #"<path d="M1 1h4"/>"#)], into: nil)

        let scan = Task { await library.checkLibrary() }
        // Yielding rather than sleeping: a scan this small is done within a few milliseconds.
        for _ in 0..<10_000 where !library.isChecking { await Task.yield() }
        XCTAssertTrue(library.isChecking, "the scan never began")
        try library.switchLibrary(to: other)
        await scan.value

        XCTAssertNil(library.check, "results about the library switched away from are dropped")
    }

    @MainActor
    func testOrphansThatCannotBeTrashedStayListedWithANotice() async throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        await library.checkLibrary()
        let vanished = library.iconsFolder.appending(path: "vanished.svg")
        library.check?.orphans = [vanished]

        library.trashOrphans()

        XCTAssertEqual(library.check?.orphans, [vanished], "still listed, so it can be tried again")
        XCTAssertEqual(library.notice?.title, "Some files could not be moved to the Trash")
        XCTAssertTrue(library.notice?.message.contains("1 file") == true)
    }

    @MainActor
    func testUndoingClearRecentlyUsedKeepsANewerStamp() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let undoManager = manualUndo(for: library)
        act(undoManager) {
            library.importItems([try! writeSVG("x", #"<path d="M1 1h4"/>"#)], into: nil)
        }
        let id = try XCTUnwrap(library.icons.first).id
        library.update([id]) { $0.lastUsed = .now.addingTimeInterval(-7 * 86_400) }
        act(undoManager) { library.clearRecents() }
        // Used again after the clear, such as a drag into another app.
        let now = Date.now
        library.update([id]) { $0.lastUsed = now }

        undoManager.undo()

        XCTAssertEqual(library.icons.first?.lastUsed, now,
                       "the use after the clear is newer than the date undo would restore")
    }

    @MainActor
    func testMovingASymlinkedLibraryMovesTheRealFolder() throws {
        let real = folder.appending(path: "Dropbox/Iconery")
        Library(folder: real, preferences: preferences())
            .importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        let link = folder.appending(path: "AppSupport/Iconery")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = Library(folder: link, preferences: preferences())
        let destination = folder.appending(path: "External")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try library.moveLibrary(into: destination)

        let moved = destination.appending(path: "Iconery Library")
        XCTAssertFalse(isSymlink(moved), "the library itself moved, not a link to it")
        XCTAssertFalse(exists(real), "and it left its old place")
        XCTAssertFalse(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: link.path(percentEncoded: false)
            )) != nil,
            "the link that now points nowhere is removed"
        )
        XCTAssertEqual(Library(folder: moved, preferences: preferences()).icons.count, 1)
    }

    @MainActor
    func testRepeatedIDsInTheIndexAreDroppedRatherThanCrashing() throws {
        let libraryFolder = folder.appending(path: "Library")
        let seed = Library(folder: libraryFolder, preferences: preferences())
        let set = seed.createSet(named: "Copied")
        seed.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: set.id)
        seed.searchText = "a"
        seed.saveSearchAsSmartSet()
        // A hand-edit that pastes every entry twice.
        let index = libraryFolder.appending(path: "library.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        )
        for key in ["sets", "icons", "licenses", "smartSets"] {
            let entries = try XCTUnwrap(json[key] as? [Any])
            json[key] = entries + entries
        }
        try JSONSerialization.data(withJSONObject: json).write(to: index)

        let library = Library(folder: libraryFolder, preferences: preferences())

        XCTAssertEqual(library.sets.count, 1)
        XCTAssertEqual(library.icons.count, 1)
        XCTAssertEqual(library.smartSets.count, 1)
        XCTAssertEqual(library.licenses.count, License.starters.count)
        // These build dictionaries keyed by id, which is where a repeat crashed.
        XCTAssertEqual(library.count(in: .smart(try XCTUnwrap(library.smartSets.first).id)), 1)
        XCTAssertEqual(library.count(in: .set(set.id)), 1)
    }

    // MARK: Backups belong to the library that wrote them

    @MainActor
    func testEachLibraryPrunesOnlyItsOwnBackups() async throws {
        let backups = folder.appending(path: "Backups")
        let a = Library(
            folder: folder.appending(path: "A"), preferences: preferences { $0.backupsKept = 2 }
        )
        a.createSet(named: "A")
        let b = Library(
            folder: folder.appending(path: "B"), preferences: preferences { $0.backupsKept = 2 }
        )
        b.createSet(named: "B")
        let first = try await a.backUp(into: backups)
        let second = try await a.backUp(into: backups)
        let theirs = try await b.backUp(into: backups)
        let mine = try await b.backUp(into: backups)
        XCTAssertTrue([first, second, theirs, mine].allSatisfy(exists), "all four fit: two each")

        let newest = try await b.backUp(into: backups)

        XCTAssertFalse(exists(theirs), "B's own oldest made room")
        XCTAssertTrue(exists(first) && exists(second), "A's backups are not B's to prune")
        XCTAssertTrue(exists(mine) && exists(newest))
        XCTAssertEqual(
            Library(folder: folder.appending(path: "B"), preferences: preferences()).lastBackup
                != nil,
            true, "the date is kept with the library"
        )
    }

    @MainActor
    func testLegacyBackupsAreAdoptedByTheFirstLibraryToBackUp() async throws {
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let oldest = backups.appending(path: "Iconery Backup 2026-09-01 at 10.00.00.iconerybackup")
        let older = backups.appending(path: "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup")
        let users = backups.appending(path: "Iconery Backup keep.zip")
        for url in [oldest, older, users] { try Data("x".utf8).write(to: url) }

        let c = Library(
            folder: folder.appending(path: "C"), preferences: preferences { $0.backupsKept = 2 }
        )
        c.createSet(named: "C")
        let own = try await c.backUp(into: backups)
        XCTAssertFalse(exists(oldest), "the older backups were adopted, so the oldest is pruned")
        XCTAssertTrue(exists(older) && exists(own) && exists(users))

        // Once per folder: a second library takes nothing that is already there.
        let d = Library(
            folder: folder.appending(path: "D"), preferences: preferences { $0.backupsKept = 1 }
        )
        d.createSet(named: "D")
        let theirs = try await d.backUp(into: backups)
        XCTAssertTrue(exists(older) && exists(own) && exists(theirs))
    }

    @MainActor
    func testOnlyOwnedBackupsAreCandidatesForPruning() throws {
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let all = [
            "Iconery Backup 2026-09-01 at 10.00.00.iconerybackup",
            "Iconery Backup 2026-09-02 at 10.00.00.iconerybackup",
            "Iconery Backup 2026-09-03 at 10.00.00.iconerybackup",
        ]
        for name in all { try Data().write(to: backups.appending(path: name)) }

        XCTAssertEqual(
            Library.backupsToPrune(in: backups, keeping: 1, owned: [all[1], all[2]])
                .map(\.lastPathComponent),
            [all[1]], "the oldest file isn't named by the library, so it isn't counted"
        )
        XCTAssertEqual(Library.backupsToPrune(in: backups, keeping: 1, owned: []), [])
    }

    @MainActor
    func testAnotherLibraryDoesNotInheritTheLastBackup() async throws {
        let backups = folder.appending(path: "Backups")
        let libraryA = folder.appending(path: "A")
        let libraryB = folder.appending(path: "B")
        Library(folder: libraryB, preferences: preferences()).createSet(named: "B")
        let library = Library(
            folder: libraryA, preferences: preferences { $0.backupSchedule = .daily }
        )
        library.createSet(named: "A")
        try library.changeBackupFolder(to: backups)
        await library.backUpIfDue()
        XCTAssertNotNil(library.lastBackup)
        XCTAssertEqual(names(in: backups).count, 1)

        try library.switchLibrary(to: libraryB)
        XCTAssertNil(library.lastBackup, "B has never been backed up")
        await library.backUpIfDue()
        XCTAssertEqual(names(in: backups).count, 2, "so one is due")

        XCTAssertNotNil(
            Library(folder: libraryA, preferences: preferences()).lastBackup,
            "A still remembers its own"
        )
    }

    @MainActor
    func testTheOldSharedLastBackupMovesIntoTheFirstLibraryOnce() throws {
        let libraryA = folder.appending(path: "A")
        let libraryB = folder.appending(path: "B")
        Library(folder: libraryA, preferences: preferences()).createSet(named: "A")
        Library(folder: libraryB, preferences: preferences()).createSet(named: "B")
        let old = Date.now.addingTimeInterval(-3600)
        Library.defaults.set(old, forKey: Library.lastBackupKey)

        let library = Library(folder: libraryA, preferences: preferences())
        let inherited = try XCTUnwrap(library.lastBackup)
        XCTAssertEqual(inherited.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(Library.defaults.object(forKey: Library.lastBackupKey),
                        "kept until it is in the index")

        library.createSet(named: "Saves")
        XCTAssertNil(Library.defaults.object(forKey: Library.lastBackupKey),
                     "once saved into the index it is gone from UserDefaults")
        try library.switchLibrary(to: libraryB)
        XCTAssertNil(library.lastBackup, "it never leaks into another library")
        XCTAssertNotNil(Library(folder: libraryA, preferences: preferences()).lastBackup)
    }

    // MARK: An unreachable backup folder

    /// A folder that was chosen for backups and then removed, as an unplugged drive would be.
    @MainActor
    private func vanishedBackupFolder(for libraryFolder: URL) throws -> URL {
        let gone = folder.appending(path: "Drive")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try Library(folder: libraryFolder, preferences: preferences()).changeBackupFolder(to: gone)
        try FileManager.default.removeItem(at: gone)
        return gone
    }

    @MainActor
    func testAMissingBackupFolderPausesScheduledBackupsUntilItIsBack() async throws {
        let libraryFolder = folder.appending(path: "Library")
        let gone = try vanishedBackupFolder(for: libraryFolder)

        let library = Library(
            folder: libraryFolder, preferences: preferences { $0.backupSchedule = .daily }
        )
        XCTAssertEqual(library.notice?.title, "Your backup folder couldn't be found")
        library.notice = nil
        await library.backUpIfDue()
        XCTAssertNil(library.lastBackup, "paused, and nothing went to the default folder")
        XCTAssertNil(library.notice)
        do {
            try await library.backUp(into: library.backupFolder)
            XCTFail("Back Up Now wrote somewhere else")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, Library.Problem.backupFolderMissing.errorDescription
            )
        }

        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        await library.backUpIfDue()
        XCTAssertNotNil(library.lastBackup, "back again, so the schedule carries on")
        XCTAssertEqual(names(in: gone).count, 1)
    }

    @MainActor
    func testChoosingANewBackupFolderEndsThePause() async throws {
        let libraryFolder = folder.appending(path: "Library")
        _ = try vanishedBackupFolder(for: libraryFolder)
        let library = Library(
            folder: libraryFolder, preferences: preferences { $0.backupSchedule = .daily }
        )
        library.createSet(named: "Set")
        let chosen = folder.appending(path: "Chosen")

        try library.changeBackupFolder(to: chosen)
        await library.backUpIfDue()

        XCTAssertEqual(names(in: chosen).count, 1)
    }

    // MARK: The backup snapshot

    @MainActor
    func testAFailedSnapshotCopyLeavesNothingBehind() async throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        // A folder of the test's own, which it can list, unlike the system's temporary items.
        let snapshots = folder.appending(path: "Snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        // The copy can't read this, so it fails before ditto is reached.
        let file = library.fileURL(for: try XCTUnwrap(library.icons.first))
        let path = file.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let readable: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        defer { try? FileManager.default.setAttributes(readable, ofItemAtPath: path) }

        do {
            try await library.writeBackup(
                to: folder.appending(path: "x.iconerybackup"), snapshotsIn: snapshots
            )
            XCTFail("the copy can't succeed without the icon")
        } catch {
            XCTAssertFalse(error is Library.Problem, "the copy is what failed: \(error)")
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }

        XCTAssertTrue(exists(snapshots))
        XCTAssertEqual(names(in: snapshots), [], "the half-made snapshot was cleaned up")
    }

    /// Caps the size of any file this process, and so a ditto it starts, can write. The
    /// signal that goes with the cap is ignored, so a write over it fails instead of killing
    /// whoever made it. Returns the call that lifts the cap.
    private func capFileSize(at bytes: UInt64) -> () -> Void {
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        var capped = original
        capped.rlim_cur = rlim_t(bytes)
        setrlimit(RLIMIT_FSIZE, &capped)
        let handler = signal(SIGXFSZ, SIG_IGN)
        return {
            var restored = original
            setrlimit(RLIMIT_FSIZE, &restored)
            signal(SIGXFSZ, handler)
        }
    }

    // MARK: Fixes 2026-10-09: import, sets and Quick Look

    @MainActor
    func testImportedSymlinksBecomeRealFiles() throws {
        let pack = folder.appending(path: "Papirus")
        let actions = pack.appending(path: "actions")
        let apps = pack.appending(path: "apps")
        try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let real = actions.appending(path: "edit-copy.svg")
        try FileManager.default.moveItem(
            at: try writeSVG("edit-copy", #"<path d="M1 1h4"/>"#), to: real
        )
        // Icon themes alias names with relative links.
        try FileManager.default.createSymbolicLink(
            atPath: apps.appending(path: "copy.svg").path(percentEncoded: false),
            withDestinationPath: "../actions/edit-copy.svg"
        )
        let library = Library(
            folder: folder.appending(path: "Library"),
            preferences: preferences { $0.skipsDuplicates = false }
        )
        let report = library.importItems([pack], into: nil)
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(Set(library.icons.map(\.name)), ["copy", "edit-copy"])
        for icon in library.icons {
            XCTAssertFalse(isSymlink(library.fileURL(for: icon)), "\(icon.name) is a real file")
            XCTAssertNotNil(library.image(for: icon), "\(icon.name) draws")
        }
    }

    @MainActor
    func testASymlinkTakesItsKindFromWhatItPointsAt() throws {
        let links = folder.appending(path: "Links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let real = try writeSVG("real", #"<path d="M1 1h4"/>"#)
        let link = links.appending(path: "alias.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())

        let report = library.importItems([link], into: nil)

        XCTAssertEqual(report.imported, 1)
        let icon = try XCTUnwrap(library.icons.first)
        XCTAssertEqual(icon.name, "alias", "the name is the link's")
        XCTAssertEqual(icon.kind, .svg, "the kind is the file's")
        XCTAssertEqual(icon.fileName.hasSuffix(".svg"), true)
    }

    @MainActor
    func testAnAbsoluteSymlinkSurvivesItsSourceBeingDeleted() throws {
        let real = try writeSVG("real", #"<path d="M1 1h4"/>"#)
        let link = folder.appending(path: "link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([link], into: nil)
        try FileManager.default.removeItem(at: real)
        let icon = try XCTUnwrap(library.icons.first)
        XCTAssertEqual(icon.name, "link")
        XCTAssertNotNil(library.image(for: icon))
    }

    @MainActor
    func testADanglingSymlinkIsReportedAsUnreadable() throws {
        let link = folder.appending(path: "gone.svg")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: "nowhere.svg"
        )
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let report = library.importItems([link], into: nil)
        XCTAssertEqual(report.skipped, ["gone.svg"])
        XCTAssertTrue(library.icons.isEmpty)
    }

    @MainActor
    func testASymlinkToAnImportedFileIsADuplicateByContent() throws {
        let real = try writeSVG("real", #"<path d="M1 1h4"/>"#)
        let link = folder.appending(path: "alias.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([real], into: nil)
        let report = library.importItems([link], into: nil)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(library.icons.count, 1)
    }

    @MainActor
    func testCheckLibraryCountsADanglingSymlinkAsMissing() async throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([try writeSVG("home", #"<path d="M1 1h4"/>"#)], into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        let file = library.fileURL(for: icon)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            atPath: file.path(percentEncoded: false), withDestinationPath: "nowhere.svg"
        )
        await library.checkLibrary()
        XCTAssertEqual(library.check?.missing.map(\.id), [icon.id])
    }

    @MainActor
    func testIconJarIconsKeepTheirOriginalFileName() throws {
        let jar = folder.appending(path: "Mine.ijlibrary")
        let sets = jar.appending(path: "Sets/F-ONE")
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: try writeSVG("arrow-left", #"<path d="M1 1h4"/>"#),
            to: sets.appending(path: "arrow-left.svg")
        )
        try sqlite(jar.appending(path: "Jars.db"), """
        CREATE TABLE ZIJGROUP (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZNAME TEXT, ZGROUP INTEGER);
        CREATE TABLE ZIJCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZIDENTIFIER TEXT,
            ZNAME TEXT, ZGROUP INTEGER, ZTYPE INTEGER);
        CREATE TABLE ZIJITEM (ZUUID TEXT, ZNAME TEXT, ZNEWFILENAME TEXT, ZTAGSSTRING TEXT,
            ZSTARRED INTEGER, ZDATE REAL, ZLASTUSEDDATE REAL, ZCOLLECTION INTEGER, ZTYPE INTEGER);
        INSERT INTO ZIJCOLLECTION VALUES (1, '0E2B5D7A-1C3F-4E6B-8A9D-2F4C6E8A0B13', 'F-ONE',
            'Arrows', NULL, 0);
        INSERT INTO ZIJITEM VALUES ('D122537C-71C1-4718-AE53-8B8D397DB80B', 'Arrow Left',
            'arrow-left.svg', NULL, 0, NULL, NULL, 1, 0);
        """)
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        try library.importIconJar(jar, into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        XCTAssertEqual(icon.name, "Arrow Left")
        var options = ExportOptions()
        options.format = .svg
        options.naming = .originalFileName
        XCTAssertEqual(Exporter.fileNames(for: icon, options: options), ["arrow-left.svg"])
    }

    @MainActor
    func testAUTF16SVGCopiesItsCodeAndNamesItsIcon() throws {
        let svg = #"<?xml version="1.0" encoding="UTF-16"?>"#
            + #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">"#
            + #"<title>Wide House</title><path d="M3 10l9-7 9 7"/></svg>"#
        let url = folder.appending(path: "wide.svg")
        try XCTUnwrap(svg.data(using: .utf16)).write(to: url)  // with a byte order mark
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([url], into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        XCTAssertEqual(icon.name, "Wide House")
        let restore = savedGeneralPasteboard()
        defer { restore() }
        NSPasteboard.general.clearContents()
        library.copySVGCode(icon)
        XCTAssertNil(library.notice?.message)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), svg)
    }

    /// Copy always writes to the general pasteboard, so a test that clears it first puts back
    /// what the person running the tests had on it.
    @MainActor
    private func savedGeneralPasteboard() -> () -> Void {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        return {
            board.clearContents()
            board.writeObjects(saved)
        }
    }

    @MainActor
    func testAUTF16SVGWithoutAByteOrderMarkIsReadAsUTF16() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">"#
            + #"<title>Plain Wide</title><path d="M3 10l9-7 9 7"/></svg>"#
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([try writeSVG("plain", #"<path d="M1 1h4"/>"#)], into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        // Swapped in afterwards, as AppKit won't draw it to import. Valid UTF-8 as well, with a
        // NUL after every character, which used to be taken as such.
        try XCTUnwrap(svg.data(using: .utf16LittleEndian)).write(to: library.fileURL(for: icon))
        let restore = savedGeneralPasteboard()
        defer { restore() }
        library.copySVGCode(icon)
        XCTAssertNil(library.notice?.message)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), svg)
    }

    @MainActor
    func testAFailedExportDoesNotStampRecentlyUsed() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.export = ExportOptions()
        library.importItems([
            try writeSVG("home", #"<path d="M1 1h4"/>"#),
            try writeSVG("gone", #"<path d="M2 1h4"/>"#),
        ], into: nil)
        let gone = try XCTUnwrap(library.icons.first { $0.name == "gone" })
        try FileManager.default.removeItem(at: library.fileURL(for: gone))
        let result = library.export(library.icons, to: folder.appending(path: "Out"))
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertNil(library.icons.first { $0.name == "gone" }?.lastUsed)
        XCTAssertNotNil(library.icons.first { $0.name == "home" }?.lastUsed)
    }

    @MainActor
    func testARefusedSetDropIsNotAccepted() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        let parent = library.createSet(named: "Parent")
        let child = library.createSet(named: "Child", inside: parent.id)
        XCTAssertFalse(library.handleDrop([Library.setDragURL(parent.id)], onto: child.id))
        XCTAssertNil(library.sets.first { $0.id == parent.id }?.parentID)
        XCTAssertFalse(library.handleDrop([Library.setDragURL(child.id)], onto: nil))
        XCTAssertFalse(library.moveSet(parent.id, into: child.id))
        XCTAssertTrue(library.moveSet(child.id, into: nil))
    }

    @MainActor
    func testLooseFilesReuseAnUnsortedSetWhateverItsCase() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.createSet(named: "unsorted")
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        library.importItems([try writeSVG("b", #"<path d="M2 1h4"/>"#)], into: nil)
        XCTAssertEqual(library.sets.map(\.name), ["unsorted"])
        XCTAssertEqual(library.icons.count, 2)
    }

    @MainActor
    func testALibraryFileDroppedBackInIsADuplicate() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.importItems([try writeSVG("a", #"<path d="M1 1h4"/>"#)], into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        let report = library.importItems([library.fileURL(for: icon)], into: nil)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(library.icons.count, 1)
    }

    @MainActor
    func testSiblingSetsKeepDistinctNamesWhenRenamedOrMoved() throws {
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences())
        library.createSet(named: "Arrows")
        let other = library.createSet(named: "Other")
        library.renameSet(other.id, to: "arrows")
        XCTAssertEqual(library.sets.first { $0.id == other.id }?.name, "arrows 2")
        // Renaming a set to its own name, or just its case, doesn't count as a clash.
        library.renameSet(other.id, to: "ARROWS 2")
        XCTAssertEqual(library.sets.first { $0.id == other.id }?.name, "ARROWS 2")

        let parent = library.createSet(named: "Parent")
        library.createSet(named: "Outline", inside: parent.id)
        let loose = library.createSet(named: "outline")
        library.moveSet(loose.id, into: parent.id)
        XCTAssertEqual(library.sets.first { $0.id == loose.id }?.name, "outline 2")
        XCTAssertEqual(library.sets.first { $0.id == loose.id }?.parentID, parent.id)
    }

    @MainActor
    func testQuickLookKeepsOneFolderWithFriendlyNamesInGridOrder() throws {
        let library = Library(
            folder: folder.appending(path: "Library"),
            preferences: preferences { $0.skipsDuplicates = false }
        )
        let set = library.createSet(named: "Set")
        let same = try writeSVG("same", #"<path d="M1 1h4"/>"#)
        library.importItems([same, same], into: set.id)
        library.importItems([try writeSVG("other", #"<path d="M2 1h4"/>"#)], into: set.id)
        library.update(Set(library.icons.filter { $0.name == "same" }.map(\.id))) {
            $0.name = "Home/Page"
        }
        library.selectAll()
        let first = library.quickLookURLs(for: library.selection)
        let inGrid = library.visibleIcons.map { Exporter.safeFileName($0.name) }
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(
            first.map { $0.deletingPathExtension().lastPathComponent }
                .map { $0.replacingOccurrences(of: " 2", with: "") },
            inGrid
        )
        XCTAssertEqual(Set(first.map(\.lastPathComponent)).count, 3, "names are unique")
        XCTAssertTrue(first.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        XCTAssertTrue(first.contains { $0.lastPathComponent == "Home-Page 2.svg" })

        let second = library.quickLookURLs(for: library.selection)
        XCTAssertEqual(second.map(\.lastPathComponent), first.map(\.lastPathComponent))
        XCTAssertTrue(second.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first[0].deletingLastPathComponent().path()),
            "the previous press's folder is gone"
        )
    }

    // MARK: Fixes 2026-10-09: export, search and views

    @MainActor
    func testDockDropIgnoresTheGridsOwnDrag() throws {
        let library = Library(
            folder: folder.appending(path: "Library"), preferences: preferences()
        )
        library.importItems([try writeSVG("home", #"<path d="M1 1h4"/>"#)], into: nil)
        library.export.format = .png
        library.export.pngSizes = [32]
        library.export.presetID = nil
        let icon = try XCTUnwrap(library.icons.first)
        _ = library.dragProvider(for: icon)
        defer { try? FileManager.default.removeItem(at: Exporter.dragRoot) }
        let staged = try XCTUnwrap(
            FileManager.default.enumerator(at: Exporter.dragRoot, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.pathExtension == "png" }
        )
        let delegate = AppDelegate()
        delegate.library = library
        delegate.application(NSApplication.shared, open: [staged])
        XCTAssertEqual(library.icons.count, 1, "the grid's own drag was imported back as a copy")

        // A file from outside is still taken, alongside a grid drag in the same drop.
        let outside = try writeSVG("outside", #"<circle cx="12" cy="12" r="5"/>"#)
        delegate.application(NSApplication.shared, open: [staged, outside])
        XCTAssertEqual(library.icons.map(\.name).sorted(), ["home", "outside"])
    }

    @MainActor
    func testSidebarSetsTravelUnderTheSchemeTheGridRefuses() {
        XCTAssertEqual(Library.setDragURL(UUID()).scheme, "iconery-set")
    }

    @MainActor
    func testPresetKeepsThePrefixAndSuffixTheFormShows() throws {
        let library = Library(
            folder: folder.appending(path: "Library"), preferences: preferences()
        )
        library.importItems([try writeSVG("home", #"<path d="M1 1h4"/>"#)], into: nil)
        let icon = try XCTUnwrap(library.icons.first)
        library.export.prefix = "brand-"
        library.export.suffix = "-v2"
        library.export.presetID = "__IJBuiltInAndroidPresetNoticationIcons"
        let preset = try XCTUnwrap(library.activePreset)

        let previewed = Exporter.fileNames(for: icon, options: library.export, preset: preset)
        let written = try library.exportFiles(for: icon).map(\.name)
        XCTAssertEqual(previewed, written, "the preview is the export's own naming")
        XCTAssertEqual(written.count, 5)
        XCTAssertEqual(written.first, "brand-home-v2-mdpi.png")
        XCTAssertEqual(written.last, "brand-home-v2-xxxhdpi.png")

        // The preset's own prefix sits after the user's and its @2x ends the name.
        library.export.presetID = "__IJBuiltInMacOSPresetAppIcon"
        let app = try library.exportFiles(for: icon).map(\.name)
        XCTAssertTrue(app.contains("brand-16x16-home-v2@2x.png"), "\(app)")
    }

    func testTagNamingKeepsEveryDensitySuffix() throws {
        var icon = Icon(name: "home", setID: UUID(), kind: .svg)
        icon.tags = (1...40).map { "keyword\($0)" }
        var options = ExportOptions()
        options.naming = .tags
        let android = try XCTUnwrap(ExportPreset.builtIn.first { $0.name == "Notification Icons" })
        let names = options.outputs(of: android).flatMap {
            Exporter.fileNames(for: icon, options: $0)
        }
        XCTAssertEqual(Set(names).count, 5, "densities collapsed into one file name")
        XCTAssertTrue(names.allSatisfy { $0.utf8.count <= 200 + ".png".utf8.count })
        XCTAssertTrue(names[4].hasSuffix("-xxxhdpi.png"))
    }

    func testOnlyTheStemIsCutAndNeverThroughACharacter() {
        let stem = String(repeating: "é👩‍👩‍👧", count: 60)
        let name = Exporter.safeFileName(stem, prefix: "pre-", suffix: "@2x")
        XCTAssertTrue(name.hasPrefix("pre-é"))
        XCTAssertTrue(name.hasSuffix("@2x"))
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertNotNil(String(data: Data(name.utf8), encoding: .utf8))
        let body = name.dropFirst(4).dropLast(3)
        XCTAssertTrue(body.allSatisfy { "é👩‍👩‍👧".contains($0) }, "a character was split")
        XCTAssertEqual(Exporter.safeFileName("a/b", prefix: "", suffix: ""), "a-b")
        XCTAssertEqual(Exporter.safeFileName("", prefix: "", suffix: ""), "icon")
    }

    func testTitlesDecodeNumericReferencesAndCDATA() {
        func title(_ text: String) -> String? {
            SVGCleaner.titleAndDescription(of: "<svg><title>\(text)</title></svg>").title
        }
        XCTAssertEqual(title("Caf&#233; &#x2192; Bar"), "Café → Bar")
        XCTAssertEqual(title("A &amp; B &lt;c&gt; &quot;d&quot; &apos;e&apos;"), "A & B <c> \"d\" 'e'")
        XCTAssertEqual(title("&amp;#233;"), "&#233;", "a decoded ampersand is not decoded again")
        XCTAssertEqual(title("<![CDATA[R&D <raw> &#233;]]>"), "R&D <raw> &#233;")
        XCTAssertEqual(title("x &#xD800; &#99999999999; &#x110000; &bogus; y"),
                       "x &#xD800; &#99999999999; &#x110000; &bogus; y")
    }

    func testTitlesKeepControlCharacterReferencesAsWritten() {
        func title(_ text: String) -> String? {
            SVGCleaner.titleAndDescription(of: "<svg><title>\(text)</title></svg>").title
        }
        XCTAssertEqual(title("a&#0;b &#1;c &#x1F;d &#127;e &#x7f;f"),
                       "a&#0;b &#1;c &#x1F;d &#127;e &#x7f;f")
        XCTAssertEqual(title("x&#9;y&#10;z&#13;w&#32;v"), "x\ty\nz\rw v",
                       "tab, line feed and carriage return are text")
    }

    @MainActor
    func testSVGImageSetNeedsNoSizesButAnImageDoes() throws {
        var options = ExportOptions()
        options.format = .imageset
        options.pngSizes = []
        XCTAssertTrue(options.isExportable)
        let source = try writeSVG("home", #"<path d="M1 1h4"/>"#)
        let svg = Icon(name: "home", setID: UUID(), kind: .svg)
        let files = try Exporter.files(
            for: svg, source: source, image: NSImage(contentsOf: source), options: options
        )
        XCTAssertEqual(files.count, 2)
        let png = Icon(name: "pic", setID: UUID(), kind: .png)
        let image = try writePNG("pic")
        XCTAssertThrowsError(
            try Exporter.files(
                for: png, source: image, image: NSImage(contentsOf: image), options: options
            )
        )
        options.format = .png
        XCTAssertFalse(options.isExportable, "a plain PNG export still needs a size")
    }

    @MainActor
    func testOnePresetThisBuildCantReadCostsOnlyItself() throws {
        let json = """
        [{"id":"mine","name":"Mine","outputs":[{"format":"png","sizes":[64],"prefix":"",
          "suffix":"","includeSize":false}]},
         {"id":"later","name":"Later","outputs":[{"format":"webp","sizes":[64],"prefix":"",
          "suffix":"","includeSize":false}]}]
        """
        Library.defaults.set(Data(json.utf8), forKey: "exportPresets")
        let library = Library(
            folder: folder.appending(path: "Library"), preferences: preferences()
        )
        XCTAssertEqual(library.presets.map(\.id), ["mine"])

        library.savePreset(named: "New")
        let stored = try XCTUnwrap(Library.defaults.data(forKey: "exportPresets"))
        let items = try XCTUnwrap(try JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["Mine", "New", "Later"])
        let later = try XCTUnwrap(items.last)
        let outputs = try XCTUnwrap(later["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.first?["format"] as? String, "webp", "kept as it was stored")

        library.deletePreset("mine")
        XCTAssertEqual(ExportPreset.loadSaved().map(\.name), ["New"])
        let after = try XCTUnwrap(Library.defaults.data(forKey: "exportPresets"))
        let names = try XCTUnwrap(try JSONSerialization.jsonObject(with: after) as? [[String: Any]])
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["New", "Later"])
    }

    func testABareFieldPrefixMatchesEveryIcon() {
        var icon = Icon(name: "arrow", setID: UUID(), kind: .svg)
        icon.tags = ["left"]
        let untagged = Icon(name: "plain", setID: UUID(), kind: .png)
        let scope = SearchScope()
        for query in ["tag:", "set:", "kind:", "type:", "TAG:"] {
            for candidate in [icon, untagged] {
                XCTAssertTrue(
                    iconMatches(candidate, query: query, setPath: "Arrows", scope: scope), query
                )
            }
        }
        XCTAssertFalse(iconMatches(untagged, query: "tag:left", setPath: "", scope: scope))
        XCTAssertFalse(iconMatches(untagged, query: "kind:svg", setPath: "", scope: scope))
        XCTAssertTrue(iconMatches(icon, query: "kind:svg tag:", setPath: "", scope: scope))
    }

    func testBatchRenameReplaceIgnoresCase() {
        var rename = BatchRename()
        rename.mode = .replace
        rename.find = "ICON"
        rename.replacement = "glyph"
        XCTAssertEqual(rename.newName(for: "my icon", index: 0), "my glyph")
        XCTAssertNil(rename.newName(for: "my image", index: 0))
    }

    func testDockIconAcceptsFoldersAndIconJarLibraries() throws {
        let plist = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Info.plist")
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: try Data(contentsOf: plist), format: nil
            ) as? [String: Any]
        )
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let viewable = types.filter { $0["CFBundleTypeRole"] as? String == "Viewer" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(viewable.contains("public.folder"))
        XCTAssertTrue(viewable.contains("com.iconjar-library"))
    }

    @MainActor
    func testTagFieldCommitsOnlyWhatTheUserChanged() throws {
        _ = NSApplication.shared
        func edit(
            _ change: (TagField.Coordinator, NSTokenField) -> Void
        ) throws -> [[String]] {
            var committed: [[String]] = []
            let coordinator = TagField.Coordinator { committed.append($0) }
            let window = NSWindow(
                contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            window.contentView?.addSubview(field)
            coordinator.refresh(field, to: ["draft", "keep"])
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            XCTAssertTrue(window.makeFirstResponder(field))
            XCTAssertNotNil(field.currentEditor())
            change(coordinator, field)
            coordinator.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field)
            )
            return committed
        }
        // Remove Tag elsewhere while the field is being edited: draft must not come back.
        XCTAssertEqual(try edit { coordinator, field in
            coordinator.refresh(field, to: ["keep"])
        }, [["keep"]])
        // What the user did in the field is kept beside the outside change.
        XCTAssertEqual(try edit { coordinator, field in
            field.objectValue = ["draft", "keep", "mine"]
            coordinator.refresh(field, to: ["keep"])
        }, [["keep", "mine"]])
        // A tag removed elsewhere that the user then types again is theirs, so it stays; the
        // one the field already held is still taken out.
        XCTAssertEqual(try edit { coordinator, field in
            field.objectValue = ["draft", "keep", "draft"]
            coordinator.refresh(field, to: ["keep"])
        }, [["keep", "draft"]])
        // Without an outside change the field's tokens commit as they stand.
        XCTAssertEqual(try edit { _, field in
            field.objectValue = ["draft", "keep", "typed"]
        }, [["draft", "keep", "typed"]])
    }

    // MARK: Fixes 2026-10-09: remaining backup issues

    @MainActor
    func testEachFolderAdoptsItsOwnLegacyBackups() async throws {
        func legacy(in backups: URL) throws -> (oldest: URL, older: URL) {
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let oldest = backups.appending(path: "Iconery Backup 2026-09-01 at 10.00.00.zip")
            let older = backups.appending(path: "Iconery Backup 2026-09-02 at 10.00.00.zip")
            for url in [oldest, older] { try Data("x".utf8).write(to: url) }
            return (oldest, older)
        }
        let one = folder.appending(path: "One")
        let two = folder.appending(path: "Two")
        let first = try legacy(in: one)
        let second = try legacy(in: two)
        let a = Library(
            folder: folder.appending(path: "A"), preferences: preferences { $0.backupsKept = 2 }
        )
        a.createSet(named: "A")
        let b = Library(
            folder: folder.appending(path: "B"), preferences: preferences { $0.backupsKept = 2 }
        )
        b.createSet(named: "B")

        _ = try await a.backUp(into: one)
        _ = try await b.backUp(into: two)

        XCTAssertFalse(exists(first.oldest), "A adopted the old backups in its folder")
        XCTAssertTrue(exists(first.older))
        XCTAssertFalse(exists(second.oldest), "B adopted the ones in its own folder as well")
        XCTAssertTrue(exists(second.older))
    }

    @MainActor
    func testALibraryBackingUpIntoAnAdoptedFolderAdoptsNothing() async throws {
        let backups = folder.appending(path: "Backups")
        let a = Library(
            folder: folder.appending(path: "A"), preferences: preferences { $0.backupsKept = 1 }
        )
        a.createSet(named: "A")
        let b = Library(
            folder: folder.appending(path: "B"), preferences: preferences { $0.backupsKept = 1 }
        )
        b.createSet(named: "B")
        let theirs = try await a.backUp(into: backups)
        XCTAssertTrue(exists(backups.appending(path: Library.adoptionMarkerName)))

        let mine = try await b.backUp(into: backups)

        XCTAssertTrue(exists(theirs) && exists(mine), "A's backup isn't B's to prune")
        XCTAssertEqual(names(in: backups).filter { $0.hasPrefix("Iconery Backup") }.count, 2)
    }

    @MainActor
    func testARenamedBackupFolderIsFollowedMidSession() async throws {
        let libraryFolder = folder.appending(path: "Library")
        let chosen = folder.appending(path: "Chosen")
        let renamed = folder.appending(path: "Renamed")
        let library = Library(
            folder: libraryFolder, preferences: preferences { $0.backupSchedule = .daily }
        )
        library.createSet(named: "Set")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try library.changeBackupFolder(to: chosen)
        try FileManager.default.moveItem(at: chosen, to: renamed)

        await library.backUpIfDue()

        XCTAssertEqual(names(in: renamed).count, 1, "the backup went to the renamed folder")
        XCTAssertFalse(exists(chosen), "the old path wasn't made again")
        XCTAssertEqual(
            library.backupFolder.resolvingSymlinksInPath(), renamed.resolvingSymlinksInPath()
        )
    }

    @MainActor
    func testABackupFolderMovedToTheTrashMidSessionPausesBackups() async throws {
        let libraryFolder = folder.appending(path: "Library")
        let chosen = folder.appending(path: "Chosen")
        let library = Library(
            folder: libraryFolder, preferences: preferences { $0.backupSchedule = .daily }
        )
        library.createSet(named: "Set")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try library.changeBackupFolder(to: chosen)
        _ = try moveToTrash(chosen)

        await library.backUpIfDue()

        XCTAssertNil(library.lastBackup, "nothing was written")
        XCTAssertFalse(exists(chosen), "the folder wasn't made again")
        XCTAssertEqual(library.notice?.title, "Your backup folder couldn't be found")
    }

    @MainActor
    func testAStandInLibraryDoesNotTakeTheOldSharedLastBackup() throws {
        let gone = folder.appending(path: "Gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        Library.defaults.set(try gone.bookmarkData(), forKey: Library.libraryKey)
        try FileManager.default.removeItem(at: gone)
        let standIn = folder.appending(path: "StandIn")
        Library(folder: standIn, preferences: preferences()).createSet(named: "Default")
        let old = Date.now.addingTimeInterval(-3600)
        Library.defaults.set(old, forKey: Library.lastBackupKey)

        let library = Library(defaultFolder: standIn, preferences: preferences())

        XCTAssertEqual(library.notice?.title, "Your library couldn't be found")
        XCTAssertEqual(library.folder.resolvingSymlinksInPath(), standIn.resolvingSymlinksInPath())
        XCTAssertNil(library.lastBackup, "the stand-in isn't the library those backups were of")
        XCTAssertNotNil(
            Library.defaults.object(forKey: Library.lastBackupKey),
            "left for the real library to take"
        )
    }

    // MARK: Fixes 2026-10-09: parallel transfer export

    /// Every file under `root` as relative path to bytes, so names and contents compare at once.
    /// `skipping` drops that many leading folders from each path.
    private func tree(_ root: URL, skipping: Int = 0) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        let depth = root.pathComponents.count
        var found: [String: Data] = [:]
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = walker?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(depth + skipping)
            found[relative.joined(separator: "/")] = try Data(contentsOf: url)
        }
        return found
    }

    // The drag draws on every core, but the folder it stages must be the one a single thread
    // would have written: same names, same " 2" suffixes on clashes, same bytes.
    @MainActor
    func testParallelTransferWritesWhatASerialExportWould() throws {
        let library = Library(
            folder: folder.appending(path: "Library"),
            preferences: Preferences(defaults: nil)
        )
        library.preferences.skipsDuplicates = false
        var urls: [URL] = []
        for i in 0..<300 {
            let body = #"<circle cx="12" cy="12" r="\#(i % 11 + 1)"/><path d="M\#(i % 7) 3l9 7"/>"#
            let svg = try writeSVG("icon\(i)", body)
            guard i % 3 == 0 else {
                urls.append(svg)
                continue
            }
            let drawn = try XCTUnwrap(NSImage(contentsOf: svg).flatMap {
                Raster.render($0, pixels: 40 + i % 5)
            })
            let png = folder.appending(path: "icon\(i).png")
            try XCTUnwrap(Raster.encode(drawn, as: .png)).write(to: png)
            urls.append(png)
        }
        library.importItems(urls, into: nil)
        XCTAssertEqual(library.icons.count, 300)
        for icon in library.icons.prefix(40) { library.rename(icon.id, to: "same") }
        for icon in library.icons.suffix(10) { library.rename(icon.id, to: "same") }
        library.selectAll()
        let icon = try XCTUnwrap(library.visibleIcons.first)

        func serial() throws -> [String: Data] {
            let root = folder.appending(path: "Serial-\(UUID().uuidString)")
            for item in library.icons {
                let files = try library.exportFiles(for: item)
                try Exporter.write(files, to: root)
            }
            return try tree(root)
        }
        func dragged() throws -> [String: Data] {
            try? FileManager.default.removeItem(at: Exporter.dragRoot)
            _ = library.dragProvider(for: icon)
            // dragRoot/<uuid>/Icons/<file>: the folder's name is new every time.
            return try tree(Exporter.dragRoot, skipping: 2)
        }
        defer { try? FileManager.default.removeItem(at: Exporter.dragRoot) }

        library.export.presetID = nil
        library.export.format = .png
        library.export.pngSizes = [16, 48, 64]
        let flat = try serial()
        var staged = try dragged()
        XCTAssertEqual(staged.keys.sorted(), flat.keys.sorted())
        XCTAssertTrue(staged.keys.contains { $0.hasSuffix("same-16 2.png") }, "a clash was renamed")
        XCTAssertEqual(staged.count, 300 * 3)
        for (name, data) in flat { XCTAssertEqual(staged[name], data, name) }

        // Image sets are folders, whose clashes rename the folder as a whole.
        library.export.format = .imageset
        let sets = try serial()
        staged = try dragged()
        XCTAssertEqual(staged.keys.sorted(), sets.keys.sorted())
        XCTAssertTrue(staged.keys.contains { $0.contains("same 2.imageset/") })
        for (name, data) in sets { XCTAssertEqual(staged[name], data, name) }
    }
}

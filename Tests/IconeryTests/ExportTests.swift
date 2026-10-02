import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import Iconery

final class ExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "IconeryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        // Moving, switching and backing up remember locations; these are the test runner's
        // defaults, not the app's, but leave them as found.
        let exportKeys = ["exportOptions", "exportPresets"]
        for key in [Library.libraryKey, Library.backupKey, Library.lastBackupKey] + exportKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        let library = Library(folder: folder.appending(path: "Library"))
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
        let library = Library(folder: original)
        library.importItems([source], into: library.createSet(named: "Set").id)
        let elsewhere = folder.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        try library.moveLibrary(into: elsewhere)

        XCTAssertEqual(library.folder.lastPathComponent, "Iconery Library")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)),
                        "icons are read from the new place")
        XCTAssertEqual(Library(folder: library.folder).icons.count, 1)
        XCTAssertThrowsError(try library.moveLibrary(into: library.iconsFolder),
                             "a library can't move into itself")
    }

    @MainActor
    func testSwitchingOpensAnotherLibraryButNotAPlainFolder() throws {
        let (_, source) = try makeSVGIcon()
        let other = Library(folder: folder.appending(path: "Other"))
        other.importItems([source], into: other.createSet(named: "Theirs").id)
        let library = Library(folder: folder.appending(path: "Mine"))
        library.createSet(named: "Mine")

        try library.switchLibrary(to: other.folder)
        XCTAssertEqual(library.setPaths.map(\.path), ["Theirs"])
        XCTAssertEqual(library.icons.count, 1)
        XCTAssertNotNil(library.image(for: try XCTUnwrap(library.icons.first)))

        XCTAssertThrowsError(try library.switchLibrary(to: folder))
        XCTAssertEqual(library.setPaths.map(\.path), ["Theirs"], "a refused switch changes nothing")
        XCTAssertEqual(Library(folder: folder.appending(path: "Mine")).setPaths.map(\.path),
                       ["Mine"], "the library switched away from was saved")
    }

    @MainActor
    func testBackUpWritesDatedZipsOutsideTheLibrary() async throws {
        let library = Library(folder: folder.appending(path: "Library"))
        library.createSet(named: "Set")
        let backups = folder.appending(path: "Backups")

        let first = try await library.backUp(into: backups)
        let second = try await library.backUp(into: backups)

        XCTAssertTrue(first.lastPathComponent.hasPrefix("Iconery Backup "))
        XCTAssertEqual(first.pathExtension, "zip")
        XCTAssertNotEqual(first, second, "two backups in the same second don't overwrite")
        XCTAssertNotNil(library.lastBackup)
        let inside = library.folder.appending(path: "Backups")
        do {
            try await library.backUp(into: inside)
            XCTFail("a backup was written inside the library it backs up")
        } catch {}
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

        let library = Library(folder: folder.appending(path: "Library"))
        let report = library.importItems([incoming], into: nil)

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.skipped, [], "files that aren't icons are ignored inside a folder")
        XCTAssertEqual(library.sets.map(\.name), ["Arrows"])
        XCTAssertEqual(library.icons.map(\.name), ["up"])

        let reopened = Library(folder: folder.appending(path: "Library"))
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

        let library = Library(folder: folder.appending(path: "Library"))
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
        let library = Library(folder: folder.appending(path: "Library"))
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
        let library = Library(folder: folder.appending(path: "Library"))
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

        let library = Library(folder: libraryFolder)
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
            default:
                XCTAssertTrue(bytes.starts(with: try XCTUnwrap(magic[format])), "\(format)")
            }
            XCTAssertEqual(files[0].name, Exporter.fileNames(for: icon, options: options)[0])
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
        let library = Library(folder: folder)
        XCTAssertEqual(library.licenses.first?.name, "MIT")
        XCTAssertEqual(library.licenses.count, 9)
        library.importItems([source], into: library.createSet(named: "Set").id)
        let icon = try XCTUnwrap(library.icons.first)
        let mit = try XCTUnwrap(library.licenses.first)
        library.setLicense([icon.id], mit.id)
        library.setInfo(icon.id, "  A house.  ")
        library.setTags(icon.id, ["home", " building ", ""])

        let reopened = Library(folder: folder)
        let saved = try XCTUnwrap(reopened.icons.first)
        XCTAssertEqual(reopened.license(of: saved)?.name, "MIT")
        XCTAssertEqual(saved.info, "A house.")
        XCTAssertEqual(saved.tags, ["home", "building"])

        reopened.removeLicense(mit.id)
        XCTAssertNil(reopened.icons.first?.licenseID)
        XCTAssertEqual(Library(folder: folder).licenses.count, 8)
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
        let library = Library(folder: folder.appending(path: "Library"))
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
            "Iconery Backup 2026-09-02 at 10.00.00.zip",
            "Iconery Backup 2026-09-01 at 10.00.00.zip",
            "Iconery Backup 2026-09-03 at 10.00.00.zip",
            "Notes.zip", "Iconery Backup.txt",
        ] {
            try Data().write(to: backups.appending(path: name))
        }
        XCTAssertEqual(
            Library.backupsToPrune(in: backups, keeping: 2).map(\.lastPathComponent),
            ["Iconery Backup 2026-09-01 at 10.00.00.zip"],
            "only the oldest of this app's backups; other files are never touched"
        )
        XCTAssertEqual(Library.backupsToPrune(in: backups, keeping: 0), [], "0 keeps everything")
    }

    @MainActor
    func testScheduledBackupRunsOnlyWhenDue() async throws {
        let preferences = preferences { $0.backupSchedule = .daily }
        let library = Library(folder: folder.appending(path: "Library"), preferences: preferences)
        library.createSet(named: "Set")
        let backups = folder.appending(path: "Backups")
        try library.changeBackupFolder(to: backups)
        func count() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false))
                .count
        }

        await library.backUpIfDue()
        XCTAssertNil(library.notice)
        XCTAssertEqual(try count(), 1, "never backed up, so one is due")
        await library.backUpIfDue()
        XCTAssertEqual(try count(), 1, "the next isn't due for a day")
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
        let library = Library(folder: folder.appending(path: "Library"))
        let outer = library.createSet(named: "Outer")
        let inner = library.createSet(named: "Inner", inside: outer.id)
        library.importItems([source], into: inner.id)
        library.toggleStar(Set(library.icons.map(\.id)))

        let backup = folder.appending(path: "Backup.zip")
        try await library.writeBackup(to: backup)

        let unpacked = folder.appending(path: "Unpacked")
        let unzip = try Process.run(
            URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", backup.path(percentEncoded: false),
                        unpacked.path(percentEncoded: false)]
        )
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)

        let restored = Library(folder: unpacked.appending(path: "Library"))
        // Against a fresh load, not `library`: the index stores dates to the second, so the
        // in-memory `added` carries fractions that never reach disk.
        let saved = Library(folder: folder.appending(path: "Library"))
        XCTAssertEqual(restored.setPaths.map(\.path), ["Outer", "Outer › Inner"])
        XCTAssertEqual(restored.icons, saved.icons, "names, sets, tags and stars all survive")
        XCTAssertEqual(restored.icons.map(\.starred), [true])
        XCTAssertNotNil(restored.image(for: try XCTUnwrap(restored.icons.first)),
                        "and the icon file itself came along")
    }

    @MainActor
    func testAFailedBackupLeavesNoPartOfAZip() async throws {
        let (_, source) = try makeSVGIcon()
        let library = Library(folder: folder.appending(path: "Library"))
        library.importItems([source], into: nil)
        // ditto can't read this, so it stops part way (status 1, measured) with a zip begun.
        let file = library.fileURL(for: try XCTUnwrap(library.icons.first))
        let path = file.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let readable: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        defer { try? FileManager.default.setAttributes(readable, ofItemAtPath: path) }
        let backups = folder.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        do {
            try await library.writeBackup(to: backups.appending(path: "Iconery Backup x.zip"))
            XCTFail("the backup can't succeed without the icon")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path()), [],
                       "nothing is left for pruning to count as a backup")
    }

    @MainActor
    func testAnUnreadableLibraryIsNeverSavedOver() throws {
        let (_, source) = try makeSVGIcon()
        let libraryFolder = folder.appending(path: "Library")
        Library(folder: libraryFolder).importItems([source], into: nil)
        let index = libraryFolder.appending(path: "library.json")
        let before = try Data(contentsOf: index)
        let path = index.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let readable: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        defer { try? FileManager.default.setAttributes(readable, ofItemAtPath: path) }

        let library = Library(folder: libraryFolder)
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

        let library = Library(folder: libraryFolder)
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
        let library = Library(folder: folder.appending(path: "Library"))
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

        let library = Library(folder: folder.appending(path: "Library"))
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

    func testBothIconJarExtensionsAreRecognised() {
        XCTAssertTrue(IconJarLibrary.isLibrary(URL(filePath: "/x/IconJar-backup.ijlibrary")))
        XCTAssertTrue(IconJarLibrary.isLibrary(URL(filePath: "/x/Old.IconJarLibrary")))
        XCTAssertFalse(IconJarLibrary.isLibrary(URL(filePath: "/x/icons")))
        if let type = IconJarLibrary.libraryType {
            XCTAssertTrue(type.conforms(to: .package), "the open panel shows a library as one file")
        }
    }

    @MainActor
    func testFolderWithoutJarsDBIsNotAnIconJarLibrary() {
        let library = Library(folder: folder.appending(path: "Library"))
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
}

import Foundation

/// The file types an icon can be, named by extension. NSImage reads all four; only SVG is
/// vector, and the others are drawn from their best bitmap for each size.
enum IconKind: String, Codable {
    case svg, png, icns, ico

    init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

struct IconSet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// The set this one sits inside; nil at the top level. Optional so libraries saved before
    /// sets could nest still decode.
    var parentID: UUID?
}

struct Icon: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var setID: UUID
    var kind: IconKind
    var tags: [String] = []
    var starred = false
    var added = Date()
    var lastUsed: Date?
    /// IconJar's "Description". Optional, like the two below it, so older libraries still decode.
    var info: String?
    var licenseID: UUID?
    /// The file name it was imported from, without the extension, for "Original file name"
    /// exports. Libraries from before it was kept have none and use the name instead.
    var originalName: String?

    /// The copy inside the library folder, named by id so two icons called "home" never collide.
    var fileName: String { "\(id.uuidString).\(kind.rawValue)" }
}

struct License: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String

    /// What a new library starts with: the licences IconJar seeds its own with.
    static var starters: [License] {
        [
            License(name: "MIT", url: "https://opensource.org/licenses/MIT"),
            License(name: "Apache 2.0 License", url: "https://www.apache.org/licenses/LICENSE-2.0"),
            License(
                name: "GNU General Public License", url: "https://www.gnu.org/licenses/gpl-3.0.html"
            ),
            License(
                name: "Creative Commons Attribution",
                url: "https://creativecommons.org/licenses/by/4.0/"
            ),
            License(
                name: "Creative Commons Attribution-ShareAlike",
                url: "https://creativecommons.org/licenses/by-sa/4.0/"
            ),
            License(
                name: "Creative Commons Attribution-NoDerivs",
                url: "https://creativecommons.org/licenses/by-nd/4.0/"
            ),
            License(
                name: "Creative Commons Attribution-NonCommercial",
                url: "https://creativecommons.org/licenses/by-nc/4.0/"
            ),
            License(
                name: "Creative Commons Attribution-NonCommercial-ShareAlike",
                url: "https://creativecommons.org/licenses/by-nc-sa/4.0/"
            ),
            License(
                name: "Creative Commons Attribution-NonCommercial-NoDerivs",
                url: "https://creativecommons.org/licenses/by-nc-nd/4.0/"
            ),
        ]
    }
}

enum SidebarItem: Hashable {
    case all, recent, starred
    case set(UUID)
}

enum Naming {
    case newSet(parent: UUID?)
    case renameSet(UUID)

    var title: String {
        switch self {
        case .newSet: "New Set"
        case .renameSet: "Rename Set"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newSet: "Create"
        case .renameSet: "Rename"
        }
    }
}

enum Deletion {
    /// `setCount` is the sets nested inside it, at any depth.
    case set(IconSet, iconCount: Int, setCount: Int)
    case icons(Set<UUID>)

    var title: String {
        switch self {
        case .set(let set, _, _): "Delete “\(set.name)”?"
        case .icons(let ids): ids.count == 1 ? "Delete this icon?" : "Delete \(ids.count) icons?"
        }
    }

    var message: String {
        switch self {
        case .set(_, let iconCount, 0):
            "Its \(plural(iconCount, "icon")) leave the library with it. This can't be undone."
        case .set(_, let iconCount, let setCount):
            "The \(plural(setCount, "set")) inside it and \(plural(iconCount, "icon")) leave the "
                + "library with it. This can't be undone."
        case .icons:
            "They leave the library. The files you imported them from are not touched."
        }
    }
}

struct Notice {
    var title: String
    var message: String
}

func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

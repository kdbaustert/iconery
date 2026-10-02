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

/// A saved search in the sidebar, run against the live library each time it's shown.
struct SmartSet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var query: String
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
    case smart(UUID)
    case tag(String)

    /// A defaults-friendly form, so the selection can be restored at the next launch.
    var stored: String {
        switch self {
        case .all: "all"
        case .recent: "recent"
        case .starred: "starred"
        case .set(let id): "set:\(id.uuidString)"
        case .smart(let id): "smart:\(id.uuidString)"
        case .tag(let tag): "tag:\(tag)"
        }
    }

    init?(stored: String) {
        switch stored {
        case "all": self = .all
        case "recent": self = .recent
        case "starred": self = .starred
        default:
            if stored.hasPrefix("set:"), let id = UUID(uuidString: String(stored.dropFirst(4))) {
                self = .set(id)
            } else if stored.hasPrefix("smart:"),
                      let id = UUID(uuidString: String(stored.dropFirst(6))) {
                self = .smart(id)
            } else if stored.hasPrefix("tag:"), stored.count > 4 {
                self = .tag(String(stored.dropFirst(4)))
            } else {
                return nil
            }
        }
    }
}

enum Naming {
    case newSet(parent: UUID?)
    case renameSet(UUID)
    case renameIcon(UUID)
    case renameSmartSet(UUID)
    case editSmartSetQuery(UUID)

    var title: String {
        switch self {
        case .newSet: "New Set"
        case .renameSet: "Rename Set"
        case .renameIcon: "Rename Icon"
        case .renameSmartSet: "Rename Smart Set"
        case .editSmartSetQuery: "Edit Query"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newSet: "Create"
        case .renameSet, .renameIcon, .renameSmartSet: "Rename"
        case .editSmartSetQuery: "Save"
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
            "Its \(plural(iconCount, "icon")) leave the library with it. Undo brings them back; "
                + "their files wait in the Trash."
        case .set(_, let iconCount, let setCount):
            "The \(plural(setCount, "set")) inside it and \(plural(iconCount, "icon")) leave the "
                + "library with it. Undo brings them back; the files wait in the Trash."
        case .icons:
            "Their files here move to the Trash, and Undo brings them back. The files you "
                + "imported them from are not touched."
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

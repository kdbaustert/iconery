import Foundation
import SQLite3
import UniformTypeIdentifiers

/// An IconJar library (.ijlibrary), read straight from IconJar's own store: a Core Data SQLite
/// file, Jars.db, beside a Sets/ folder holding each set's files. Groups hold sets and can nest;
/// sets hold icons. Layout measured on IconJar 2.11.4 (Setapp) on 2026-10-02, against both a
/// current library and an older one.
struct IconJarLibrary {
    struct Group {
        var key: Int
        var uuid: String
        var name: String
        var parent: Int?
    }

    struct Collection {
        var key: Int
        var uuid: String
        /// The set's folder under Sets/. Not its uuid, which is a different value.
        var folder: String
        var name: String
        var group: Int?
    }

    struct Item {
        var uuid: String
        var name: String?
        /// Relative to its set's folder.
        var file: String
        var tags: [String]
        var starred: Bool
        var added: Date?
        var lastUsed: Date?
        var collection: Int
        /// IconJar's own record of the file type: 0 SVG, 1 PNG, 4 ICNS, 6 ICO.
        var type: Int?

        /// For a file whose extension doesn't say what it is. Measured on this Mac: one ICNS was
        /// stored as "onyx-dark-alt.-null-".
        var recordedKind: IconKind? {
            switch type {
            case 0: .svg
            case 1: .png
            case 4: .icns
            case 6: .ico
            default: nil
            }
        }
    }

    struct Unreadable: LocalizedError {
        var errorDescription: String?
    }

    var groups: [Group] = []
    var collections: [Collection] = []
    var items: [Item] = []

    /// IconJar's own library type, a package. Looked up by identifier: on this Mac,
    /// `UTType(filenameExtension: "ijlibrary")` returned a dynamic, non-package type (measured),
    /// so an open panel filtering on it greyed out every library. nil when IconJar isn't installed,
    /// and then a library is a plain folder.
    static let libraryType = UTType("com.iconjar-library")
    /// Both extensions IconJar 2.11.4 declares for that type.
    static let extensions: Set<String> = ["ijlibrary", "iconjarlibrary"]

    static func isLibrary(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Reads a copy of the store, never the original: IconJar may have it open, and even a
    /// read-only SQLite open can leave files beside the database.
    static func read(_ library: URL) throws -> IconJarLibrary {
        let store = library.appending(path: "Jars.db")
        guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else {
            throw Unreadable(
                errorDescription: "“\(library.lastPathComponent)” has no Jars.db inside, so it "
                    + "isn't an IconJar library."
            )
        }
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "IconeryIconJar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The -wal file holds writes not yet folded into the database; a copy without it is stale.
        for suffix in ["", "-wal", "-shm"] {
            let file = library.appending(path: "Jars.db\(suffix)")
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                let copy = scratch.appending(path: "Jars.db\(suffix)")
                try FileManager.default.copyItem(at: file, to: copy)
            }
        }

        var handle: OpaquePointer?
        let path = scratch.appending(path: "Jars.db").path(percentEncoded: false)
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle
        else {
            sqlite3_close(handle)
            throw Unreadable(errorDescription: "IconJar's database could not be opened.")
        }
        defer { sqlite3_close(db) }

        var jar = IconJarLibrary()
        try query(db, "SELECT Z_PK, ZUUID, ZNAME, ZGROUP FROM ZIJGROUP") { row in
            jar.groups.append(Group(
                key: row.int(0) ?? 0, uuid: row.text(1) ?? "", name: row.text(2) ?? "Group",
                parent: row.int(3)
            ))
        }
        // ZTYPE 0 is an ordinary set. 3 and 4 are IconJar's built-in Starred and Recently Used,
        // which Iconery has its own versions of.
        try query(
            db, "SELECT Z_PK, ZUUID, ZIDENTIFIER, ZNAME, ZGROUP FROM ZIJCOLLECTION WHERE ZTYPE = 0"
        ) { row in
            guard let folder = row.text(2) else { return }
            jar.collections.append(Collection(
                key: row.int(0) ?? 0, uuid: row.text(1) ?? "", folder: folder,
                name: row.text(3) ?? folder, group: row.int(4)
            ))
        }
        try query(
            db, "SELECT ZUUID, ZNAME, ZNEWFILENAME, ZTAGSSTRING, ZSTARRED, ZDATE, ZLASTUSEDDATE, "
                + "ZCOLLECTION, ZTYPE FROM ZIJITEM"
        ) { row in
            guard let file = row.text(2), let collection = row.int(7) else { return }
            jar.items.append(Item(
                uuid: row.text(0) ?? "",
                name: row.text(1),
                file: file,
                // A comma-separated string, not a list: "Insomnia,Alt".
                tags: (row.text(3) ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                starred: row.int(4) == 1,
                // Core Data stores dates as seconds since 2001, not 1970.
                added: row.double(5).map(Date.init(timeIntervalSinceReferenceDate:)),
                lastUsed: row.double(6).map(Date.init(timeIntervalSinceReferenceDate:)),
                collection: collection,
                type: row.int(8)
            ))
        }
        return jar
    }

    private struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int? {
            isNull(column) ? nil : Int(sqlite3_column_int64(statement, column))
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        private func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, each: (Row) -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle
        else {
            throw Unreadable(
                errorDescription: "IconJar's database isn't laid out the way this version of "
                    + "Iconery expects: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            each(Row(statement: statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw Unreadable(errorDescription: String(cString: sqlite3_errmsg(db)))
        }
    }
}

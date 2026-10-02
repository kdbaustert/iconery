import Foundation
import Observation

enum BackupSchedule: String, CaseIterable, Identifiable {
    case never, daily, weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .never: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

enum GridSort: String, CaseIterable, Identifiable {
    case name, fileType, dateAdded, dateUsed

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .fileType: "File Type"
        case .dateAdded: "Date Added"
        case .dateUsed: "Date Used"
        }
    }

    /// The direction a key starts in when picked: names read A to Z, dates newest first.
    var startsDescending: Bool {
        switch self {
        case .name, .fileType: false
        case .dateAdded, .dateUsed: true
        }
    }

    var ascendingTitle: String {
        switch self {
        case .name, .fileType: "A to Z"
        case .dateAdded, .dateUsed: "Oldest First"
        }
    }

    var descendingTitle: String {
        switch self {
        case .name, .fileType: "Z to A"
        case .dateAdded, .dateUsed: "Newest First"
        }
    }
}

enum LabelMode: String, CaseIterable, Identifiable {
    case always, hover, never

    var id: Self { self }

    var title: String {
        switch self {
        case .always: "Always"
        case .hover: "On Hover"
        case .never: "Never"
        }
    }
}

/// How the app behaves, kept in UserDefaults. What an export writes lives in ExportOptions.
/// Tests hand Library an instance with no defaults at all, which keeps everything in memory:
/// a throwaway UserDefaults suite still leaves a plist in ~/Library/Preferences (measured).
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults?

    // Library
    var backupSchedule: BackupSchedule {
        didSet { save(backupSchedule.rawValue, "backupSchedule") }
    }
    /// 0 keeps every backup.
    var backupsKept: Int { didSet { save(backupsKept, "backupsKept") } }

    // General
    /// Picking a new key starts it in its usual direction: names A to Z, dates newest first.
    var sort: GridSort {
        didSet {
            save(sort.rawValue, "gridSort")
            if sort != oldValue { sortDescending = sort.startsDescending }
        }
    }
    var sortDescending: Bool { didSet { save(sortDescending, "gridSortDescending") } }
    var labels: LabelMode { didSet { save(labels.rawValue, "gridLabels") } }
    var searchesTags: Bool { didSet { save(searchesTags, "searchTags") } }
    var searchesSetNames: Bool { didSet { save(searchesSetNames, "searchSetNames") } }
    var searchesDescriptions: Bool { didSet { save(searchesDescriptions, "searchDescriptions") } }
    var recentLimit: Int { didSet { save(recentLimit, "recentLimit") } }
    var confirmsIconDeletion: Bool { didSet { save(confirmsIconDeletion, "confirmIconDeletion") } }

    // Import
    var skipsDuplicates: Bool { didSet { save(skipsDuplicates, "importSkipsDuplicates") } }
    var readsSVGTitles: Bool { didSet { save(readsSVGTitles, "importReadsSVGTitles") } }
    /// The set loose files go into when no set is selected; nil for "Unsorted".
    var looseFilesSetID: UUID? { didSet { save(looseFilesSetID?.uuidString, "looseFilesSet") } }

    // Export
    var keepsSetFolders: Bool { didSet { save(keepsSetFolders, "exportKeepsSetFolders") } }
    var addsFinderTags: Bool { didSet { save(addsFinderTags, "exportAddsFinderTags") } }
    var revealsExports: Bool { didSet { save(revealsExports, "revealsExports") } }

    // Window, restored at launch
    var sidebarItem: String? { didSet { save(sidebarItem, "sidebarItem") } }
    var expandedSetIDs: [String] { didSet { save(expandedSetIDs, "expandedSets") } }

    static let recentLimits = [25, 50, 100, 200, 500]
    static let backupCounts = [5, 10, 20, 50, 0]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        func stored<Value>(_ key: String) -> Value? { defaults?.object(forKey: key) as? Value }
        backupSchedule = stored("backupSchedule").flatMap(BackupSchedule.init) ?? .never
        backupsKept = stored("backupsKept") ?? 10
        let sortKey: GridSort = stored("gridSort").flatMap(GridSort.init) ?? .name
        sort = sortKey
        // Date Added showed newest first before direction existed, so that stays its default.
        sortDescending = stored("gridSortDescending") ?? (sortKey == .dateAdded)
        labels = stored("gridLabels").flatMap(LabelMode.init) ?? .always
        searchesTags = stored("searchTags") ?? true
        searchesSetNames = stored("searchSetNames") ?? false
        searchesDescriptions = stored("searchDescriptions") ?? false
        recentLimit = stored("recentLimit") ?? 100
        confirmsIconDeletion = stored("confirmIconDeletion") ?? true
        skipsDuplicates = stored("importSkipsDuplicates") ?? true
        readsSVGTitles = stored("importReadsSVGTitles") ?? true
        looseFilesSetID = stored("looseFilesSet").flatMap(UUID.init(uuidString:))
        keepsSetFolders = stored("exportKeepsSetFolders") ?? false
        addsFinderTags = stored("exportAddsFinderTags") ?? false
        revealsExports = stored("revealsExports") ?? true
        sidebarItem = stored("sidebarItem")
        expandedSetIDs = stored("expandedSets") ?? []
    }

    private func save(_ value: Any?, _ key: String) {
        defaults?.set(value, forKey: key)
    }
}

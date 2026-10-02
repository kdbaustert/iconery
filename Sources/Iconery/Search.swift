import Foundation

/// Which fields search looks at besides the name, which it always does.
struct SearchScope: Equatable {
    var tags = true
    var setNames = false
    var descriptions = false
}

/// Whether `icon` belongs in the grid while the search field holds `query`. Every word typed has
/// to turn up in one of the searched fields, so each word narrows the grid. Matching ignores case
/// and accents and finds a word anywhere, so "row" finds "arrow". `setPath` is the icon's whole
/// set path, so searching a parent set's name finds the icons in the sets inside it.
///
/// A word can also name its field, whatever the scope says: tag:arrow looks only at tags,
/// kind:svg (or type:svg) wants that file type exactly, and set:outline looks at the set path.
func iconMatches(_ icon: Icon, query: String, setPath: String, scope: SearchScope) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    var fields = [icon.name]
    if scope.tags { fields += icon.tags }
    if scope.setNames { fields.append(setPath) }
    if scope.descriptions, let info = icon.info { fields.append(info) }
    func found(_ word: some StringProtocol, in fields: [String]) -> Bool {
        fields.contains {
            $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    return words.allSatisfy { word in
        let lowered = word.lowercased()
        if lowered.hasPrefix("tag:") { return found(word.dropFirst(4), in: icon.tags) }
        if lowered.hasPrefix("kind:") { return icon.kind.rawValue == lowered.dropFirst(5) }
        if lowered.hasPrefix("type:") { return icon.kind.rawValue == lowered.dropFirst(5) }
        if lowered.hasPrefix("set:") { return found(word.dropFirst(4), in: [setPath]) }
        return found(word, in: fields)
    }
}

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
func iconMatches(_ icon: Icon, query: String, setPath: String, scope: SearchScope) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    var fields = [icon.name]
    if scope.tags { fields += icon.tags }
    if scope.setNames { fields.append(setPath) }
    if scope.descriptions, let info = icon.info { fields.append(info) }
    return words.allSatisfy { word in
        fields.contains {
            $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

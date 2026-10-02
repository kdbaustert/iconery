import Foundation

/// Whether `icon` belongs in the grid while the search field holds `query`.
///
/// TODO(kenny): this is a placeholder rule, a plain substring match on the name. Decide what
/// searching an icon library should mean and replace it (5-10 lines). The choices that matter:
/// - Which fields count: the name only, or tags and the set name too, so "arrows" finds every
///   icon in the Arrows set?
/// - Several words: must every word match somewhere (narrows as you type) or any one of them?
/// - Where in a word: anywhere ("row" finds "arrow"), or only at word starts, which stops short
///   queries flooding the grid?
func iconMatches(_ icon: Icon, query: String, setName: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || icon.name.localizedCaseInsensitiveContains(query)
}

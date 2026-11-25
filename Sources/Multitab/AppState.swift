import Foundation
import Observation

struct TabSpec: Codable {
    var id: UUID
    var spec: String
    var sort: String
    var time: String
}

enum Spec {
    private static func capture(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Turns what the user typed into a feed spec: r/name, r/a+b, u/name, search:words, home, popular, all.
    static func normalize(_ raw: String) -> String? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.replacingOccurrences(of: #"^https?://(www\.|old\.|new\.)?reddit\.com"#, with: "", options: [.regularExpression, .caseInsensitive])
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !v.isEmpty else { return nil }
        let low = v.lowercased()
        if ["home", "popular", "all"].contains(low) { return low }
        if low.hasPrefix("search:") {
            let q = v.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? nil : "search:" + q
        }
        if let u = capture(#"^(?:u|user)/([A-Za-z0-9_-]{2,})$"#, v) { return "u/" + u }
        if let r = capture(#"^(?:r/)?([A-Za-z0-9_]{2,21}(?:\+[A-Za-z0-9_]{2,21})*)$"#, v) { return "r/" + r }
        return nil
    }

    static func label(_ s: String) -> String {
        switch s {
        case "home": return "Home"
        case "popular": return "Popular"
        case "all": return "All"
        default: return s.hasPrefix("search:") ? "Search: " + s.dropFirst(7) : s
        }
    }
}

@MainActor @Observable
final class Feed: Identifiable {
    let id: UUID
    var spec: String
    var sort: String
    var time: String

    var items: [MediaItem] = []
    var loading = false
    var done = false
    var error: String?

    @ObservationIgnored private var after: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var gen = 0

    init(_ t: TabSpec) {
        id = t.id; spec = t.spec; sort = t.sort; time = t.time
    }

    var tabSpec: TabSpec { TabSpec(id: id, spec: spec, sort: sort, time: time) }
    var label: String { Spec.label(spec) }

    private func endpoint() -> (String, [String: String]) {
        var q: [String: String] = ["limit": "50"]
        if let after { q["after"] = after }
        if sort == "top" { q["t"] = time }
        if spec == "home" { return ("/" + sort, q) }
        if spec == "popular" || spec == "all" { return ("/r/\(spec)/\(sort)", q) }
        if spec.hasPrefix("r/") { return ("/r/\(spec.dropFirst(2))/\(sort)", q) }
        if spec.hasPrefix("u/") {
            q["sort"] = sort == "rising" ? "hot" : sort
            return ("/user/\(spec.dropFirst(2))/submitted", q)
        }
        if spec.hasPrefix("search:") {
            q["q"] = String(spec.dropFirst(7))
            q["type"] = "link"
            q["sort"] = ["hot": "relevance", "new": "new", "top": "top", "rising": "hot"][sort] ?? "relevance"
            return ("/search", q)
        }
        return ("/r/popular/hot", q)
    }

    /// Loads pages until at least ~18 new media items arrive, since many posts have no media.
    func loadMore(_ client: RedditClient) async {
        guard !loading, !done else { return }
        loading = true
        error = nil
        let g = gen
        var added = 0, pages = 0
        do {
            while added < 18 && pages < 4 && !done {
                let (path, query) = endpoint()
                let page = try await client.listing(path: path, query: query)
                guard g == gen else { return }
                pages += 1
                for item in page.items where !seen.contains(item.id) {
                    seen.insert(item.id)
                    items.append(item)
                    added += 1
                }
                after = page.after
                if after == nil { done = true }
            }
        } catch {
            if g == gen { self.error = error.localizedDescription }
        }
        if g == gen { loading = false }
    }

    func reset() {
        gen += 1
        items = []
        after = nil
        done = false
        loading = false
        error = nil
        seen = []
    }
}

struct ViewerTarget: Equatable {
    let feedID: UUID
    var index: Int
}

@MainActor @Observable
final class AppState {
    var feeds: [Feed]
    var activeID: UUID?
    var visited: Set<UUID> = []
    var creds: Credentials
    var viewer: ViewerTarget?
    var showSettings = false
    var showAdd = false
    var blurNSFW: Bool
    var tileSize: Double

    // View state. Kept here because SwiftUI's @State needs full Xcode to compile.
    var hoveredTab: UUID?
    var hoveredTile: String?
    var addText = ""
    var addInvalid = false
    var viewerInfo = false
    var revealed: Set<String> = []
    var draft = Credentials()
    var settingsStatus: String?
    var settingsWorking = false

    static let shared = AppState()

    @ObservationIgnored let client: RedditClient

    init() {
        let c = CredentialStore.load()
        creds = c
        client = RedditClient(creds: c)
        let d = UserDefaults.standard
        blurNSFW = d.object(forKey: "blurNSFW") as? Bool ?? true
        tileSize = d.object(forKey: "tileSize") as? Double ?? 220
        var specs = (d.data(forKey: "tabs.v1")).flatMap { try? JSONDecoder().decode([TabSpec].self, from: $0) } ?? []
        if specs.isEmpty {
            specs = ["r/pics", "r/gifs", "r/aww"].map { TabSpec(id: UUID(), spec: $0, sort: "hot", time: "day") }
        }
        feeds = specs.map(Feed.init)
        let saved = UUID(uuidString: d.string(forKey: "activeTab") ?? "")
        activeID = feeds.contains { $0.id == saved } ? saved : feeds.first?.id
        if let activeID { visited.insert(activeID) }
    }

    var activeFeed: Feed? { feeds.first { $0.id == activeID } }

    func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(feeds.map(\.tabSpec)), forKey: "tabs.v1")
        d.set(activeID?.uuidString, forKey: "activeTab")
        d.set(blurNSFW, forKey: "blurNSFW")
        d.set(tileSize, forKey: "tileSize")
    }

    func activate(_ id: UUID) {
        guard feeds.contains(where: { $0.id == id }) else { return }
        activeID = id
        visited.insert(id)
        save()
    }

    func activate(index: Int) {
        if feeds.indices.contains(index) { activate(feeds[index].id) }
    }

    func open(_ spec: String) {
        if let existing = feeds.first(where: { $0.spec.lowercased() == spec.lowercased() }) {
            activate(existing.id)
            return
        }
        let feed = Feed(TabSpec(id: UUID(), spec: spec, sort: "hot", time: "day"))
        let i = feeds.firstIndex { $0.id == activeID } ?? feeds.count - 1
        feeds.insert(feed, at: min(i + 1, feeds.count))
        activate(feed.id)
    }

    func close(_ id: UUID) {
        guard feeds.count > 1, let i = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds.remove(at: i)
        visited.remove(id)
        if viewer?.feedID == id { viewer = nil }
        if activeID == id { activate(feeds[max(0, i - 1)].id) } else { save() }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = feeds.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard feeds.indices.contains(j) else { return }
        feeds.swapAt(i, j)
        save()
    }

    func reload(_ feed: Feed) {
        feed.reset()
        save()
        Task { await feed.loadMore(client) }
    }

    func updateCredentials(_ c: Credentials) async throws {
        try CredentialStore.save(c)
        creds = c
        await client.update(c)
        for f in feeds { f.reset() }
        if let f = activeFeed { await f.loadMore(client) }
    }
}

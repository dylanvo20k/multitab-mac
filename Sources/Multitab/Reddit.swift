import Foundation

// MARK: - Credentials

struct Credentials: Codable, Equatable, Sendable {
    var clientId = ""
    var clientSecret = ""
    var username = ""
    var password = ""

    var isComplete: Bool { !clientId.trimmingCharacters(in: .whitespaces).isEmpty }
    var signsIn: Bool { !username.isEmpty && !password.isEmpty }

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id", clientSecret = "client_secret", username, password
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        // Treat untouched placeholders from config.example.json as empty.
        if clientId.hasPrefix("PASTE_") { clientId = "" }
        if clientSecret.hasPrefix("PASTE_") { clientSecret = "" }
    }
}

/// Saved as a private (0600) file in ~/Library/Application Support/Multitab.
enum CredentialStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multitab/credentials.json")
    }

    static func load() -> Credentials {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Credentials.self, from: d) {
            return c
        }
        // Reuse the config from the earlier web version, if it was set up.
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("multitab/config.json")
        if let d = try? Data(contentsOf: legacy), let c = try? JSONDecoder().decode(Credentials.self, from: d), c.isComplete {
            return c
        }
        return Credentials()
    }

    static func save(_ c: Credentials) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(c).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Errors

enum RedditError: LocalizedError {
    case notConfigured
    case auth(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Reddit app ID in Settings."
        case .auth(let m): return m
        case .http(403): return "Reddit blocked this feed. It may be private, quarantined or banned."
        case .http(404): return "Reddit couldn't find that. Check the name."
        case .http(429): return "Reddit is rate limiting the app. Wait a minute, then try again."
        case .http(let c): return "Reddit returned an error (\(c))."
        }
    }
}

// MARK: - Media

struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case image, gif, video }

    let id: String
    let kind: Kind
    let thumb: URL?
    let full: URL          // full-size image, or mp4
    let hls: URL?          // video stream with sound
    let aspect: Double     // width / height
    let title: String
    let subreddit: String
    let permalink: String
    let nsfw: Bool

    var redditURL: URL? { URL(string: "https://www.reddit.com" + permalink) }
}

struct Page: Sendable {
    let items: [MediaItem]
    let after: String?
}

enum MediaParser {
    private static func url(_ v: Any?) -> URL? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return URL(string: s.replacingOccurrences(of: "&amp;", with: "&"))
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static let imageExt = try! NSRegularExpression(pattern: #"\.(jpe?g|png|webp|gif)(\?.*)?$"#, options: .caseInsensitive)

    private static func isImageURL(_ s: String) -> Bool {
        imageExt.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func items(from post: [String: Any]) -> [MediaItem] {
        guard let name = post["name"] as? String else { return [] }
        let title = post["title"] as? String ?? ""
        let sub = post["subreddit_name_prefixed"] as? String ?? ""
        let permalink = post["permalink"] as? String ?? ""
        let nsfw = post["over_18"] as? Bool ?? false

        // Crossposts keep their media on the original post.
        var src = post
        let hasOwnMedia = post["preview"] != nil || post["media_metadata"] != nil || (post["media"] as? [String: Any]) != nil
        if !hasOwnMedia, let parent = (post["crosspost_parent_list"] as? [[String: Any]])?.first {
            src = parent
        }

        func make(_ suffix: String, _ kind: MediaItem.Kind, thumb: URL?, full: URL, hls: URL? = nil, w: Double?, h: Double?) -> MediaItem {
            let aspect = (w ?? 0) > 0 && (h ?? 0) > 0 ? w! / h! : 1
            return MediaItem(id: name + suffix, kind: kind, thumb: thumb, full: full, hls: hls, aspect: aspect,
                             title: title, subreddit: sub, permalink: permalink, nsfw: nsfw)
        }

        // Galleries: every image becomes its own tile.
        if (src["is_gallery"] as? Bool) == true,
           let meta = src["media_metadata"] as? [String: Any],
           let entries = (src["gallery_data"] as? [String: Any])?["items"] as? [[String: Any]] {
            var out: [MediaItem] = []
            for (i, entry) in entries.enumerated() {
                guard let mid = entry["media_id"] as? String,
                      let m = meta[mid] as? [String: Any],
                      (m["status"] as? String) == "valid",
                      let s = m["s"] as? [String: Any] else { continue }
                let previews = m["p"] as? [[String: Any]] ?? []
                let p = previews.first { (num($0["x"]) ?? 0) >= 480 } ?? previews.last
                let thumb = url(p?["u"]) ?? url(s["u"]) ?? url(s["gif"])
                if let mp4 = url(s["mp4"]) {
                    out.append(make("-\(i)", .gif, thumb: thumb, full: mp4, w: num(s["x"]), h: num(s["y"])))
                } else if let full = url(s["u"]) ?? url(s["gif"]) {
                    out.append(make("-\(i)", .image, thumb: thumb, full: full, w: num(s["x"]), h: num(s["y"])))
                }
            }
            return out
        }

        let preview = src["preview"] as? [String: Any]
        let img = (preview?["images"] as? [[String: Any]])?.first
        let source = img?["source"] as? [String: Any]
        let resolutions = img?["resolutions"] as? [[String: Any]] ?? []
        let thumb = url((resolutions.first { (num($0["width"]) ?? 0) >= 480 } ?? resolutions.last)?["url"]) ?? url(source?["url"])
        let sw = num(source?["width"]), sh = num(source?["height"])

        // Reddit-hosted video (and many external videos Reddit has a copy of).
        let rv = ((src["secure_media"] as? [String: Any])?["reddit_video"]
                  ?? (src["media"] as? [String: Any])?["reddit_video"]
                  ?? preview?["reddit_video_preview"]) as? [String: Any]
        if let rv, let fallback = url(rv["fallback_url"]) {
            let isGif = rv["is_gif"] as? Bool ?? false
            return [make("", isGif ? .gif : .video, thumb: thumb, full: fallback, hls: isGif ? nil : url(rv["hls_url"]),
                         w: num(rv["width"]) ?? sw, h: num(rv["height"]) ?? sh)]
        }

        // GIFs: Reddit provides an mp4 version.
        if let mp4 = ((img?["variants"] as? [String: Any])?["mp4"] as? [String: Any])?["source"] as? [String: Any],
           let mp4URL = url(mp4["url"]) {
            return [make("", .gif, thumb: thumb, full: mp4URL, w: num(mp4["width"]), h: num(mp4["height"]))]
        }

        let link = (src["url_overridden_by_dest"] as? String) ?? (src["url"] as? String) ?? ""
        if link.lowercased().hasSuffix(".gifv"), let mp4 = URL(string: String(link.dropLast(5)) + ".mp4") {
            return [make("", .gif, thumb: thumb, full: mp4, w: sw, h: sh)]
        }
        if isImageURL(link), let direct = url(link) {
            return [make("", .image, thumb: thumb ?? direct, full: direct, w: sw, h: sh)]
        }
        if (src["post_hint"] as? String) == "image", let full = url(source?["url"]) {
            return [make("", .image, thumb: thumb, full: full, w: sw, h: sh)]
        }
        return []  // text posts and article links are skipped
    }
}

// MARK: - Client

actor RedditClient {
    private var creds: Credentials
    private var token: String?
    private var expiry = Date.distantPast

    init(creds: Credentials) { self.creds = creds }

    func update(_ c: Credentials) {
        creds = c
        token = nil
    }

    private var userAgent: String {
        "macos:multitab-gallery:v0.1 (personal use by /u/\(creds.username.isEmpty ? "unknown" : creds.username))"
    }

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return Data(s.utf8)
    }

    private func accessToken(force: Bool) async throws -> String {
        if !force, let token, Date() < expiry.addingTimeInterval(-60) { return token }
        guard creds.isComplete else { throw RedditError.notConfigured }

        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        let basic = Data("\(creds.clientId.trimmingCharacters(in: .whitespaces)):\(creds.clientSecret.trimmingCharacters(in: .whitespaces))".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = creds.signsIn
            ? Self.formEncode([("grant_type", "password"), ("username", creds.username), ("password", creds.password)])
            : Self.formEncode([("grant_type", "client_credentials")])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RedditError.auth("Reddit refused the login (\(code)). Check the app ID and secret in Settings.")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let t = obj["access_token"] as? String else {
            let why = obj["error"] as? String ?? "unknown error"
            let hint = creds.signsIn ? " If your account uses two-factor auth, clear the username and password in Settings." : ""
            throw RedditError.auth("Reddit refused the login: \(why).\(hint)")
        }
        token = t
        expiry = Date().addingTimeInterval((obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        return t
    }

    private func getJSON(_ path: String, _ query: [String: String]) async throws -> Any {
        var comps = URLComponents(string: "https://oauth.reddit.com" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "raw_json", value: "1")]
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw RedditError.http(400) }

        for attempt in 0..<2 {
            let t = try await accessToken(force: attempt == 1)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { continue }
            guard code == 200 else { throw RedditError.http(code) }
            return try JSONSerialization.jsonObject(with: data)
        }
        throw RedditError.http(401)
    }

    func listing(path: String, query: [String: String]) async throws -> Page {
        let obj = try await getJSON(path, query)
        guard let data = (obj as? [String: Any])?["data"] as? [String: Any] else { return Page(items: [], after: nil) }
        var out: [MediaItem] = []
        for child in data["children"] as? [[String: Any]] ?? [] where (child["kind"] as? String) == "t3" {
            if let post = child["data"] as? [String: Any] { out += MediaParser.items(from: post) }
        }
        return Page(items: out, after: data["after"] as? String)
    }
}

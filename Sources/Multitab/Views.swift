import AppKit
import SwiftUI

@main
struct MultitabApp: App {
    private let app = AppState.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 256 << 20, diskCapacity: 2 << 30)
    }

    var body: some Scene {
        WindowGroup("Multitab") {
            ContentView()
                .environment(app)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { app.showAdd = true }.keyboardShortcut("t")
                Button("Close Tab") { if let id = app.activeID { app.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Refresh") { if let f = app.activeFeed { app.reload(f) } }.keyboardShortcut("r")
                Divider()
                ForEach(1..<10) { n in
                    Button("Tab \(n)") { app.activate(index: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }.keyboardShortcut(",")
            }
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            ZStack {
                if !app.creds.isComplete {
                    SetupView()
                } else {
                    // Keep visited tabs alive so each keeps its scroll position.
                    ForEach(app.feeds.filter { app.visited.contains($0.id) }) { feed in
                        let on = feed.id == app.activeID
                        GridView(feed: feed)
                            .opacity(on ? 1 : 0)
                            .allowsHitTesting(on)
                            .accessibilityHidden(!on)
                    }
                }
            }
        }
        .overlay {
            if let target = app.viewer, let feed = app.feeds.first(where: { $0.id == target.feedID }) {
                ViewerView(feed: feed)
            }
        }
        .toolbar { Toolbar() }
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .onChange(of: app.tileSize) { app.save() }
        .onChange(of: app.blurNSFW) { app.save() }
    }
}

struct Toolbar: ToolbarContent {
    @Environment(AppState.self) private var app

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let feed = app.activeFeed {
                FeedControls(feed: feed)
            }
            Slider(value: Binding(get: { app.tileSize }, set: { app.tileSize = $0 }), in: 120...420) {
                Text("Tile size")
            } minimumValueLabel: {
                Image(systemName: "square.grid.3x3")
            } maximumValueLabel: {
                Image(systemName: "square.grid.2x2")
            }
            .frame(width: 150)
            .help("Tile size")
            Button { app.showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
    }
}

struct FeedControls: View {
    @Environment(AppState.self) private var app
    @Bindable var feed: Feed

    var body: some View {
        Picker("Sort", selection: $feed.sort) {
            Text("Hot").tag("hot")
            Text("New").tag("new")
            Text("Top").tag("top")
            Text("Rising").tag("rising")
        }
        .pickerStyle(.segmented)
        .onChange(of: feed.sort) { app.reload(feed) }
        if feed.sort == "top" {
            Picker("Time", selection: $feed.time) {
                Text("Past hour").tag("hour")
                Text("Today").tag("day")
                Text("This week").tag("week")
                Text("This month").tag("month")
                Text("This year").tag("year")
                Text("All time").tag("all")
            }
            .onChange(of: feed.time) { app.reload(feed) }
        }
        Button { app.reload(feed) } label: { Image(systemName: "arrow.clockwise") }
            .help("Refresh (⌘R)")
    }
}

// MARK: - Tabs

struct TabStrip: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(app.feeds.enumerated()), id: \.element.id) { i, feed in
                        TabButton(feed: feed, index: i)
                    }
                }
                .padding(.vertical, 6)
            }
            Button { app.showAdd = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab (⌘T)")
                .popover(isPresented: $app.showAdd, arrowEdge: .bottom) { AddTabView() }
        }
        .padding(.horizontal, 10)
    }
}

struct TabButton: View {
    @Environment(AppState.self) private var app
    let feed: Feed
    let index: Int

    var body: some View {
        let on = feed.id == app.activeID
        let hovering = app.hoveredTab == feed.id
        HStack(spacing: 6) {
            Text(feed.label).lineLimit(1)
            if app.feeds.count > 1 && (hovering || on) {
                Button { app.close(feed.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(on ? Color.accentColor : (hovering ? Color.primary.opacity(0.08) : .clear), in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(on ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { app.activate(feed.id) }
        .onHover { inside in
            if inside { app.hoveredTab = feed.id } else if app.hoveredTab == feed.id { app.hoveredTab = nil }
        }
        .help(index < 9 ? "\(feed.spec)  (⌘\(index + 1))" : feed.spec)
        .contextMenu {
            Button("Move Left") { app.move(feed.id, by: -1) }.disabled(index == 0)
            Button("Move Right") { app.move(feed.id, by: 1) }.disabled(index == app.feeds.count - 1)
            Divider()
            Button("Close Tab") { app.close(feed.id) }.disabled(app.feeds.count < 2)
        }
    }
}

struct AddTabView: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 10) {
            Text("Open a feed").font(.headline)
            TextField("r/pics, r/gifs+aww, u/name, search: cats", text: $app.addText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: app.addText) { app.addInvalid = false }
            if app.addInvalid {
                Text("Try r/subreddit, u/username, search: words, popular, all or home.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                ForEach(app.creds.signsIn ? ["home", "popular", "all"] : ["popular", "all"], id: \.self) { s in
                    Button(Spec.label(s)) { app.open(s); app.showAdd = false }
                }
                Spacer()
                Button("Open", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { app.addText = ""; app.addInvalid = false; focused = true }
    }

    private func submit() {
        guard let spec = Spec.normalize(app.addText) else { app.addInvalid = true; return }
        app.open(spec)
        app.showAdd = false
    }
}

// MARK: - Grid

struct GridView: View {
    @Environment(AppState.self) private var app
    let feed: Feed

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: app.tileSize), spacing: 4)], spacing: 4) {
                ForEach(Array(feed.items.enumerated()), id: \.element.id) { i, item in
                    Tile(item: item, playing: app.hoveredTile == item.id, blur: app.blurNSFW && item.nsfw)
                        .aspectRatio(1, contentMode: .fit)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { app.hoveredTile = item.id } else if app.hoveredTile == item.id { app.hoveredTile = nil }
                        }
                        .onTapGesture { app.viewer = ViewerTarget(feedID: feed.id, index: i) }
                        .onAppear {
                            if i >= feed.items.count - 12 { Task { await feed.loadMore(app.client) } }
                        }
                }
            }
            .padding(4)
            footer.padding(24)
        }
        .task(id: feed.id) {
            if feed.items.isEmpty && !feed.done { await feed.loadMore(app.client) }
        }
    }

    @ViewBuilder private var footer: some View {
        if let error = feed.error {
            VStack(spacing: 8) {
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await feed.loadMore(app.client) } }
            }
        } else if feed.loading {
            ProgressView()
        } else if feed.done {
            Text(feed.items.isEmpty ? "No images or videos in this feed." : "That's everything in this feed.")
                .foregroundStyle(.secondary)
        } else if !feed.items.isEmpty {
            Button("Load More") { Task { await feed.loadMore(app.client) } }
        }
    }
}

struct Tile: View {
    let item: MediaItem
    let playing: Bool
    let blur: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.06))
                AsyncImage(url: item.thumb ?? (item.kind == .image ? item.full : nil)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.small)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                if (playing || item.thumb == nil) && item.kind != .image && !blur {
                    LoopingVideo(url: item.full)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            .blur(radius: blur ? 28 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if item.kind != .image {
                    Text(item.kind == .video ? "VIDEO" : "GIF")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay {
                if blur {
                    Text("NSFW").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 3)
                }
            }
        }
    }
}

// MARK: - Full-window viewer

struct ViewerView: View {
    @Environment(AppState.self) private var app
    let feed: Feed
    @FocusState private var focused: Bool

    private var index: Int { app.viewer?.index ?? 0 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            if feed.items.indices.contains(index) {
                let item = feed.items[index]
                media(item)
                    .id(item.id)
                    .blur(radius: app.blurNSFW && item.nsfw && !app.revealed.contains(item.id) ? 40 : 0)
                    .onTapGesture { app.revealed.insert(item.id) }
                    .padding(.horizontal, 56)
                    .padding(.vertical, 20)
                if app.viewerInfo { infoBar(item) }
            }
            edgeButtons
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { app.viewer = nil; return .handled }
        .onKeyPress("i") { app.viewerInfo.toggle(); return .handled }
        .onKeyPress("o") {
            if feed.items.indices.contains(index), let u = feed.items[index].redditURL { NSWorkspace.shared.open(u) }
            return .handled
        }
    }

    @ViewBuilder private func media(_ item: MediaItem) -> some View {
        switch item.kind {
        case .image:
            AsyncImage(url: item.full) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    // Show the thumbnail while the full image loads.
                    AsyncImage(url: item.thumb) { p in
                        if case .success(let t) = p { t.resizable().scaledToFit() } else { ProgressView() }
                    }
                }
            }
        case .gif:
            LoopingVideo(url: item.full, fill: false)
        case .video:
            VideoWithSound(item: item)
        }
    }

    private func infoBar(_ item: MediaItem) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(item.subreddit).bold()
                Text(item.title).lineLimit(1)
                Spacer()
                Text("\(index + 1) / \(feed.items.count)").monospacedDigit().foregroundStyle(.white.opacity(0.7))
                if let u = item.redditURL { Link("Open on Reddit", destination: u) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.7))
        }
    }

    private var edgeButtons: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.title) }
                .disabled(index == 0)
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right").font(.title) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 14)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 14) {
                Button { app.viewer = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .help("Close (Esc)")
                Text("← → browse · I info · O open on Reddit · Esc close")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            .padding(14)
        }
    }

    private func step(_ d: Int) {
        guard var v = app.viewer else { return }
        let next = v.index + d
        guard next >= 0, next < feed.items.count else { return }
        v.index = next
        app.viewer = v
        if next >= feed.items.count - 6 { Task { await feed.loadMore(app.client) } }
    }
}

// MARK: - Setup and settings

struct SetupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Multitab to Reddit").font(.title2.bold())
            Text("Reddit only lets apps read posts with your own free app key. It takes about two minutes:")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open reddit.com/prefs/apps while signed in, and click “create another app”.")
                Text("2. Pick the type **script**, any name, and redirect URI http://localhost:8787")
                Text("3. Copy the ID under the app's name and the secret into Settings.")
            }
            HStack {
                Link("Open reddit.com/prefs/apps", destination: URL(string: "https://www.reddit.com/prefs/apps")!)
                Spacer()
                Button("Open Settings") { app.showSettings = true }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 520)
        .padding(28)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Reddit app") {
                TextField("App ID", text: $app.draft.clientId)
                SecureField("Secret", text: $app.draft.clientSecret)
                Link("Create one at reddit.com/prefs/apps (type: script)", destination: URL(string: "https://www.reddit.com/prefs/apps")!)
                    .font(.caption)
            }
            Section {
                TextField("Username", text: $app.draft.username)
                SecureField("Password", text: $app.draft.password)
            } header: {
                Text("Your account (optional)")
            } footer: {
                Text("Only needed for your Home feed. Doesn't work with two-factor auth. Saved only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Viewing") {
                Toggle("Blur NSFW until clicked", isOn: $app.blurNSFW)
            }
            if let status = app.settingsStatus {
                Text(status).font(.callout).foregroundStyle(status.hasPrefix("Connected") ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(app.settingsWorking ? "Connecting…" : "Save & Connect") { Task { await saveAndTest() } }
                    .disabled(app.settingsWorking || app.draft.clientId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { app.draft = app.creds; app.settingsStatus = nil }
    }

    private func saveAndTest() async {
        app.settingsWorking = true
        defer { app.settingsWorking = false }
        do {
            try await app.updateCredentials(app.draft)
            _ = try await app.client.listing(path: "/r/pics/hot", query: ["limit": "1"])
            app.settingsStatus = "Connected. You're all set."
        } catch {
            app.settingsStatus = error.localizedDescription
        }
    }
}

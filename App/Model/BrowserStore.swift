import SwiftUI
import WebKit

/// Tabs, opened folders, recents, and their persistence.
@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: UUID?
    @Published private(set) var roots: [Root] = []
    @Published private(set) var recents: [Recent] = []
    /// Shown as a HUD while files are being copied in.
    @Published var busy: String?
    /// One-off message for the user (download saved, something failed).
    @Published var notice: String?

    static let maxLiveWebViews = 6
    private let server = LocalServer.shared
    private var resolved: [String: URL] = [:]
    private var saveWork: DispatchWorkItem?

    var active: Tab? { tabs.first { $0.id == activeID } }

    init() {
        var state = AppState()
        if let data = try? Data(contentsOf: AppDirs.stateFile), let saved = try? JSONDecoder().decode(AppState.self, from: data) { state = saved }
        roots = state.roots
        recents = state.recents
        if !roots.contains(where: { $0.kind == .library }) {
            roots.insert(Root(id: AppDirs.token(), kind: .library, name: "On My iPhone"), at: 0)
        }
        server.start()
        for id in roots.map(\.id) { prepare(root: id) }
        tabs = state.tabs.map { Tab(saved: $0, store: self) }
        if tabs.isEmpty { tabs = [Tab(saved: SavedTab(id: UUID(), title: "", location: .start), store: self)] }
        activeID = tabs.contains { $0.id == state.active } ? state.active : tabs.last?.id
        active?.activate()
        writeWelcomeNote()
    }

    // MARK: Addresses

    func url(for location: Location) -> URL? {
        switch location {
        case .start: return nil
        case .web(let text): return URL(string: text)
        case .local(let root, let path): return server.url(token: root, path: path)
        }
    }
    func location(for url: URL) -> Location {
        if url.host == "127.0.0.1", url.scheme == "http" {
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let token = parts.first, roots.contains(where: { $0.id == token }) {
                var path = parts.dropFirst().joined(separator: "/")
                if url.path.hasSuffix("/"), !path.isEmpty { path += "/" }
                return .local(root: token, path: path)
            }
        }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            for root in roots {
                guard let folder = directory(of: root)?.standardizedFileURL.path, path.hasPrefix(folder + "/") else { continue }
                return .local(root: root.id, path: String(path.dropFirst(folder.count + 1)))
            }
        }
        return .web(url.absoluteString)
    }
    func folder(root id: String) -> URL? { roots.first { $0.id == id }.flatMap { directory(of: $0) } }
    /// Turns what the user typed into an address: a URL, a bare domain, or a web search.
    nonisolated static func location(typed text: String) -> Location? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil { return .web(url.absoluteString) }
        let looksLikeHost = !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.hasPrefix("localhost")) && !trimmed.hasSuffix(".")
        if looksLikeHost, let url = URL(string: "https://" + trimmed), url.host != nil { return .web(url.absoluteString) }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url.map { .web($0.absoluteString) }
    }

    // MARK: Roots

    func directory(of root: Root) -> URL? {
        switch root.kind {
        case .library: return AppDirs.documents
        case .imported: return AppDirs.opened.appendingPathComponent(root.id)
        case .folder: return resolved[root.id]
        }
    }
    /// Makes the root's folder reachable through the server. False if it cannot be found any more.
    @discardableResult
    func prepare(root id: String) -> Bool {
        guard let index = roots.firstIndex(where: { $0.id == id }) else { return false }
        let root = roots[index]
        if root.kind == .folder, resolved[id] == nil {
            guard let bookmark = root.bookmark else { return false }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return false }
            guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else { return false }
            if stale, let fresh = try? url.bookmarkData() { roots[index].bookmark = fresh; scheduleSave() }
            resolved[id] = url
        }
        guard let folder = directory(of: root), FileManager.default.fileExists(atPath: folder.path) else { return false }
        server.register(token: id, directory: folder)
        return true
    }
    func removeRoot(_ root: Root) {
        guard root.kind != .library else { return }
        for tab in tabs { if case .local(let id, _) = tab.location, id == root.id { tab.load(.start) } }
        recents.removeAll { $0.root == root.id }
        forget(root)
        scheduleSave()
    }
    private func forget(_ root: Root) {
        server.unregister(token: root.id)
        if let url = resolved.removeValue(forKey: root.id) { url.stopAccessingSecurityScopedResource() }
        if root.kind == .imported { try? FileManager.default.removeItem(at: AppDirs.opened.appendingPathComponent(root.id)) }
        roots.removeAll { $0.id == root.id }
    }
    /// Drops private copies that no tab or recent item points at any more.
    private func pruneImports() {
        var used = Set(recents.map(\.root))
        for tab in tabs { if case .local(let id, _) = tab.location { used.insert(id) } }
        for root in roots where root.kind == .imported && !used.contains(root.id) { forget(root) }
    }

    // MARK: Opening

    /// Opens files picked in Files (or sent from another app). They are copied into a private folder together, so
    /// a page picked along with its images, scripts and videos finds them.
    func open(files: [URL]) {
        guard !files.isEmpty else { return }
        let id = AppDirs.token()
        let folder = AppDirs.opened.appendingPathComponent(id)
        busy = files.count == 1 ? "Opening \(files[0].lastPathComponent)…" : "Opening \(files.count) files…"
        Task.detached(priority: .userInitiated) {
            var copied: [String] = [], sources: [String: Data] = [:], problem: String?
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &coordinationError) { readable in
                    let target = AppDirs.freeName(readable.lastPathComponent, in: folder)
                    do {
                        try FileManager.default.copyItem(at: readable, to: target)
                        copied.append(target.lastPathComponent)
                        if let bookmark = try? file.bookmarkData() { sources[target.lastPathComponent] = bookmark }
                    } catch { problem = error.localizedDescription }
                }
                if let coordinationError { problem = coordinationError.localizedDescription }
            }
            let names = copied, bookmarks = sources, failure = problem
            await MainActor.run { self.finishOpening(id: id, names: names, sources: bookmarks, problem: failure) }
        }
    }
    private func finishOpening(id: String, names: [String], sources: [String: Data], problem: String?) {
        busy = nil
        guard !names.isEmpty else {
            try? FileManager.default.removeItem(at: AppDirs.opened.appendingPathComponent(id))
            notice = "That file could not be opened" + (problem.map { ": \($0)" } ?? ".")
            return
        }
        let pages = names.filter { PageKind.isPage(URL(fileURLWithPath: $0)) }
        let title = names.count == 1 ? names[0] : (pages.first ?? names[0])
        roots.append(Root(id: id, kind: .imported, name: title, sources: sources))
        prepare(root: id)
        // A page picked with its assets opens as one tab; several pages open one tab each.
        let toOpen = pages.isEmpty ? Array(names.prefix(8)) : Array(pages.prefix(8))
        for (index, name) in toOpen.enumerated() { show(.local(root: id, path: name), newTab: index > 0) }
        if let problem { notice = "Some files could not be copied: \(problem)" }
        scheduleSave()
    }
    /// Opens a folder picked in Files in place (nothing is copied), so everything inside it is available.
    func open(folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        guard let bookmark = try? folder.bookmarkData() else {
            if scoped { folder.stopAccessingSecurityScopedResource() }
            notice = "That folder could not be opened."; return
        }
        // The same folder picked again reuses its entry.
        for id in roots.filter({ $0.kind == .folder }).map(\.id) where prepare(root: id) && resolved[id]?.standardizedFileURL == folder.standardizedFileURL {
            if scoped { folder.stopAccessingSecurityScopedResource() }
            show(.local(root: id, path: entryPath(in: folder)), newTab: false); return
        }
        let root = Root(id: AppDirs.token(), kind: .folder, name: folder.lastPathComponent, bookmark: bookmark)
        roots.append(root); resolved[root.id] = folder
        prepare(root: root.id)
        show(.local(root: root.id, path: entryPath(in: folder)), newTab: false)
        scheduleSave()
    }
    private func entryPath(in folder: URL) -> String {
        for name in ["index.html", "index.htm"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
        return ""
    }
    /// Shows `location` in the current tab if it is an empty new tab, otherwise (or if `newTab`) in a new one.
    func show(_ location: Location, newTab: Bool) {
        if !newTab, let active, active.isStart { active.load(location); limitLiveWebViews(); return }
        let tab = Tab(saved: SavedTab(id: UUID(), title: "", location: .start), store: self)
        tabs.append(tab); select(tab)
        tab.load(location)
        limitLiveWebViews()
    }
    /// Re-copies an individually opened file if its original in Files changed since it was copied.
    func refreshFromOriginal(root id: String, path: String) {
        guard let root = roots.first(where: { $0.id == id }), root.kind == .imported, let bookmark = root.sources?[path] else { return }
        var stale = false
        guard let original = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
        let scoped = original.startAccessingSecurityScopedResource()
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
        let copy = AppDirs.opened.appendingPathComponent(id).appendingPathComponent(path)
        let newer = (try? original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let have = (try? copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard newer > have else { return }
        let temporary = copy.deletingLastPathComponent().appendingPathComponent(".refresh-" + UUID().uuidString)
        if (try? FileManager.default.copyItem(at: original, to: temporary)) != nil {
            _ = try? FileManager.default.replaceItemAt(copy, withItemAt: temporary)
        }
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Tabs

    func newTab() { let tab = Tab(saved: SavedTab(id: UUID(), title: "", location: .start), store: self); tabs.append(tab); select(tab) }
    func select(_ tab: Tab) {
        if let current = active, current.id != tab.id { current.capture() }
        activeID = tab.id
        tab.activate()
        limitLiveWebViews()
        scheduleSave()
    }
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.hibernate()
        try? FileManager.default.removeItem(at: tab.snapshotFile)
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [Tab(saved: SavedTab(id: UUID(), title: "", location: .start), store: self)] }
        if activeID == tab.id { let next = tabs[min(index, tabs.count - 1)]; activeID = next.id; next.activate() }
        pruneImports(); scheduleSave()
    }
    func closeAll() {
        for tab in tabs { tab.hibernate(); try? FileManager.default.removeItem(at: tab.snapshotFile) }
        let tab = Tab(saved: SavedTab(id: UUID(), title: "", location: .start), store: self)
        tabs = [tab]; activeID = tab.id
        pruneImports(); scheduleSave()
    }
    func openPopup(from opener: Tab, configuration: WKWebViewConfiguration) -> WKWebView? {
        let tab = Tab(saved: SavedTab(id: UUID(), title: "", location: .start, zoom: opener.zoom, desktop: opener.desktop), store: self)
        let view = tab.adopt(configuration: configuration)
        let index = tabs.firstIndex { $0.id == opener.id }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        opener.capture()
        activeID = tab.id; tab.lastUsed = Date()
        limitLiveWebViews(); scheduleSave()
        return view
    }
    /// Keeps only the most recently used tabs loaded in memory.
    private func limitLiveWebViews() {
        let live = tabs.filter { $0.webView != nil && $0.id != activeID }.sorted { $0.lastUsed > $1.lastUsed }
        for tab in live.dropFirst(Self.maxLiveWebViews - 1) { tab.hibernate() }
    }
    func memoryWarning() { for tab in tabs where tab.id != activeID { tab.hibernate() } }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        if #available(iOS 15.4, *) { configuration.preferences.isElementFullscreenEnabled = true }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    // MARK: Recents

    func noteVisit(_ tab: Tab) {
        guard case .local(let root, let path) = tab.location, !path.isEmpty, !path.hasSuffix("/") else { return }
        let item = Recent(root: root, path: path, title: tab.displayTitle, date: Date())
        if let first = recents.first, first.id == item.id, first.title == item.title { return }
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
    }
    func removeRecent(_ item: Recent) { recents.removeAll { $0.id == item.id }; pruneImports(); scheduleSave() }
    func clearRecents() { recents = []; pruneImports(); scheduleSave() }

    // MARK: Server and persistence

    /// Called when a local page fails to connect. True if the server is running again.
    func reviveServer() -> Bool {
        let ok = server.restart()
        for id in roots.map(\.id) { prepare(root: id) }
        return ok
    }
    /// The system closes the listening socket while the app is suspended; check it when the app comes back.
    func becameActive() {
        let port = server.port
        guard port != 0, let probe = URL(string: "http://127.0.0.1:\(port)/alive") else { _ = reviveServer(); return }
        var request = URLRequest(url: probe, timeoutInterval: 1.5); request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if response == nil { Task { @MainActor in _ = self.reviveServer() } }
        }.resume()
    }
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        let state = AppState(tabs: tabs.map { $0.export() }, active: activeID, roots: roots, recents: recents)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: AppDirs.stateFile, options: .atomic)
    }
    func enteredBackground() { active?.capture(); saveNow() }

    private func writeWelcomeNote() {
        let note = AppDirs.documents.appendingPathComponent("Put HTML files and folders here.txt")
        guard !UserDefaults.standard.bool(forKey: "wroteWelcomeNote") else { return }
        UserDefaults.standard.set(true, forKey: "wroteWelcomeNote")
        try? "Anything you copy into this folder in the Files app shows up in HTML Viewer under Places.\nCopy a whole website folder here and its pages, images, scripts and videos all work.\n".write(to: note, atomically: true, encoding: .utf8)
    }
}

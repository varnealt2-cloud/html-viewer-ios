import SwiftUI
import WebKit

/// One browser tab. The web view is created only when the tab is first shown and may be released while the tab is
/// in the background (its history is kept), so many tabs stay cheap.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    unowned let store: BrowserStore

    @Published var title: String
    @Published var location: Location
    @Published var displayURL: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var failure: String?
    @Published var snapshot: UIImage?
    @Published var desktop: Bool
    @Published var zoom: Double
    /// Bumped whenever `webView` is created or released so the container view re-attaches.
    @Published var webViewGeneration = 0

    private(set) var webView: WKWebView?
    private var history: Data?
    private var historyPort: UInt16?
    private var observers: [NSKeyValueObservation] = []
    private var retriedAfterServerRestart = false
    private var downloads: [WKDownload: URL] = [:]
    var lastUsed = Date()

    init(saved: SavedTab, store: BrowserStore) {
        id = saved.id; self.store = store
        title = saved.title; location = saved.location
        history = saved.history; historyPort = saved.port
        desktop = saved.desktop ?? false; zoom = saved.zoom ?? 1
        super.init()
        snapshot = UIImage(contentsOfFile: snapshotFile.path)
    }

    var isStart: Bool { location == .start && webView == nil }
    var snapshotFile: URL { AppDirs.snapshots.appendingPathComponent(id.uuidString + ".jpg") }

    var displayTitle: String {
        if !title.isEmpty { return title }
        switch location {
        case .start: return "New Tab"
        case .local(_, let path): return (path as NSString).lastPathComponent.isEmpty ? "Folder" : (path as NSString).lastPathComponent
        case .web(let text): return URL(string: text)?.host ?? text
        }
    }
    /// Short text for the address pill.
    var addressText: String {
        switch location {
        case .start: return "Open a file or enter an address"
        case .local(let root, let path):
            let entry = store.roots.first { $0.id == root }
            let name = entry?.kind == .library ? Device.onMy : (entry?.name ?? "Files")
            if entry?.kind == .imported { return path.isEmpty ? name : path }
            return path.isEmpty ? name : name + "/" + path
        case .web(let text):
            guard let url = URL(string: text), let host = url.host else { return text }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }
    var isLocal: Bool { if case .local = location { return true }; return false }
    var isSecureWeb: Bool { if case .web(let text) = location { return text.hasPrefix("https://") }; return false }

    func export() -> SavedTab {
        if let webView {
            if let data = webView.interactionState as? Data { history = data; historyPort = LocalServer.shared.port }
        }
        return SavedTab(id: id, title: title, location: location, history: history, port: historyPort, zoom: zoom, desktop: desktop)
    }

    // MARK: Web view life cycle

    /// Creates the web view if needed and restores where the tab was.
    func activate() {
        lastUsed = Date()
        guard webView == nil, location != .start else { return }
        let view = makeWebView(configuration: store.makeConfiguration())
        if let history, historyPort == LocalServer.shared.port {
            view.interactionState = history
            if view.url == nil { loadCurrentLocation() }
        } else { loadCurrentLocation() }
    }
    /// Frees the web view of a background tab, keeping its history and snapshot.
    func hibernate() {
        guard let webView else { return }
        if let data = webView.interactionState as? Data { history = data; historyPort = LocalServer.shared.port }
        observers.removeAll()
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.stopLoading(); webView.removeFromSuperview()
        self.webView = nil; isLoading = false; webViewGeneration += 1
    }
    /// Used for window.open / target=_blank: WebKit requires the new view to be built from its configuration.
    func adopt(configuration: WKWebViewConfiguration) -> WKWebView { makeWebView(configuration: configuration) }

    @discardableResult
    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        if #available(iOS 16.0, *) { view.isFindInteractionEnabled = true }
        if #available(iOS 16.4, *) { view.isInspectable = true }
        view.scrollView.keyboardDismissMode = .interactive
        view.isOpaque = false; view.backgroundColor = .systemBackground
        view.pageZoom = zoom
        applyDesktop(to: view)
        observers = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.titleChanged(view.title) } },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.urlChanged(view.url) } },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
        ]
        webView = view; webViewGeneration += 1
        return view
    }
    private func applyDesktop(to view: WKWebView) {
        view.customUserAgent = desktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" : nil
    }

    private func titleChanged(_ new: String?) {
        guard let new, !new.isEmpty, new != title else { return }
        title = new; store.noteVisit(self); store.scheduleSave()
    }
    private func urlChanged(_ url: URL?) {
        guard let url, url.scheme != "about" else { return }
        displayURL = url
        let new = store.location(for: url)
        if new != location { location = new; title = webView?.title ?? ""; store.scheduleSave() }
    }

    // MARK: Navigation

    func load(_ target: Location) {
        failure = nil; retriedAfterServerRestart = false
        location = target; title = ""
        if target == .start { hibernate(); history = nil; store.scheduleSave(); return }
        if webView == nil { makeWebView(configuration: store.makeConfiguration()) }
        loadCurrentLocation()
        store.scheduleSave()
    }
    private func loadCurrentLocation() {
        guard let webView else { return }
        if case .local(let root, _) = location, !store.prepare(root: root) {
            failure = "This page's folder is not available any more. Open it again from Files."
            return
        }
        failure = nil
        if case .local(let root, let path) = location, !LocalServer.shared.isRunning, !LocalServer.shared.start() {
            // Without the local server, show the file directly; self-contained pages work the same.
            if let folder = store.folder(root: root) {
                LocalServer.shared.note("server unavailable; opening \(path) as a file")
                webView.loadFileURL(folder.appendingPathComponent(path), allowingReadAccessTo: folder); return
            }
        }
        guard let url = store.url(for: location) else { failure = "This address could not be opened."; return }
        webView.load(URLRequest(url: url))
    }
    func reload() {
        failure = nil; retriedAfterServerRestart = false
        guard let webView else { activate(); return }
        if case .local(let root, let path) = location { store.refreshFromOriginal(root: root, path: path) }
        // After a failed load the web view has no page to reload, so load the address again.
        if webView.url == nil || store.location(for: webView.url!) != location { loadCurrentLocation() } else { webView.reloadFromOrigin() }
    }
    func stop() { webView?.stopLoading() }
    func goBack() { failure = nil; webView?.goBack() }
    func goForward() { failure = nil; webView?.goForward() }
    func find() { if #available(iOS 16.0, *) { webView?.findInteraction?.presentFindNavigator(showingReplace: false) } }
    func setZoom(_ value: Double) { zoom = min(3, max(0.5, value)); webView?.pageZoom = zoom; store.scheduleSave() }
    func toggleDesktop() {
        desktop.toggle()
        if let webView { applyDesktop(to: webView); webView.reloadFromOrigin() }
        store.scheduleSave()
    }
    func source() async -> String {
        guard let webView else { return "" }
        return (try? await webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") as? String) ?? ""
    }

    /// Updates the thumbnail used in the tab overview.
    func capture(completion: (() -> Void)? = nil) {
        guard let webView, webView.window != nil, webView.bounds.width > 0 else { completion?(); return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: 360)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let self, let image {
                self.snapshot = image
                let file = self.snapshotFile
                DispatchQueue.global(qos: .utility).async { try? image.jpegData(compressionQuality: 0.7)?.write(to: file, options: .atomic) }
            }
            completion?()
        }
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // mailto:, tel:, maps and app links belong to other apps.
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences); return
        }
        if action.shouldPerformDownload { decisionHandler(.download, preferences); return }
        decisionHandler(.allow, preferences)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failure = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retriedAfterServerRestart = false
        if let url = webView.url { urlChanged(url) }
        store.noteVisit(self); store.scheduleSave()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.capture() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    private func failed(_ error: Error) {
        let e = error as NSError
        // -999: replaced by a newer navigation. 102: the response became a download. 204: handed to the media player.
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204)) { return }
        if isLocal, !retriedAfterServerRestart {
            // The local server stops while the app is suspended; bring it back and try once more.
            retriedAfterServerRestart = true
            LocalServer.shared.note("page failed: \(e.domain) \(e.code) \(e.localizedDescription)")
            if store.reviveServer() { loadCurrentLocation(); return }
            if case .local(let root, let path) = location, let folder = store.folder(root: root), let webView {
                webView.loadFileURL(folder.appendingPathComponent(path), allowingReadAccessTo: folder); return
            }
        }
        failure = e.localizedDescription + (isLocal ? "\n\n" + LocalServer.shared.diagnostics.split(separator: "\n").suffix(4).joined(separator: "\n") : "")
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        store.openPopup(from: self, configuration: configuration)
    }
    func webViewDidClose(_ webView: WKWebView) { store.close(self) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        Self.present(alert) { completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        Self.present(alert) { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text ?? "") })
        Self.present(alert) { completionHandler(nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    /// Presents on the frontmost view controller; `unavailable` runs if nothing can present (the page must get an answer).
    static func present(_ controller: UIViewController, unavailable: () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        guard let top else { unavailable(); return }
        // On iPad, share sheets are popovers and must be anchored (here: above the toolbar's share button).
        if let popover = controller.popoverPresentationController, popover.sourceView == nil, popover.barButtonItem == nil {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - top.view.safeAreaInsets.bottom - 40, width: 1, height: 1)
            popover.permittedArrowDirections = [.down, .up]
        }
        top.present(controller, animated: true)
    }
}

// MARK: - Downloads

extension Tab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        try? FileManager.default.createDirectory(at: AppDirs.downloads, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let target = AppDirs.freeName(name, in: AppDirs.downloads)
        downloads[download] = target
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let file = downloads.removeValue(forKey: download) {
            store.notice = "Saved “\(file.lastPathComponent)” to Downloads. Find it in Files → \(Device.onMy) → HTML Viewer → Downloads."
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        store.notice = "The download failed: \(error.localizedDescription)"
    }
}

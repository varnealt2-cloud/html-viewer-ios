import XCTest
import WebKit
import AVFoundation
@testable import HTMLViewer

final class ViewerTests: XCTestCase {
    private var folder: URL!
    private var token: String!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("site-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        token = AppDirs.token()
        XCTAssertTrue(LocalServer.shared.start(), "The local server must start")
        LocalServer.shared.register(token: token, directory: folder)
    }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { print("SERVER port \(LocalServer.shared.port) running \(LocalServer.shared.isRunning)\n" + LocalServer.shared.diagnostics) }
        LocalServer.shared.unregister(token: token)
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ data: Data) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    private func request(_ path: String, method: String = "GET", range: String? = nil, raw: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let url = raw ? URL(string: "http://127.0.0.1:\(LocalServer.shared.port)/\(path)")! : LocalServer.shared.url(token: token, path: path)!
        var request = URLRequest(url: url); request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        let (data, response) = try await URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil).data(for: request)
        return (data, response as! HTTPURLResponse)
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    func testServerServesFilesRangesAndListings() async throws {
        let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
        try write("big.bin", bytes)
        try write("sub folder/päge ü.html", Data("<!doctype html><title>t</title>héllo".utf8))
        try write("latin.html", Data([0x3C, 0x70, 0x3E, 0xE9, 0x3C, 0x2F, 0x70, 0x3E]))   // <p>é</p> in Latin-1
        try write("noext", Data("<h1>x</h1>".utf8))

        var (data, response) = try await request("big.bin")
        XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(data, bytes)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")

        (data, response) = try await request("big.bin", range: "bytes=10-19")
        XCTAssertEqual(response.statusCode, 206); XCTAssertEqual(data, bytes.subdata(in: 10..<20))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/600000")
        (data, response) = try await request("big.bin", range: "bytes=599990-")
        XCTAssertEqual(response.statusCode, 206); XCTAssertEqual(data, bytes.suffix(10))
        (data, response) = try await request("big.bin", range: "bytes=-5")
        XCTAssertEqual(data, bytes.suffix(5))
        (_, response) = try await request("big.bin", range: "bytes=600000-")
        XCTAssertEqual(response.statusCode, 416)

        (data, response) = try await request("big.bin", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200); XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "600000")

        (data, response) = try await request("sub folder/päge ü.html")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("héllo"))
        (_, response) = try await request("latin.html")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html", "Non-UTF-8 pages keep their own encoding")
        (_, response) = try await request("noext")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")

        (_, response) = try await request("sub folder")
        XCTAssertEqual(response.statusCode, 301)
        (data, response) = try await request("sub folder/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("päge ü.html"), "Folders without an index page list their files")

        (_, response) = try await request("missing.html")
        XCTAssertEqual(response.statusCode, 404)
        (_, response) = try await request("\(token!)/%2e%2e/%2e%2e/etc/hosts", raw: true)
        XCTAssertTrue([403, 404].contains(response.statusCode), "Nothing outside the opened folder is reachable")
        XCTAssertEqual(LocalServer.shared.respond(method: "GET", target: "/\(token!)/../../etc/hosts", headers: [:]).status, 403)
        XCTAssertEqual(LocalServer.shared.respond(method: "GET", target: "/\(token!)/%2e%2e/x", headers: [:]).status, 403)
        (_, response) = try await request("not-a-token/big.bin", raw: true)
        XCTAssertEqual(response.statusCode, 404)
        (_, response) = try await request("big.bin", method: "POST")
        XCTAssertEqual(response.statusCode, 405)
    }

    func testRangeParser() {
        XCTAssertEqual(LocalServer.parseRange("bytes=0-0", size: 10), 0...0)
        XCTAssertEqual(LocalServer.parseRange("bytes=5-", size: 10), 5...9)
        XCTAssertEqual(LocalServer.parseRange("bytes=5-100", size: 10), 5...9)
        XCTAssertEqual(LocalServer.parseRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(LocalServer.parseRange("bytes=-30", size: 10), 0...9)
        XCTAssertNil(LocalServer.parseRange("bytes=10-", size: 10))
        XCTAssertNil(LocalServer.parseRange("bytes=7-3", size: 10))
        XCTAssertNil(LocalServer.parseRange("items=1-2", size: 10))
    }

    func testTypedAddresses() {
        XCTAssertEqual(BrowserStore.location(typed: "https://example.com/a?b=1"), .web("https://example.com/a?b=1"))
        XCTAssertEqual(BrowserStore.location(typed: " example.com "), .web("https://example.com"))
        XCTAssertEqual(BrowserStore.location(typed: "how to center a div"), .web("https://duckduckgo.com/?q=how%20to%20center%20a%20div"))
        XCTAssertNil(BrowserStore.location(typed: "   "))
    }

    func testStateRoundTrips() throws {
        let state = AppState(tabs: [SavedTab(id: UUID(), title: "A", location: .local(root: "abc", path: "x/y.html"), history: Data([1, 2]), port: 47821, zoom: 1.2, desktop: true),
                                    SavedTab(id: UUID(), title: "", location: .web("https://example.com")), SavedTab(id: UUID(), title: "", location: .start)],
                             active: nil, roots: [Root(id: "abc", kind: .folder, name: "Site", bookmark: Data([9]))],
                             recents: [Recent(root: "abc", path: "x/y.html", title: "A", date: Date(timeIntervalSince1970: 5))])
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.tabs.map(\.location), state.tabs.map(\.location))
        XCTAssertEqual(back.tabs[0].history, Data([1, 2])); XCTAssertEqual(back.roots, state.roots); XCTAssertEqual(back.recents, state.recents)
    }

    /// A real page in a real web view: stylesheet, image, ES module, fetch, local storage, and a video that loads
    /// and seeks, all through the local server.
    @MainActor
    func testPageLoadsStylesScriptsFetchImagesAndVideo() async throws {
        try await makeVideo(at: folder.appendingPathComponent("media/clip.mp4"))
        try write("style.css", Data("main { max-width: 321px; }".utf8))
        try write("lib.js", Data("export const value = 42;".utf8))
        try write("data.json", Data("{\"ok\":true}".utf8))
        try write("pic.svg", Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\"/></svg>".utf8))
        try write("index.html", Data("""
        <!doctype html><meta charset="utf-8"><title>Test page</title><link rel="stylesheet" href="style.css">
        <main><img id="pic" src="pic.svg"><video id="clip" src="media/clip.mp4" muted playsinline preload="auto"></video></main>
        <script type="module">
        import { value } from "./lib.js";
        const out = { module: value === 42 };
        const done = () => window.webkit.messageHandlers.result.postMessage(JSON.stringify(out));
        try {
          out.css = getComputedStyle(document.querySelector("main")).maxWidth === "321px";
          const pic = document.getElementById("pic");
          await new Promise(r => pic.complete ? r() : (pic.onload = pic.onerror = r));
          out.image = pic.naturalWidth === 8;
          out.fetch = (await (await fetch("data.json")).json()).ok === true;
          localStorage.setItem("k", "v"); out.storage = localStorage.getItem("k") === "v";
          const clip = document.getElementById("clip");
          const within = (name, promise) => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(
            name + " timed out; readyState=" + clip.readyState + " networkState=" + clip.networkState + " error=" + (clip.error && clip.error.code))), 20000))]);
          clip.play().catch(() => {});
          await within("video load", new Promise((resolve, reject) => {
            if (clip.readyState >= 2) return resolve();
            clip.onloadeddata = resolve; clip.onerror = () => reject(new Error("video error " + (clip.error && clip.error.code)));
          }));
          out.videoLoaded = clip.videoWidth === 64 && clip.duration > 1;
          clip.pause();
          await within("video seek", new Promise((resolve, reject) => { clip.onseeked = resolve; clip.onerror = reject; clip.currentTime = clip.duration * 0.8; }));
          out.videoSeeked = clip.currentTime > 1;
        } catch (e) { out.error = String(e); }
        done();
        </script>
        """.utf8))

        let receiver = Receiver()
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(receiver, name: "result")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first
        window?.addSubview(view)
        defer { view.removeFromSuperview() }
        view.load(URLRequest(url: LocalServer.shared.url(token: token, path: "index.html")!))

        let deadline = Date().addingTimeInterval(60)
        while receiver.json == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let json = try XCTUnwrap(receiver.json, "The page never reported back")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(result["error"], "Page error: \(result["error"] ?? "")")
        for key in ["module", "css", "image", "fetch", "storage", "videoLoaded", "videoSeeked"] {
            XCTAssertEqual(result[key] as? Bool, true, "\(key) failed: \(json)")
        }
        XCTAssertEqual(view.title, "Test page")
    }

    /// Opening a file the way the Files picker hands it over, then restoring the tab after a relaunch.
    @MainActor
    func testOpenedFileBecomesATabAndIsRestored() async throws {
        try write("picked page.html", Data("<!doctype html><title>Picked</title><p>hi</p>".utf8))
        try write("picked.css", Data("p{color:red}".utf8))
        let store = BrowserStore()
        let before = store.tabs.count
        store.open(files: [folder.appendingPathComponent("picked page.html"), folder.appendingPathComponent("picked.css")])
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !(store.active?.title == "Picked" && store.active?.isLoading == false) { try await Task.sleep(nanoseconds: 100_000_000) }
        let tab = try XCTUnwrap(store.active)
        XCTAssertEqual(tab.title, "Picked")
        guard case .local(let root, let path) = tab.location else { return XCTFail("Not a local page: \(tab.location)") }
        XCTAssertEqual(path, "picked page.html")
        XCTAssertLessThanOrEqual(store.tabs.count, before + 1, "The stylesheet picked with the page does not get its own tab")
        let copies = try FileManager.default.contentsOfDirectory(atPath: AppDirs.opened.appendingPathComponent(root).path).sorted()
        XCTAssertEqual(copies, ["picked page.html", "picked.css"])
        XCTAssertEqual(store.recents.first?.title, "Picked")
        store.saveNow()

        let relaunched = BrowserStore()
        let restored = try XCTUnwrap(relaunched.tabs.first { $0.id == tab.id }, "The tab is saved")
        XCTAssertEqual(restored.location, tab.location); XCTAssertEqual(restored.title, "Picked")
        XCTAssertEqual(relaunched.activeID, tab.id)
        let reload = Date().addingTimeInterval(30)
        while Date() < reload, restored.webView?.title != "Picked" { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(restored.webView?.title, "Picked", "The restored tab loads its page again")

        relaunched.close(restored); relaunched.clearRecents()
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppDirs.opened.appendingPathComponent(root).path), "Closed pages do not leave copies behind")
        relaunched.saveNow()
    }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        var json: String?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { json = message.body as? String }
    }

    /// Writes a 2-second 64×64 H.264 clip.
    private func makeVideo(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 4), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}

import Foundation
import Network
import UniformTypeIdentifiers

/// A small HTTP server bound to 127.0.0.1 that serves the folders the user opened.
///
/// Local pages are loaded through it rather than as file:// URLs, so everything a page can do on a real website
/// works: relative images/CSS/JS, fetch() and XMLHttpRequest, ES modules, web workers, and video/audio seeking
/// (byte ranges). Every folder is reachable only under an unguessable token: http://127.0.0.1:PORT/TOKEN/path.
final class LocalServer {
    static let shared = LocalServer()
    static let preferredPort: UInt16 = 47821

    private let lock = NSLock()
    private var roots: [String: URL] = [:]
    private var listener: NWListener?
    private var ready = false
    private var currentPort: UInt16 = 0
    private let acceptQueue = DispatchQueue(label: "LocalServer.accept")
    private var connections: [ObjectIdentifier: AnyObject] = [:]
    private var notes: [String] = []

    /// Recent server events, for diagnosing a page that will not load.
    var diagnostics: String { lock.lock(); defer { lock.unlock() }; return notes.joined(separator: "\n") }
    func note(_ text: String) {
        lock.lock(); notes.append(text); if notes.count > 200 { notes.removeFirst(notes.count - 200) }; lock.unlock()
    }
    fileprivate func ended(_ connection: AnyObject) {
        lock.lock(); connections[ObjectIdentifier(connection)] = nil; lock.unlock()
    }

    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return currentPort }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func register(token: String, directory: URL) {
        lock.lock(); roots[token] = directory.standardizedFileURL; lock.unlock()
    }
    func unregister(token: String) { lock.lock(); roots[token] = nil; lock.unlock() }
    func directory(for token: String) -> URL? { lock.lock(); defer { lock.unlock() }; return roots[token] }

    /// URL of `path` (relative, unescaped) inside the folder registered under `token`.
    func url(token: String, path: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: ";?#")
        let escaped = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
        let trailing = path.hasSuffix("/") && !escaped.isEmpty ? "/" : ""
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(escaped)\(trailing)")
    }

    /// Starts the server if it is not running. Blocks briefly until the port is known. Returns false on failure.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        // The preferred port keeps page addresses (and so each page's saved storage) the same between launches.
        return listen(on: Self.preferredPort) || listen(on: 0)
    }
    func restart() -> Bool {
        lock.lock(); let old = listener; listener = nil; ready = false; lock.unlock()
        old?.cancel()
        return start()
    }

    private func listen(on wanted: UInt16) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        let made: NWListener
        do { made = try NWListener(using: parameters, on: wanted == 0 ? .any : (NWEndpoint.Port(rawValue: wanted) ?? .any)) }
        catch { note("listener for port \(wanted) not created: \(error)"); return false }
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        made.stateUpdateHandler = { [weak self, weak made] state in
            guard let self, let made else { return }
            self.note("listener(\(wanted)) \(state) port=\(made.port?.rawValue ?? 0)")
            switch state {
            case .ready:
                self.lock.lock(); self.listener = made; self.currentPort = made.port?.rawValue ?? 0; self.ready = true; self.lock.unlock()
                if !signalled { signalled = true; done.signal() }
            case .failed, .cancelled:
                self.lock.lock(); if self.listener === made { self.ready = false; self.listener = nil }; self.lock.unlock()
                made.cancel()
                if !signalled { signalled = true; done.signal() }
            default: break
            }
        }
        made.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.note("accepted \(connection.endpoint)")
            let client = Connection(connection, server: self)
            self.lock.lock(); self.connections[ObjectIdentifier(client)] = client; self.lock.unlock()
            client.start()
        }
        made.start(queue: acceptQueue)
        _ = done.wait(timeout: .now() + 3)
        lock.lock(); let ok = ready && listener === made; lock.unlock()
        if !ok { made.cancel() }
        return ok
    }

    // MARK: Request handling

    struct Response {
        var status: Int
        var headers: [(String, String)] = []
        var body: Data = Data()
        var file: (handle: FileHandle, offset: UInt64, length: UInt64)?
    }

    static let reasons = [200: "OK", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 400: "Bad Request",
                          403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 500: "Internal Server Error"]

    func respond(method: String, target: String, headers: [String: String]) -> Response {
        guard method == "GET" || method == "HEAD" else {
            return page(405, "This viewer only reads files.", extra: [("Allow", "GET, HEAD")])
        }
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        guard let decoded = rawPath.removingPercentEncoding else { return page(400, "Bad address.") }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let token = parts.first, let root = directory(for: token) else { return page(404, "This page's folder is not open any more.") }
        let relative = Array(parts.dropFirst())
        if relative.contains("..") || relative.contains(".") { return page(403, "That path is outside the opened folder.") }
        var file = root
        for part in relative { file.appendPathComponent(part) }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return page(404, "There is no file named “\(relative.last ?? "")” here.")
        }
        if isDirectory.boolValue {
            if !decoded.hasSuffix("/") {
                let query = target.contains("?") ? "?" + target.split(separator: "?", maxSplits: 1)[1] : ""
                return Response(status: 301, headers: [("Location", rawPath + "/" + query), ("Content-Length", "0")])
            }
            for index in ["index.html", "index.htm"] {
                let candidate = file.appendingPathComponent(index)
                if manager.fileExists(atPath: candidate.path) { return serve(candidate, method: method, headers: headers) }
            }
            return listing(of: file, title: relative.last ?? root.lastPathComponent, isRoot: relative.isEmpty, method: method)
        }
        return serve(file, method: method, headers: headers)
    }

    private func serve(_ file: URL, method: String, headers: [String: String]) -> Response {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return page(403, "This file could not be opened.") }
        let size = (try? handle.seekToEnd()) ?? 0
        var type = Self.mimeType(for: file)
        if type.hasPrefix("text/") || type == "application/json" || type == "application/xhtml+xml" || type == "image/svg+xml" {
            // Without a declared encoding WebKit assumes Latin-1 over HTTP; almost every file today is UTF-8.
            if size <= 8 << 20, (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd() ?? Data() {
                if !Self.hasUTF16BOM(data), String(data: data, encoding: .utf8) != nil { type += "; charset=utf-8" }
            }
        }
        var common: [(String, String)] = [("Content-Type", type), ("Accept-Ranges", "bytes"), ("Cache-Control", "no-store")]
        var start: UInt64 = 0, length = size, status = 200
        if let range = headers["range"], size > 0 {
            guard let parsed = Self.parseRange(range, size: size) else {
                try? handle.close()
                return Response(status: 416, headers: [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")])
            }
            start = parsed.lowerBound; length = parsed.upperBound - parsed.lowerBound + 1; status = 206
            common.append(("Content-Range", "bytes \(start)-\(parsed.upperBound)/\(size)"))
        }
        common.append(("Content-Length", String(length)))
        if method == "HEAD" { try? handle.close(); return Response(status: status, headers: common) }
        return Response(status: status, headers: common, file: (handle, start, length))
    }

    static func parseRange(_ header: String, size: UInt64) -> ClosedRange<UInt64>? {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.hasPrefix("bytes="), size > 0 else { return nil }
        let first = value.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let bounds = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = UInt64(bounds[1]), suffix > 0 else { return nil }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let lower = UInt64(bounds[0]), lower < size else { return nil }
        if bounds[1].isEmpty { return lower...(size - 1) }
        guard let upper = UInt64(bounds[1]), upper >= lower else { return nil }
        return lower...min(upper, size - 1)
    }

    static func hasUTF16BOM(_ data: Data) -> Bool {
        data.count >= 2 && ((data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE) || (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF))
    }

    private static let knownTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "shtml": "text/html", "xhtml": "application/xhtml+xml", "xht": "application/xhtml+xml",
        "css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript", "json": "application/json",
        "map": "application/json", "webmanifest": "application/manifest+json", "wasm": "application/wasm", "xml": "text/xml",
        "txt": "text/plain", "md": "text/plain", "log": "text/plain", "csv": "text/csv", "vtt": "text/vtt", "srt": "text/plain",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "avif": "image/avif", "heic": "image/heic", "bmp": "image/bmp", "ico": "image/x-icon", "tif": "image/tiff", "tiff": "image/tiff",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm", "ogv": "video/ogg", "m3u8": "application/vnd.apple.mpegurl",
        "ts": "video/mp2t", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg", "oga": "audio/ogg",
        "opus": "audio/ogg", "flac": "audio/flac", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "pdf": "application/pdf", "zip": "application/zip", "glb": "model/gltf-binary", "gltf": "model/gltf+json", "usdz": "model/vnd.usdz+zip",
    ]
    static func mimeType(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        if let known = knownTypes[ext] { return known }
        if ext.isEmpty { return "text/html" }   // "any kind": pages saved without an extension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static let style = """
    <meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
    <style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:20px 18px 40px;background:#fff;color:#111}@media(prefers-color-scheme:dark){body{background:#000;color:#f2f2f2}}
    h1{font-size:22px;margin:8px 0 16px;word-break:break-word}p{opacity:.7;line-height:1.4}
    a{display:flex;gap:12px;align-items:center;padding:13px 4px;border-bottom:1px solid rgba(128,128,128,.28);
    color:inherit;text-decoration:none;word-break:break-word}a:active{opacity:.5}.i{width:26px;text-align:center;flex:none}
    .s{margin-left:auto;opacity:.55;font-size:14px;flex:none;padding-left:10px}</style>
    """
    private func page(_ status: Int, _ message: String, extra: [(String, String)] = []) -> Response {
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(Self.reasons[status] ?? "Error")</title>\(Self.style)</head><body><h1>\(Self.reasons[status] ?? "Error")</h1><p>\(Self.escape(message))</p></body></html>"
        let body = Data(html.utf8)
        return Response(status: status, headers: [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", String(body.count)), ("Cache-Control", "no-store")] + extra, body: body)
    }
    private func listing(of folder: URL, title: String, isRoot: Bool, method: String) -> Response {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .map { url -> (name: String, dir: Bool, size: Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url.lastPathComponent, values?.isDirectory ?? false, values?.fileSize ?? 0)
            }
            .sorted { $0.dir != $1.dir ? $0.dir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: ";?#/")
        var rows = isRoot ? "" : "<a href=\"../\"><span class=\"i\">↩︎</span>Back</a>"
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        for item in items {
            let href = (item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name) + (item.dir ? "/" : "")
            let size = item.dir ? "" : "<span class=\"s\">\(formatter.string(fromByteCount: Int64(item.size)))</span>"
            rows += "<a href=\"\(href)\"><span class=\"i\">\(item.dir ? "📁" : "📄")</span>\(Self.escape(item.name))\(size)</a>"
        }
        if items.isEmpty { rows += "<p>This folder is empty.</p>" }
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(Self.escape(title))</title>\(Self.style)</head><body><h1>\(Self.escape(title))</h1>\(rows)</body></html>"
        let body = Data(html.utf8)
        let headers = [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", String(body.count)), ("Cache-Control", "no-store")]
        return Response(status: 200, headers: headers, body: method == "HEAD" ? Data() : body)
    }
}

/// One client connection: parses requests (keep-alive), streams file bodies in chunks with back-pressure.
private final class Connection {
    private let connection: NWConnection
    private let server: LocalServer
    private var buffer = Data()
    private let queue: DispatchQueue
    private static let chunk = 256 * 1024

    init(_ connection: NWConnection, server: LocalServer) {
        self.connection = connection; self.server = server
        queue = DispatchQueue(label: "LocalServer.connection", qos: .userInitiated)
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed(let error): server.note("connection failed: \(error)"); connection.cancel()
            case .cancelled: connection.stateUpdateHandler = nil; server.ended(self)
            default: break
            }
        }
        connection.start(queue: queue)
        read()
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, finished, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                handle(head)
            } else if error != nil || finished || buffer.count > 256 * 1024 {
                if let error { server.note("receive ended: \(error)") } else if !buffer.isEmpty { server.note("request ended early after \(buffer.count) bytes") }
                else if !finished { server.note("receive ended with nothing") }
                connection.cancel()
            } else {
                read()
            }
        }
    }
    private func handle(_ head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard request.count >= 2 else { server.note("bad request line: \(lines.first ?? "")"); connection.cancel(); return }
        // Request bodies are never expected (GET/HEAD only); anything else is answered and the connection closed.
        let hasBody = (Int(headers["content-length"] ?? "0") ?? 0) > 0 || headers["transfer-encoding"] != nil
        let keepAlive = !hasBody && (headers["connection"]?.lowercased() != "close")
        var response = server.respond(method: request[0], target: request[1], headers: headers)
        if response.status >= 400 { server.note("\(request[0]) \(request[1]) -> \(response.status)") }
        response.headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        var text = "HTTP/1.1 \(response.status) \(LocalServer.reasons[response.status] ?? "OK")\r\n"
        for (name, value) in response.headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var first = Data(text.utf8); first.append(response.body)
        connection.send(content: first, completion: .contentProcessed { [self] error in
            if let error { server.note("send failed: \(error)"); try? response.file?.handle.close(); connection.cancel(); return }
            if let file = response.file {
                do { try file.handle.seek(toOffset: file.offset) } catch { try? file.handle.close(); connection.cancel(); return }
                stream(file.handle, remaining: file.length, keepAlive: keepAlive)
            } else { finish(keepAlive) }
        })
    }
    private func stream(_ handle: FileHandle, remaining: UInt64, keepAlive: Bool) {
        if remaining == 0 { try? handle.close(); finish(keepAlive); return }
        let count = Int(min(UInt64(Self.chunk), remaining))
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            stream(handle, remaining: remaining - UInt64(data.count), keepAlive: keepAlive)
        })
    }
    private func finish(_ keepAlive: Bool) {
        if keepAlive { read() } else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in connection.cancel() })
        }
    }
}

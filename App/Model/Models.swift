import UIKit
import Security

/// A folder the local server can show. Its `id` is the unguessable token in page addresses.
struct Root: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case library, imported, folder }
    var id: String
    var kind: Kind
    var name: String
    /// `.folder`: bookmark of the folder the user picked in Files (kept so it reopens after a relaunch).
    var bookmark: Data?
    /// `.imported`: file name → bookmark of the original in Files, used to pick up edits on reload.
    var sources: [String: Data]?
}

/// Where a tab is, independent of the server's port.
enum Location: Codable, Equatable {
    case start
    case local(root: String, path: String)
    case web(String)
}

struct SavedTab: Codable {
    var id: UUID
    var title: String
    var location: Location
    /// WKWebView's back/forward history, valid only while the server port is `port`.
    var history: Data?
    var port: UInt16?
    var zoom: Double?
    var desktop: Bool?
}

struct Recent: Codable, Identifiable, Equatable {
    var root: String
    var path: String
    var title: String
    var date: Date
    var id: String { root + "/" + path }
}

struct AppState: Codable {
    var tabs: [SavedTab] = []
    var active: UUID?
    var roots: [Root] = []
    var recents: [Recent] = []
}

enum AppDirs {
    static let support: URL = make(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HTMLViewer"))
    /// Private copies of files opened one at a time from Files.
    static let opened: URL = make(support.appendingPathComponent("Opened"))
    static let snapshots: URL = make(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots"))
    /// Visible in the Files app under On My iPhone → HTML Viewer.
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let downloads: URL = documents.appendingPathComponent("Downloads")
    static let stateFile: URL = support.appendingPathComponent("state.json")

    private static func make(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    /// `name`, or `name 2`, `name 3`… if taken, inside `folder`.
    static func freeName(_ name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        return candidate
    }
}

enum Device {
    /// The name the Files app uses for local storage on this device.
    @MainActor static var onMy: String { UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone" }
}

enum PageKind {
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "shtml", "mhtml", "svg"]
    static func isPage(_ url: URL) -> Bool { htmlExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty }
}

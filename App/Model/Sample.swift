import Foundation

extension BrowserStore {
    /// A file or folder handed over by Files ("Open in HTML Viewer") or another app.
    func openIncoming(_ url: URL) {
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if scoped { url.stopAccessingSecurityScopedResource() }
            if isFolder { open(folder: url) } else { open(files: [url]) }
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            show(.web(url.absoluteString), newTab: false)
        }
    }

    /// Writes a small multi-file site into the app's Files folder → Sample and opens it: a quick check that pages, styles,
    /// scripts, fetch, images and links all load.
    func openSample() {
        let folder = AppDirs.documents.appendingPathComponent("Sample")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in Self.sampleFiles {
            try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        guard let library = roots.first(where: { $0.kind == .library }) else { return }
        show(.local(root: library.id, path: "Sample/index.html"), newTab: false)
    }

    static let sampleFiles: [String: String] = [
        "index.html": """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Sample page</title>
          <link rel="stylesheet" href="style.css">
        </head>
        <body>
          <main>
            <img src="mark.svg" alt="" width="72" height="72">
            <h1>It works</h1>
            <p>This page lives in the Files app under <b>HTML Viewer → Sample</b>. Each line below checks one thing a real page needs.</p>
            <ul id="checks">
              <li id="css">Stylesheet (style.css)</li>
              <li id="img">Image (mark.svg)</li>
              <li id="js">Script module (app.js)</li>
              <li id="fetch">fetch() of data.json</li>
              <li id="store">Saved data (localStorage)</li>
            </ul>
            <p id="summary">Checking…</p>
            <p><a href="second.html">Open the second page</a> · <a href="second.html" target="_blank">in a new tab</a></p>
          </main>
          <script type="module" src="app.js"></script>
        </body>
        </html>
        """,
        "second.html": """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Second page</title>
          <link rel="stylesheet" href="style.css">
        </head>
        <body>
          <main>
            <h1>Second page</h1>
            <p>Links between your files work like on a website. Swipe from the left edge or use the back button.</p>
            <p><a href="index.html">Back to the first page</a></p>
          </main>
        </body>
        </html>
        """,
        "style.css": """
        :root { color-scheme: light dark; --ok: #1a8f4c; }
        body { font: 17px/1.5 -apple-system, system-ui, sans-serif; margin: 0; background: #fff; color: #111; }
        @media (prefers-color-scheme: dark) { body { background: #000; color: #f2f2f2; } }
        main { max-width: 34rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
        h1 { font-size: 2rem; letter-spacing: -0.02em; margin: 1rem 0 0.5rem; }
        ul { list-style: none; padding: 0; margin: 1.5rem 0; border-top: 1px solid rgba(128, 128, 128, 0.3); }
        li { padding: 0.8rem 0; border-bottom: 1px solid rgba(128, 128, 128, 0.3); display: flex; justify-content: space-between; gap: 1rem; }
        li::after { content: "waiting"; opacity: 0.5; }
        li.ok::after { content: "✓ works"; color: var(--ok); opacity: 1; font-weight: 600; }
        li.bad::after { content: "✗ failed"; color: #c0392b; opacity: 1; font-weight: 600; }
        #summary { font-weight: 600; }
        a { color: #2f6fed; }
        """,
        "app.js": """
        import { greeting } from "./lib.js";
        const results = {};
        const mark = (id, ok) => {
          results[id] = ok;
          document.getElementById(id).className = ok ? "ok" : "bad";
          const all = ["css", "img", "js", "fetch", "store"];
          if (all.every(k => k in results)) {
            const passed = all.filter(k => results[k]).length;
            document.getElementById("summary").textContent = passed === all.length ? "All 5 checks passed" : `${passed} of 5 checks passed`;
          }
        };
        mark("js", greeting() === "hello");
        mark("css", getComputedStyle(document.querySelector("main")).maxWidth !== "none");
        const image = document.querySelector("img");
        const checkImage = () => mark("img", image.naturalWidth > 0);
        if (image.complete) checkImage(); else { image.onload = checkImage; image.onerror = checkImage; }
        fetch("data.json").then(r => r.json()).then(d => mark("fetch", d.ok === true)).catch(() => mark("fetch", false));
        try {
          const visits = Number(localStorage.getItem("visits") || 0) + 1;
          localStorage.setItem("visits", String(visits));
          mark("store", Number(localStorage.getItem("visits")) === visits);
        } catch { mark("store", false); }
        """,
        "lib.js": "export const greeting = () => \"hello\";\n",
        "data.json": "{ \"ok\": true }\n",
        "mark.svg": """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72"><rect width="72" height="72" rx="16" fill="#2f6fed"/><path d="M27 24 15 36l12 12M45 24l12 12-12 12M40 20 32 52" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/></svg>
        """,
    ]
}

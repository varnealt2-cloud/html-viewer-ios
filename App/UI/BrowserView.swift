import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum Palette {
    static let accent = Color(red: 0.18, green: 0.44, blue: 0.93)
}

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var showTabs = false
    @State private var picker: DocumentPicker.Kind?
    @State private var sourceText: SourceText?
    @State private var editingAddress = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let tab = store.active {
                VStack(spacing: 0) {
                    TabContent(tab: tab, picker: $picker).id(tab.id)
                    BottomBar(tab: tab, showTabs: $showTabs, picker: $picker, sourceText: $sourceText, editing: $editingAddress)
                }
                // While typing in a page the web view makes its own room for the keyboard.
                .ignoresSafeArea(.keyboard, edges: editingAddress ? [] : .bottom)
            }
            if let busy = store.busy {
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text(busy).font(.callout).multilineTextAlignment(.center) }
                    .padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(40)
            }
        }
        .tint(Palette.accent)
        .fullScreenCover(isPresented: $showTabs) { TabGrid(isPresented: $showTabs) }
        .onChange(of: picker) { kind in
            guard let kind else { return }
            picker = nil
            DocumentPicker.shared.present(kind) { urls in
                if kind == .folder, let folder = urls.first { store.open(folder: folder) } else { store.open(files: urls) }
            }
        }
        .sheet(item: $sourceText) { SourceView(source: $0) }
        .alert("HTML Viewer", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.notice ?? "") }
    }
}

struct SourceText: Identifiable { let id = UUID(); let title: String; let text: String }

/// The page area of one tab: the start page, or the tab's web view with a failure message over it.
struct TabContent: View {
    @ObservedObject var tab: Tab
    @Binding var picker: DocumentPicker.Kind?

    var body: some View {
        ZStack {
            if tab.isStart {
                StartPage(picker: $picker)
            } else {
                WebContainer(tab: tab, generation: tab.webViewGeneration)
                if let failure = tab.failure {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("This page didn't load").font(.title3.weight(.semibold))
                        Text(failure).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { tab.reload() }.buttonStyle(.borderedProminent)
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
                    .accessibilityIdentifier("failure")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the tab's own WKWebView (owned by the tab, so it survives switching tabs).
struct WebContainer: UIViewRepresentable {
    let tab: Tab
    let generation: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .systemBackground; return view
    }
    func updateUIView(_ container: UIView, context: Context) {
        let web = tab.webView
        if let web, web.superview === container { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let web else { return }
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
    }
}

struct BottomBar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var tab: Tab
    @Binding var showTabs: Bool
    @Binding var picker: DocumentPicker.Kind?
    @Binding var sourceText: SourceText?
    @Binding var editing: Bool
    @FocusState private var focused: Bool
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Rectangle().fill(Palette.accent)
                    .frame(width: geometry.size.width * (tab.isLoading ? max(0.06, tab.progress) : 0))
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
            }
            .frame(height: 2).opacity(tab.isLoading ? 1 : 0)

            HStack(spacing: 8) {
                if editing {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search or enter address", text: $typed)
                            .keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).focused($focused)
                            .onSubmit { go() }
                            .onAppear { DispatchQueue.main.async { focused = true } }
                            .onChange(of: focused) { isFocused in if !isFocused { editing = false } }
                            .accessibilityIdentifier("addressField")
                        if !typed.isEmpty {
                            Button { typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button("Cancel") { focused = false; editing = false }
                } else {
                    pageMenu
                    Button { beginEditing() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.isLocal ? "doc.text" : tab.isSecureWeb ? "lock.fill" : tab.isStart ? "magnifyingglass" : "globe")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(tab.addressText).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(tab.isStart ? .secondary : .primary)
                        }
                        .frame(maxWidth: .infinity).padding(.horizontal, 12).frame(height: 44)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("addressPill").accessibilityLabel("Address, \(tab.addressText)")
                    Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").frame(width: 36, height: 44)
                    }
                    .disabled(tab.isStart).accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if !editing {
                HStack {
                    barButton("chevron.backward", "Back", enabled: tab.canGoBack) { tab.goBack() }
                    Spacer()
                    barButton("chevron.forward", "Forward", enabled: tab.canGoForward) { tab.goForward() }
                    Spacer()
                    barButton("square.and.arrow.up", "Share", enabled: !tab.isStart) { share() }
                    Spacer()
                    Menu {
                        Button { picker = .file } label: { Label("Open File…", systemImage: "doc") }
                        Button { picker = .files } label: { Label("Open Several Files…", systemImage: "doc.on.doc") }
                        Button { picker = .folder } label: { Label("Open Folder…", systemImage: "folder") }
                        Button { store.newTab() } label: { Label("New Tab", systemImage: "plus") }
                    } label: { Image(systemName: "plus").font(.system(size: 20)).frame(width: 48, height: 44) }
                        .accessibilityLabel("Open").accessibilityIdentifier("openMenu")
                    Spacer()
                    Button { store.active?.capture { showTabs = true } } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.8).frame(width: 23, height: 23)
                            Text("\(min(store.tabs.count, 99))").font(.system(size: 12, weight: .bold, design: .rounded))
                        }.frame(width: 48, height: 44)
                    }
                    .accessibilityLabel("Tabs, \(store.tabs.count) open").accessibilityIdentifier("tabsButton")
                }
                .padding(.horizontal, 14).padding(.top, 2)
            }
        }
        .padding(.bottom, editing ? 8 : 0)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var pageMenu: some View {
        Menu {
            if #available(iOS 16.0, *) {
                Button { tab.find() } label: { Label("Find on Page", systemImage: "magnifyingglass") }.disabled(tab.isStart)
            }
            ControlGroup {
                Button { tab.setZoom(tab.zoom - 0.1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { tab.setZoom(1) } label: { Text("\(Int((tab.zoom * 100).rounded()))%") }
                Button { tab.setZoom(tab.zoom + 0.1) } label: { Image(systemName: "textformat.size.larger") }
            }
            Button { tab.toggleDesktop() } label: {
                Label(tab.desktop ? "Request Mobile Site" : "Request Desktop Site", systemImage: tab.desktop ? "iphone" : "desktopcomputer")
            }
            Button { Task { sourceText = SourceText(title: tab.displayTitle, text: await tab.source()) } } label: {
                Label("View Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }.disabled(tab.isStart)
            if let url = tab.displayURL, !tab.isLocal, !tab.isStart {
                Button { UIPasteboard.general.url = url } label: { Label("Copy Address", systemImage: "doc.on.doc") }
            }
            Divider()
            Button(role: .destructive) { store.close(tab) } label: { Label("Close Tab", systemImage: "xmark") }
        } label: { Image(systemName: "textformat.size").frame(width: 36, height: 44) }
            .accessibilityLabel("Page options")
    }

    private func barButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20)).frame(width: 48, height: 44) }
            .disabled(!enabled).accessibilityLabel(label)
    }
    private func beginEditing() {
        if case .web(let text) = tab.location { typed = text } else { typed = "" }
        editing = true
    }
    private func go() {
        focused = false; editing = false
        if let location = BrowserStore.location(typed: typed) { tab.load(location) }
    }
    private func share() {
        var item: Any?
        switch tab.location {
        case .local(let root, let path):
            if let folder = store.roots.first(where: { $0.id == root }).flatMap({ store.directory(of: $0) }) { item = folder.appendingPathComponent(path) }
        case .web(let text): item = URL(string: text)
        case .start: break
        }
        guard let item else { return }
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        Tab.present(sheet) {}
    }
}

/// Read-only HTML source of the current page.
struct SourceView: View {
    let source: SourceText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            SourceTextView(text: source.text).ignoresSafeArea(edges: .bottom)
                .navigationTitle(source.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button { UIPasteboard.general.string = source.text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy") }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
                }
        }
        .navigationViewStyle(.stack)
    }
}
struct SourceTextView: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.autocapitalizationType = .none; view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

/// The Files picker, for files (several at once) or one folder. Presented with UIKit directly: the system picker
/// dismisses itself, which a SwiftUI sheet wrapper does not always track.
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    /// `.file`: one tap on a file opens it. `.files`: tick several, then Open.
    enum Kind: String, Identifiable { case file, files, folder; var id: String { rawValue } }
    static let shared = DocumentPicker()
    private var picked: (([URL]) -> Void)?

    func present(_ kind: Kind, picked: @escaping ([URL]) -> Void) {
        self.picked = picked
        // Files are handed over as copies, so no access permission can lapse while they are read.
        // .item: any file at all, so pages with unusual or missing extensions can be chosen.
        let controller = kind == .folder
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = kind == .files
        controller.delegate = self
        Tab.present(controller) { self.picked = nil }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = picked; picked = nil
        handler?(urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked = nil }
}

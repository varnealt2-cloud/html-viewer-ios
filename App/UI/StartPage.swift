import SwiftUI

/// What a new tab shows: ways to open something, saved places, and recently opened pages.
struct StartPage: View {
    @EnvironmentObject private var store: BrowserStore
    @Binding var picker: DocumentPicker.Kind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HTML Viewer").font(.largeTitle.bold())
                    Text("Open any HTML file on this device.").foregroundStyle(.secondary)
                }
                .padding(.top, 28)

                HStack(spacing: 12) {
                    bigButton("Open File", "doc.badge.plus", prominent: true) { picker = .file }
                        .accessibilityIdentifier("openFiles")
                    bigButton("Open Folder", "folder.badge.plus", prominent: false) { picker = .folder }
                        .accessibilityIdentifier("openFolder")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tap a file to open it. A page that uses its own images, videos, styles or scripts needs them too: open the whole folder, or select the page together with its files.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { picker = .files } label: { Label("Select several files at once", systemImage: "checklist") }
                        .font(.subheadline).accessibilityIdentifier("openSeveral")
                }

                section("Places") {
                    ForEach(store.roots.filter { $0.kind != .imported }) { root in
                        row(root.kind == .library ? "internaldrive" : "folder", root.kind == .library ? Device.onMy : root.name,
                            root.kind == .library ? "Files → \(Device.onMy) → HTML Viewer" : "Folder in Files") {
                            if store.prepare(root: root.id) { store.show(.local(root: root.id, path: ""), newTab: false) }
                            else { store.notice = "“\(root.name)” is not available any more. Open the folder again." }
                        }
                        .contextMenu {
                            if root.kind == .folder { Button(role: .destructive) { store.removeRoot(root) } label: { Label("Remove from Places", systemImage: "minus.circle") } }
                        }
                    }
                }

                if !store.recents.isEmpty {
                    section("Recent", trailing: { Button("Clear") { store.clearRecents() }.font(.subheadline) }) {
                        ForEach(store.recents.prefix(12)) { item in
                            row("doc.text", item.title, (item.path as NSString).lastPathComponent) {
                                if store.prepare(root: item.root) { store.show(.local(root: item.root, path: item.path), newTab: false) }
                                else { store.notice = "That file is not available any more."; store.removeRecent(item) }
                            }
                            .contextMenu { Button(role: .destructive) { store.removeRecent(item) } label: { Label("Remove", systemImage: "minus.circle") } }
                        }
                    }
                }

                Button { store.openSample() } label: { Label("Open the sample page", systemImage: "sparkles") }
                    .font(.subheadline).accessibilityIdentifier("openSample")
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("startPage")
    }

    private func bigButton(_ title: String, _ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium)).frame(height: 32, alignment: .bottom)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .foregroundStyle(prominent ? Color.white : Palette.accent)
            .background(prominent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }
    private func section<Trailing: View, Content: View>(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.title3.weight(.semibold)); Spacer(); trailing() }
            VStack(spacing: 0) { content() }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    private func row(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Palette.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 56) }
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// Overview of all open tabs as thumbnails.
struct TabGrid: View {
    @EnvironmentObject private var store: BrowserStore
    @Binding var isPresented: Bool
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.tabs) { tab in
                            TabCard(tab: tab, isActive: tab.id == store.activeID,
                                    open: { store.select(tab); isPresented = false },
                                    close: { withAnimation(.easeOut(duration: 0.22)) { store.close(tab) } })
                                .id(tab.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear { if let id = store.activeID { proxy.scrollTo(id, anchor: .center) } }
            }
            HStack {
                Button { store.newTab(); isPresented = false } label: { Image(systemName: "plus").font(.system(size: 21)).frame(width: 48, height: 44) }
                    .accessibilityLabel("New Tab").accessibilityIdentifier("newTab")
                Spacer()
                Menu {
                    Button(role: .destructive) { store.closeAll(); isPresented = false } label: { Label("Close All \(store.tabs.count) Tabs", systemImage: "xmark") }
                } label: { Text(store.tabs.count == 1 ? "1 Tab" : "\(store.tabs.count) Tabs").font(.subheadline.weight(.semibold)).foregroundStyle(.primary).frame(height: 44) }
                Spacer()
                Button("Done") { isPresented = false }.font(.body.weight(.semibold)).frame(height: 44).accessibilityIdentifier("tabsDone")
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .background(.bar).overlay(alignment: .top) { Divider() }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .tint(Palette.accent)
    }
}

private struct TabCard: View {
    @ObservedObject var tab: Tab
    let isActive: Bool
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                Color(.secondarySystemGroupedBackground)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay(alignment: .top) {
                        if let image = tab.snapshot, !tab.isStart {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            Image(systemName: tab.isStart ? "plus.square.dashed" : "doc.text")
                                .font(.system(size: 34)).foregroundStyle(.tertiary).frame(maxHeight: .infinity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isActive ? Palette.accent : Color(.separator), lineWidth: isActive ? 2.5 : 0.5) }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary)
                        .frame(width: 26, height: 26).background(.thinMaterial, in: Circle())
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
            Text(tab.displayTitle).font(.footnote.weight(.medium)).lineLimit(1).padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
    }
}

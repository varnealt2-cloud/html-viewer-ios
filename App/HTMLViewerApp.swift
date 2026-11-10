import SwiftUI

@main
struct HTMLViewerApp: App {
    @StateObject private var store = BrowserStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(store)
                .onOpenURL { store.openIncoming($0) }
                .onChange(of: phase) { value in
                    switch value {
                    case .active: store.becameActive()
                    case .background: store.enteredBackground()
                    default: store.saveNow()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in store.memoryWarning() }
                .onAppear {
                    // Used by the automated tests: open the sample, or a file as if it had been picked.
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-sample") { store.openSample() }
                    if let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count { store.open(files: [URL(fileURLWithPath: arguments[index + 1])]) }
                    if let index = arguments.firstIndex(of: "-seed"), index + 1 < arguments.count {
                        let source = URL(fileURLWithPath: arguments[index + 1])
                        try? FileManager.default.copyItem(at: source, to: AppDirs.documents.appendingPathComponent(source.lastPathComponent))
                    }
                }
        }
    }
}

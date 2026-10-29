import SwiftUI
import UIKit
import MemoKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app here when a background model download finishes while it is not running.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelManager.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}

@main
struct MemoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundTasks.register()
        BackgroundTasks.startConnectivityMonitor()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Text("App Group: \(AppPaths.usingAppGroup ? "yes" : "no")")
                    }
                    Section("Debug") {
                        NavigationLink("Transcription test") { DebugTranscriptionView() }
                    }
                }
                .navigationTitle("Memo")
            }
            .task { await ModelManager.shared.reconnect() }
            .onOpenURL { GoogleAuth.handle($0) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: BackgroundTasks.processNow()
                case .background: BackgroundTasks.didEnterBackground()
                default: break
                }
            }
        }
    }
}

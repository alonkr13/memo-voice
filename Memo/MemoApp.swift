import SwiftUI
import MemoKit

@main
struct MemoApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Memo").font(.largeTitle.bold())
                Text("App Group: \(AppPaths.usingAppGroup ? "yes" : "no")")
                    .font(.title3)
            }
            .padding()
        }
    }
}

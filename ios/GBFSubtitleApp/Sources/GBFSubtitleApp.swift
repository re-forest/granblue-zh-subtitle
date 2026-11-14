import SwiftUI

@main
struct GBFSubtitleApp: App {
    @StateObject private var sessionManager = SubtitleSessionManager()

    var body: some Scene {
        WindowGroup {
            MainSplitView(sessionManager: sessionManager)
                .preferredColorScheme(.dark)
        }
    }
}

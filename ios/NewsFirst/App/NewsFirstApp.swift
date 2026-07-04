import SwiftUI

@main
struct NewsFirstApp: App {
    @State private var store = FeedStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }   // cache renders first; network refresh behind it
        }
    }
}

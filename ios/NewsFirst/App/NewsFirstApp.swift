import SwiftUI

@main
struct NewsFirstApp: App {
    @State private var store = FeedStore()

    init() {
        #if os(iOS)
        // Default segment font can't fit TOPICS + "Immersive" + gear across a 393pt
        // screen; a notch smaller clears it with no truncation anywhere.
        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font], for: .selected)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }   // cache renders first; network refresh behind it
        }
    }
}

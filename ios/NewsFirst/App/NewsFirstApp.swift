import SwiftUI

@main
struct NewsFirstApp: App {
    @State private var store = FeedStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }   // cache renders first; network refresh happens behind it
        }
    }
}

struct RootView: View {
    @Environment(FeedStore.self) private var store
    @State private var mode: ViewMode = .list

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: FeedListView()
                case .immersive: ImmersiveView()
                }
            }
            .toolbar { ViewModeToggle(mode: $mode) }
        }
    }
}

enum ViewMode: String, CaseIterable {
    case list = "List"
    case immersive = "Immersive"
}

struct ViewModeToggle: ToolbarContent {
    @Binding var mode: ViewMode
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode.animation(.snappy(duration: 0.25))) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }
}

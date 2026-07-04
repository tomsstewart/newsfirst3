import SwiftUI

/// App shell: pulsing splash → header (brand + view toggle + settings) → topic chips → feed.
struct RootView: View {
    @Environment(FeedStore.self) private var store
    @State private var showSettings = false
    @State private var showSplash = true

    var body: some View {
        @Bindable var store = store
        ZStack {
            VStack(spacing: 0) {
                header
                TopicBar()
                    .padding(.bottom, 8)
                feed
            }
            .background(Theme.groupedBackground)

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(1)
            }
        }
        .preferredColorScheme(store.appearance.scheme)
        .sheet(item: $store.reading) { ReaderSheet(article: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            // Splash holds only as long as the cache load needs — never a fixed timer.
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showSplash = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("NewsFirst")
                .font(Theme.Text.headline)
            Spacer()
            Picker("View", selection: Binding(
                get: { store.mode },
                set: { m in withAnimation(Theme.Motion.feed) { store.mode = m } }
            )) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 230)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @State private var swipeDirection: Edge = .trailing

    @ViewBuilder private var feed: some View {
        ZStack {
            if store.isLoadingSelected {
                FeedSkeleton(mode: store.mode)
                    .transition(.opacity)
            } else if store.visible.isEmpty {
                EmptyTopicView(topic: store.selectedTopic)
                    .transition(.opacity)
            } else {
                Group {
                    switch store.mode {
                    case .list: ListFeedView()
                    case .immersive: ImmersiveFeedView()
                    case .full: FullFeedView()
                    }
                }
                .id("\(store.mode.rawValue)-\(store.selectedTopic)")   // replay kinetic entrances per topic/mode
                .transition(.asymmetric(
                    insertion: .move(edge: swipeDirection).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .animation(Theme.Motion.feed, value: store.mode)
        .animation(Theme.Motion.feed, value: store.selectedTopic)
        .animation(Theme.Motion.feed, value: store.isLoadingSelected)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    guard abs(v.translation.width) > 60,
                          abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    stepTopic(v.translation.width < 0 ? 1 : -1)
                }
        )
    }

    /// Swipe left/right anywhere on the feed pages through the topic bar.
    private func stepTopic(_ delta: Int) {
        let bar = store.topicBar
        guard let idx = bar.firstIndex(of: store.selectedTopic) else { return }
        let next = (idx + delta + bar.count) % bar.count
        swipeDirection = delta > 0 ? .trailing : .leading
        withAnimation(Theme.Motion.feed) { store.selectedTopic = bar[next] }
        if store.customTopics.contains(bar[next]) { Task { await store.loadCustom(bar[next]) } }
    }
}

// MARK: - Topic chips (the spine of the product)

struct TopicBar: View {
    @Environment(FeedStore.self) private var store
    @State private var addingTopic = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.topicBar, id: \.self) { topic in
                    chip(topic)
                }
                addChip
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    private func chip(_ topic: String) -> some View {
        let selected = store.selectedTopic == topic
        let custom = store.customTopics.contains(topic)
        return Button {
            withAnimation(Theme.Motion.snappy) { store.selectedTopic = topic }
            if custom { Task { await store.loadCustom(topic) } }
        } label: {
            HStack(spacing: 5) {
                if custom {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.caption2)
                }
                Text(topic.capitalized)
            }
            .font(Theme.Text.meta)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassChip(prominent: selected)
            .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if custom {
                Button(role: .destructive) { store.removeCustomTopic(topic) } label: {
                    Label("Remove topic", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private var addChip: some View {
        if addingTopic {
            TextField("keyword…", text: $draft)
                .font(Theme.Text.meta)
                .textFieldStyle(.plain)
                .focused($draftFocused)
                .frame(width: 110)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassChip()
                .onSubmit {
                    store.addCustomTopic(draft)
                    draft = ""
                    withAnimation(Theme.Motion.snappy) { addingTopic = false }
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Button {
                withAnimation(Theme.Motion.snappy) { addingTopic = true }
                draftFocused = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.caption2.bold())
                    Text("Custom")
                }
                .font(Theme.Text.meta)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassChip()
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressableStyle())
        }
    }
}

// MARK: - Pulsing splash (v2's signature carried forward)

struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.groupedBackground.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("NewsFirst")
                    .font(.system(size: 40, weight: .heavy, design: .default))
                    .foregroundStyle(Theme.accent)
                    .scaleEffect(pulse ? 1.06 : 0.97)
                    .opacity(pulse ? 1 : 0.75)
                Text("Be first to know")
                    .font(Theme.Text.meta)
                    .foregroundStyle(.secondary)
                    .opacity(pulse ? 0.9 : 0.4)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

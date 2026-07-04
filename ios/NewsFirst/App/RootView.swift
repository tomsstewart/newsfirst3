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
        .preferredColorScheme(store.appearance.scheme ?? .dark)   // Midnight Glass has no light palette yet — Auto means dark
        .sheet(item: $store.reading) { ReaderSheet(article: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task(id: "\(store.browse.rawValue)|\(store.selectedTopic)|\(store.selectedSource)") {
            await store.backfillIfSparse()
        }
        .task {
            // Splash holds only as long as the cache load needs — never a fixed timer.
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showSplash = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Theme.Motion.card) {
                    store.browse = store.browse == .topics ? .sources : .topics
                }
                if store.browse == .sources { Task { await store.loadSources() } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.browse == .topics ? "square.grid.2x2" : "dot.radiowaves.up.forward")
                        .font(.caption2.bold())
                    Text(store.browse.rawValue.uppercased())
                        .font(Theme.Text.badge)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(store.browse == .topics ? Theme.accent : Color(red: 0.95, green: 0.45, blue: 0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .foregroundStyle(.white)
                .shadow(color: (store.browse == .topics ? Theme.accent : Color.orange).opacity(0.5), radius: 6)
            }
            .buttonStyle(PressableStyle())
            Spacer()
            Picker("View", selection: Binding(
                get: { store.mode },
                set: { m in withAnimation(Theme.Motion.feed) { store.mode = m } }
            )) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
    @State private var feedDrag: CGFloat = 0

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
                .id("\(store.mode.rawValue)-\(store.browse.rawValue)-\(store.selectedTopic)-\(store.selectedSource)")   // replay kinetic entrances per topic/mode
                .transition(.asymmetric(
                    insertion: .move(edge: swipeDirection).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .animation(Theme.Motion.feed, value: store.mode)
        .animation(Theme.Motion.feed, value: store.selectedTopic)
        .animation(Theme.Motion.feed, value: store.selectedSource)
        .animation(Theme.Motion.feed, value: store.browse)
        .animation(Theme.Motion.feed, value: store.isLoadingSelected)
        .offset(x: feedDrag)
        .opacity(1 - Double(abs(feedDrag)) / 900)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    feedDrag = v.translation.width * 0.9          // tracks from the first pixels
                    swipeDirection = v.translation.width < 0 ? .trailing : .leading
                }
                .onEnded { v in
                    let commit = abs(v.translation.width) > 70 && abs(v.translation.width) > abs(v.translation.height) * 1.2
                    if commit {
                        feedDrag = 0                              // new feed slides in via transition
                        stepTopic(v.translation.width < 0 ? 1 : -1)
                    } else {
                        withAnimation(Theme.Motion.card) { feedDrag = 0 }   // spring back
                    }
                }
        )
    }

    /// Swipe left/right anywhere on the feed pages through the topic bar.
    private func stepTopic(_ delta: Int) {
        swipeDirection = delta > 0 ? .trailing : .leading
        if store.browse == .sources {
            let bar = store.sourceBar
            guard let idx = bar.firstIndex(of: store.selectedSource), !bar.isEmpty else { return }
            withAnimation(Theme.Motion.feed) { store.selectedSource = bar[(idx + delta + bar.count) % bar.count] }
            return
        }
        let bar = store.topicBar
        guard let idx = bar.firstIndex(of: store.selectedTopic) else { return }
        let next = (idx + delta + bar.count) % bar.count
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if store.browse == .topics {
                        ForEach(store.topicBar, id: \.self) { topic in chip(topic).id(topic) }
                        addChip
                    } else {
                        ForEach(store.sourceBar, id: \.self) { source in sourceChip(source).id(source) }
                    }
                }
                .padding(.horizontal, 16)
                #if os(macOS)
                .gesture(barDragScroll(proxy))   // mouse drag scrolls the bar (touch does this natively)
                #endif
            }
            .scrollClipDisabled()
            .task { if store.browse == .sources { await store.loadSources() } }
            .onChange(of: store.selectedTopic) { _, sel in
                withAnimation(Theme.Motion.snappy) { proxy.scrollTo(sel, anchor: .center) }
            }
            .onChange(of: store.selectedSource) { _, sel in
                withAnimation(Theme.Motion.snappy) { proxy.scrollTo(sel, anchor: .center) }
            }
        }
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
            .animation(nil, value: store.selectedTopic)   // color/material swap must not tween (B/W flash)
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

    #if os(macOS)
    @State private var barDragAccum: CGFloat = 0
    private func barDragScroll(_ proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let bar = store.browse == .topics ? store.topicBar : store.sourceBar
                let current = store.browse == .topics ? store.selectedTopic : store.selectedSource
                guard let idx = bar.firstIndex(of: current) else { return }
                let steps = Int((-v.translation.width - barDragAccum) / 70)
                if steps != 0 {
                    barDragAccum += CGFloat(steps) * 70
                    let target = max(0, min(bar.count - 1, idx + steps))
                    withAnimation(Theme.Motion.snappy) { proxy.scrollTo(bar[target], anchor: .center) }
                }
            }
            .onEnded { _ in barDragAccum = 0 }
    }
    #endif

    private func sourceChip(_ source: String) -> some View {
        let selected = store.selectedSource == source
        return Button {
            withAnimation(Theme.Motion.snappy) { store.selectedSource = source }
        } label: {
            Text(source)
                .font(Theme.Text.meta)
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassChip(prominent: selected)
                .foregroundStyle(selected ? .white : .secondary)
                .animation(nil, value: store.selectedSource)
        }
        .buttonStyle(PressableStyle())
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

import SwiftUI

/// App shell: pulsing splash → header (brand + view toggle + settings) → topic chips → feed.
struct RootView: View {
    @Environment(FeedStore.self) private var store
    @State private var showSettings = false
    @State private var showSplash = true
    @State private var showAuth = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false

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

            if !hasOnboarded && !showSplash {
                OnboardingView(done: $hasOnboarded)
                    .transition(.opacity)
                    .zIndex(2)
            }
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(store.appearance.scheme)
        #if os(iOS)
        .fullScreenCover(item: $store.reading) { ReaderSheet(article: $0) }
        #else
        .sheet(item: $store.reading) { ReaderSheet(article: $0) }
        #endif
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAuth) { AuthView() }
        .environment(\.openAuth, { showAuth = true })
        .onAppear { Analytics.capture("app_open") }
        .task(id: "\(store.browse.rawValue)|\(store.selectedTopic)|\(store.selectedSource)") {
            await store.backfillIfSparse()
        }
        .task {
            // Splash holds only as long as the cache load needs — never a fixed timer.
            try? await Task.sleep(for: .milliseconds(950))   // let the fly-in settle
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
    }

    private var header: some View {
        // Flexible row (not absolute centering): the full "Immersive" label needs more
        // width than the gap left by absolute centering, which shoved it under TOPICS.
        HStack(spacing: 10) {
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
                    .fixedSize()   // never collapses under header width pressure
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(store.browse == .topics ? Theme.accent : Color(red: 0.95, green: 0.45, blue: 0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .foregroundStyle(.white)
                    .shadow(color: (store.browse == .topics ? Theme.accent : Color.orange).opacity(0.5), radius: 6)
                }
            .buttonStyle(PressableStyle())
            Spacer(minLength: 6)
            Picker("View", selection: Binding(
                get: { store.mode },
                set: { m in withAnimation(Theme.Motion.feed) { store.mode = m } }
            )) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .layoutPriority(1)   // the selector never truncates; spacers absorb the squeeze
            Spacer(minLength: 6)
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
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                if store.isLoadingSelected {
                    FeedSkeleton(mode: store.mode).transition(.opacity)
                } else {
                    // Live carousel: neighbour columns are mounted and visible during the drag.
                    HStack(spacing: 0) {
                        pane(offset: -1, width: w)
                        pane(offset: 0, width: w)
                        pane(offset: 1, width: w)
                    }
                    .offset(x: -w + feedDrag)
                }
            }
            .animation(Theme.Motion.feed, value: store.mode)
            .animation(Theme.Motion.feed, value: store.isLoadingSelected)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        feedDrag = v.translation.width
                        store.swipeProgress = max(-1, min(1, -v.translation.width / w))
                    }
                    .onEnded { v in
                        let commit = abs(v.translation.width) > w * 0.28 || abs(v.predictedEndTranslation.width) > w * 0.55
                        if commit {
                            let delta = v.translation.width < 0 ? 1 : -1
                            withAnimation(Theme.Motion.feed, completionCriteria: .logicallyComplete) {
                                feedDrag = CGFloat(-delta) * w
                                store.swipeProgress = CGFloat(delta)   // pill glides into the target chip in sync
                            } completion: {
                                KineticGate.suppressed = true
                                if store.browse == .sources { store.selectedSource = store.barItem(offset: delta) }
                                else { store.selectedTopic = store.barItem(offset: delta) }
                                let landed = store.barItem(offset: 0)
                                if store.customTopics.contains(landed) { Task { await store.loadCustom(landed) } }
                                store.prefetchImages()
                                feedDrag = 0
                                store.swipeProgress = 0
                            }
                        } else {
                            withAnimation(Theme.Motion.card) { feedDrag = 0; store.swipeProgress = 0 }
                        }
                    }
            )
        }
    }

    @ViewBuilder private func pane(offset: Int, width: CGFloat) -> some View {
        let items = store.visibleAt(offset: offset)
        Group {
            if items.isEmpty {
                EmptyTopicView(topic: store.barItem(offset: offset))
            } else {
                switch store.mode {
                case .list: ListFeedView(items: items)
                case .immersive: ImmersiveFeedView(items: items)
                case .full: FullFeedView(items: items)
                }
            }
        }
        .frame(width: width)
        .id("\(store.mode.rawValue)-\(store.browse.rawValue)-\(store.barItem(offset: offset))")
    }

    /// Swipe left/right anywhere on the feed pages through the topic bar.
    private func stepTopic(_ delta: Int) {
        KineticGate.suppressed = true    // swipe = straight column scroll, no entrance cascade
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

extension EnvironmentValues {
    @Entry var openAuth: () -> Void = {}
}

// MARK: - Topic chips (the spine of the product)

struct TopicBar: View {
    @Environment(FeedStore.self) private var store
    @Namespace private var chipSelection
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var pillEpoch = 0   // bumped on non-adjacent jumps → pill fades instead of travelling
    @State private var draggedTopic: String?
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
                .coordinateSpace(name: "chipbar")
                .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
                .background(alignment: .topLeading) { movingIndicator }
                .scrollTargetLayout()
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

    /// During a swipe, the chip the pill is travelling toward goes transparent in
    /// proportion to progress, so the pill is revealed as it arrives — no flash.
    private func chipPanelOpacity(_ item: String, selected: Bool, bar: [String], current: String) -> Double {
        if selected { return 0 }
        let p = store.swipeProgress
        guard p != 0, let idx = bar.firstIndex(of: current), !bar.isEmpty else { return 1 }
        let target = bar[(idx + (p > 0 ? 1 : -1) + bar.count) % bar.count]
        return item == target ? 1 - Double(abs(p)) : 1
    }

    private func chip(_ topic: String) -> some View {
        let selected = store.selectedTopic == topic
        let custom = store.customTopics.contains(topic)
        let labelContent = HStack(spacing: 5) {
            if custom {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption2)
            }
            Text(topic.capitalized)
        }
        .font(Theme.Text.meta)
        return Button {
            KineticGate.suppressed = false   // direct tap earns the kinetic cascade
            withAnimation(Theme.Motion.snappy) {
                // Epoch bump must live inside the transaction or the pill's fade transition
                // runs un-animated (a hard cut) instead of fading in at the target chip.
                if let a = store.topicBar.firstIndex(of: store.selectedTopic),
                   let b = store.topicBar.firstIndex(of: topic), abs(a - b) > 1 {
                    pillEpoch += 1            // distant topic: pill fades in, doesn't dash
                }
                store.selectedTopic = topic
            }
            if custom { Task { await store.loadCustom(topic) } }
        } label: {
            labelContent
            .overlay { pillMaskedWhite(topic) { labelContent } }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.panel.opacity(chipPanelOpacity(topic, selected: selected, bar: store.topicBar, current: store.selectedTopic)), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.panelBorder.opacity(chipPanelOpacity(topic, selected: selected, bar: store.topicBar, current: store.selectedTopic)), lineWidth: 1))
            .foregroundStyle(.secondary)
            .background(GeometryReader { g in
                Color.clear.preference(key: ChipFramesKey.self, value: [topic: g.frame(in: .named("chipbar"))])
            })
        }
        .buttonStyle(PressableStyle())
        .onDrag {
            draggedTopic = topic
            return NSItemProvider(object: topic as NSString)
        }
        .onDrop(of: [.text], delegate: ChipDropDelegate(item: topic, dragged: $draggedTopic, store: store))
        .contextMenu {
            if custom {
                Button(role: .destructive) { store.removeCustomTopic(topic) } label: {
                    Label("Remove topic", systemImage: "trash")
                }
            }
        }
    }

    /// Interpolated pill rect in chip-bar space (single source of truth).
    private func pillRect() -> CGRect? {
        let bar = store.browse == .topics ? store.topicBar : store.sourceBar
        let current = store.browse == .topics ? store.selectedTopic : store.selectedSource
        guard let idx = bar.firstIndex(of: current), let from = chipFrames[current] else { return nil }
        let p = store.swipeProgress
        let targetItem = bar[(idx + (p > 0 ? 1 : -1) + bar.count) % bar.count]
        let to = chipFrames[targetItem] ?? from
        let f = abs(p)
        return CGRect(x: from.minX + (to.minX - from.minX) * f,
                      y: from.minY,
                      width: from.width + (to.width - from.width) * f,
                      height: from.height)
    }

    /// The selection pill: tracks the finger — interpolates between the current and
    /// target chip frames in proportion to the carousel's live swipe progress.
    @ViewBuilder private var movingIndicator: some View {
        if let r = pillRect() {
            let x = r.minX, wd = r.width, from = r
            Capsule()
                .fill(Theme.selectionGradient)
                .shadow(color: Theme.accent.opacity(0.45), radius: 8, y: 2)
                .frame(width: wd, height: from.height)
                .offset(x: x, y: from.minY)
                .id(pillEpoch)                    // non-adjacent jump: fade out/in, no cross-bar dash
                .transition(.opacity)
                // No value-gated animation: finger updates arrive un-animated (instant tracking),
                // commit/cancel/tap updates arrive inside withAnimation transactions (smooth glide).
        }
    }

    /// White text revealed by the pill itself: the label's white layer is masked to the
    /// pill's rect, so glyphs whiten pixel-by-pixel as the pill's edge crosses them.
    @ViewBuilder private func pillMaskedWhite<L: View>(_ item: String, @ViewBuilder label: () -> L) -> some View {
        if let pf = pillRect(), let cf = chipFrames[item], pf.intersects(cf) {
            label()
                .foregroundStyle(.white)
                .mask(alignment: .topLeading) {
                    Capsule()
                        .frame(width: pf.width, height: pf.height)
                        .offset(x: pf.minX - cf.minX, y: 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
        }
    }

    #if os(macOS)
    @State private var barDragStart: Int? = nil
    private func barDragScroll(_ proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let bar = store.browse == .topics ? store.topicBar : store.sourceBar
                guard !bar.isEmpty else { return }
                if barDragStart == nil {
                    let current = store.browse == .topics ? store.selectedTopic : store.selectedSource
                    barDragStart = bar.firstIndex(of: current) ?? 0
                }
                let target = max(0, min(bar.count - 1, (barDragStart ?? 0) + Int(-v.translation.width / 64)))
                proxy.scrollTo(bar[target], anchor: .center)
            }
            .onEnded { _ in barDragStart = nil }
    }
    #endif

    private func sourceChip(_ source: String) -> some View {
        let selected = store.selectedSource == source
        let labelContent = Text(source)
            .font(Theme.Text.meta)
            .lineLimit(1)
        return Button {
            KineticGate.suppressed = false
            withAnimation(Theme.Motion.snappy) {
                if let a = store.sourceBar.firstIndex(of: store.selectedSource),
                   let b = store.sourceBar.firstIndex(of: source), abs(a - b) > 1 {
                    pillEpoch += 1
                }
                store.selectedSource = source
            }
        } label: {
            labelContent
                .overlay { pillMaskedWhite(source) { labelContent } }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.panel.opacity(chipPanelOpacity(source, selected: selected, bar: store.sourceBar, current: store.selectedSource)), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : Theme.panelBorder.opacity(chipPanelOpacity(source, selected: selected, bar: store.sourceBar, current: store.selectedSource)), lineWidth: 1))
                .foregroundStyle(.secondary)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChipFramesKey.self, value: [source: g.frame(in: .named("chipbar"))])
                })
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

/// Click-and-drag a chip onto another to reorder your topic bar (persisted).
struct ChipDropDelegate: DropDelegate {
    let item: String
    @Binding var dragged: String?
    let store: FeedStore

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != item,
              let from = store.enabledTopics.firstIndex(of: dragged),
              let to = store.enabledTopics.firstIndex(of: item) else { return }
        withAnimation(Theme.Motion.snappy) {
            store.enabledTopics.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct ChipFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Splash — v2.5's converging fly-in: "News" from above, "First" from below,
// spring-settling into one wordmark (damping 15 / stiffness 120 ≈ response .57, fraction .7).

struct SplashView: View {
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvas.ignoresSafeArea()
                HStack(spacing: 0) {
                    Text("News")
                        .offset(y: settled ? 0 : -90)
                        .opacity(settled ? 1 : 0)
                    Text("First")
                        .offset(y: settled ? 0 : 90)
                        .opacity(settled ? 1 : 0)
                }
                .font(.system(size: 48, weight: .black))
                .kerning(-1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.92)) { settled = true }
        }
    }
}
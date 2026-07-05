import SwiftUI

/// App shell: pulsing splash → header (brand + view toggle + settings) → topic chips → feed.
struct RootView: View {
    @Environment(FeedStore.self) private var store
    @State private var showSettings = false
    @State private var showSplash = true
    @State private var showAuth = false
    @State private var showInbox = false
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
        .sheet(item: $store.story) { StoryView(seed: $0) }
        .sheet(isPresented: $showInbox) { BreakingInboxView() }
        .environment(\.openAuth, { showAuth = true })
        .onAppear { Analytics.capture("app_open") }
        .task {
            PushManager.shared.openArticle = { articleID, _ in
                Task { await store.openArticle(id: articleID) }
            }
            PushManager.shared.flushPendingOpen()   // cold start from a notification tap
            await PushManager.shared.registerIfAuthorized()
        }
        .task {
            // Headless smoke test for the studio voice (CI/sim): KOKORO_SELFTEST=1.
            guard ProcessInfo.processInfo.environment["KOKORO_SELFTEST"] == "1" else { return }
            do {
                let clock = ContinuousClock()
                let start = clock.now
                let samples = try await KokoroEngine.shared.synthesize("Good morning. Here's your briefing. On Bitcoin, from CoinDesk: prices rallied overnight as whales accumulated.")
                print("KOKORO_SELFTEST ok samples=\(samples.count) audioSecs=\(Double(samples.count) / 24_000) elapsed=\(clock.now - start)")
            } catch {
                print("KOKORO_SELFTEST FAILED: \(error)")
            }
        }
        .task(id: "\(store.browse.rawValue)|\(store.selectedTopic)|\(store.selectedSource)") {
            await store.backfillIfSparse()
        }
        .task {
            // Fly-in needs ~550ms to land; beyond that, hold only while the cache load
            // still owes us a feed (bounded) — a fixed 950ms floor broke the <1s budget.
            try? await Task.sleep(for: .milliseconds(550))
            for _ in 0..<8 where !store.hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(50))
            }
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
                    // Icon-only: the header now also carries the alerts bell (v2.5
                    // parity) and TOPICS/SOURCES text didn't fit alongside it.
                    Image(systemName: store.browse == .topics ? "square.grid.2x2" : "dot.radiowaves.up.forward")
                        .font(.footnote.bold())
                        .accessibilityLabel(store.browse.rawValue)
                        .fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 9)
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
            Button { showInbox = true } label: {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .topTrailing) {
                        let n = store.breakingStories.count
                        if n > 0 {
                            Text("\(n)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4.5).padding(.vertical, 1.5)
                                .background(Theme.tierHigh, in: Capsule())
                                .offset(x: 9, y: -9)
                        }
                    }
            }
            .buttonStyle(PressableStyle())
            Spacer(minLength: 2).frame(maxWidth: 10)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)    // safe area already clears the status bar; 12 was dead air
        .padding(.bottom, 10)
    }

    private enum DragAxis { case horizontal, vertical }
    @State private var dragAxis: DragAxis?
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
                        // Latch the axis on first movement: re-evaluating per frame let a
                        // diagonal scroll flip horizontal mid-gesture — the feed lurched
                        // sideways by the full accumulated translation in one frame.
                        if dragAxis == nil {
                            dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                        }
                        guard dragAxis == .horizontal else { return }
                        feedDrag = max(-w, min(w, v.translation.width))   // only 3 panes exist — never expose blank canvas
                        store.swipeProgress = max(-1, min(1, -v.translation.width / w))
                    }
                    .onEnded { v in
                        defer { dragAxis = nil }
                        guard dragAxis == .horizontal else { return }   // a vertical flick must never commit a topic change
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
        let item = store.barItem(offset: offset)
        Group {
            if items.isEmpty {
                if store.browse == .topics, store.isCustomPending(item) {
                    FeedSkeleton(mode: store.mode)   // search in flight — never a black void
                } else {
                    EmptyTopicView(topic: item)
                }
            } else {
                switch store.mode {
                case .list: ListFeedView(topic: item, items: items)
                case .immersive: ImmersiveFeedView(topic: item, items: items)
                case .full: FullFeedView(items: items)
                }
            }
        }
        .frame(width: width)
        .id("\(store.mode.rawValue)-\(store.browse.rawValue)-\(store.barItem(offset: offset))")
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

    /// Chip surface (panel + border) opacity, continuous through swipes: the chip the
    /// pill is LEAVING fades its surface back in with progress, the chip it's ARRIVING
    /// at fades out — `selected` alone flips only at commit completion, which left the
    /// outgoing chip borderless until the animation finished.
    private func chipPanelOpacity(_ item: String, selected: Bool, bar: [String], current: String) -> Double {
        let p = store.swipeProgress
        if selected { return abs(p) }   // pill departing → surface returns in sync
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
            } else if topic == FeedStore.topStories {
                Image(systemName: "flame.fill").font(.caption2)
            }
            Text(FeedStore.displayName(topic))
            // v2.5's ✕ on the active chip: presets disable, customs delete. Replaces the
            // long-press context menu, whose recognizer was also blocking drag-to-reorder.
            if selected, topic != FeedStore.topStories {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .opacity(0.85)
                    .onTapGesture { store.removeFromBar(topic) }
            }
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
            .overlay(Capsule().strokeBorder(Theme.panelBorder.opacity(chipPanelOpacity(topic, selected: selected, bar: store.topicBar, current: store.selectedTopic)), lineWidth: 1))
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
        // ALWAYS mounted: gating this view on pill/chip intersection made commits remove
        // it structurally, and the default removal fade kept the old title white for the
        // whole commit animation. Mounted permanently, the MASK's offset animates inside
        // the commit transaction — the white sweeps off/onto glyphs with the pill's edge.
        label()
            .foregroundStyle(.white)
            .mask(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let pf = pillRect(), let cf = chipFrames[item] {
                        // The overlay lives on the un-padded label (origin = chip origin +
                        // content insets); uncorrected, the reveal led the pill edge by 14pt.
                        Capsule()
                            .frame(width: pf.width, height: pf.height)
                            .offset(x: pf.minX - cf.minX - 14, y: -8)
                            .id(pillEpoch)          // non-adjacent jump: fade with the pill, never sweep the bar
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .overlay(Capsule().strokeBorder(Theme.panelBorder.opacity(chipPanelOpacity(source, selected: selected, bar: store.sourceBar, current: store.selectedSource)), lineWidth: 1))
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
                .onAppear { draftFocused = true }   // focus once mounted; focusing pre-insert was dropped sometimes
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
        guard let dragged else { return }
        store.moveChip(dragged, before: item)
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
            // v2.5's character: land with a visible bounce (Tom's call — brand moment,
            // exempt from the no-overshoot feed rule).
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { settled = true }
        }
    }
}
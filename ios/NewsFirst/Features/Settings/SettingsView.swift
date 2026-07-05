import SwiftUI

/// Settings — a real page in the app's design language, not a stock form.
struct SettingsView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [FeedSource] = []
    @State private var showSources = false
    @State private var newTopic = ""
    var snapshotStatic = false   // ImageRenderer can't rasterise ScrollView; demo snapshots render flat

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            scrollContainer {
                VStack(spacing: 18) {
                    section("Appearance", icon: "circle.lefthalf.filled") {
                        HStack(spacing: 8) {
                            ForEach(Appearance.allCases) { a in
                                let selected = store.appearance == a
                                let enabled = true
                                Button {
                                    withAnimation(Theme.Motion.snappy) { store.appearance = a }
                                } label: {
                                    Text(a.rawValue)
                                        .font(Theme.Text.meta)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .glassChip(prominent: selected)
                                        .foregroundStyle(selected ? AnyShapeStyle(.white) : (enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
                                }
                                .buttonStyle(PressableStyle())
                                .disabled(!enabled)
                            }
                            Spacer()
                        }
                    }

                    section("Default view", icon: "rectangle.3.group") {
                        HStack(spacing: 8) {
                            ForEach(ViewMode.allCases) { m in
                                let selected = store.defaultMode == m
                                Button {
                                    withAnimation(Theme.Motion.snappy) { store.defaultMode = m; store.mode = m }
                                } label: {
                                    Text(m.rawValue)
                                        .font(Theme.Text.meta)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .glassChip(prominent: selected)
                                        .foregroundStyle(selected ? .white : .secondary)
                                }
                                .buttonStyle(PressableStyle())
                            }
                            Spacer()
                        }
                    }

                    section("Home region", icon: "globe.europe.africa.fill", footer: "Top Stories leans toward your region's news — Westminster for UK readers, not Brisbane bail laws.") {
                        HStack(spacing: 8) {
                            ForEach(RegionBucket.allCases) { r in
                                let selected = store.regionPref == r
                                Button {
                                    withAnimation(Theme.Motion.snappy) { store.regionPref = r }
                                } label: {
                                    Text(r == .auto ? "Auto · \(RegionBucket.detected.rawValue)" : r.rawValue)
                                        .font(Theme.Text.meta)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .glassChip(prominent: selected)
                                        .foregroundStyle(selected ? .white : .secondary)
                                }
                                .buttonStyle(PressableStyle())
                            }
                            Spacer()
                        }
                    }

                    section("Your topics", icon: "square.grid.2x2") {
                        FlowChips(items: FeedStore.presetTopics, isOn: { store.enabledTopics.contains($0) }) { topic, on in
                            withAnimation(Theme.Motion.snappy) {
                                if on { store.enabledTopics.append(topic) }
                                else { store.enabledTopics.removeAll { $0 == topic } }
                            }
                        }
                    }

                    section("Custom topics", icon: "dot.radiowaves.left.and.right", footer: "Custom topics match any article mentioning your keywords — the heart of NewsFirst.") {
                        VStack(spacing: 10) {
                            ForEach(store.customTopics, id: \.self) { topic in
                                HStack {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.caption).foregroundStyle(Theme.accent)
                                    Text(topic.capitalized).font(Theme.Text.rowTitle)
                                    Spacer()
                                    Button {
                                        store.removeCustomTopic(topic)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)
                                            .padding(7)
                                            .background(.primary.opacity(0.06), in: Circle())
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                            HStack(spacing: 10) {
                                TextField("Add keyword (e.g. rare earth)", text: $newTopic)
                                    .textFieldStyle(.plain)
                                    .font(Theme.Text.rowTitle)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(.primary.opacity(0.05), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 1))
                                    .onSubmit(addTopic)
                                Button(action: addTopic) {
                                    Image(systemName: "plus")
                                        .font(.footnote.bold())
                                        .foregroundStyle(.white)
                                        .padding(9)
                                        .background(Theme.accent, in: Circle())
                                        .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                                }
                                .buttonStyle(PressableStyle())
                                .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }

                    section("Sources", icon: "antenna.radiowaves.left.and.right", footer: "Disabled sources disappear from every feed.") {
                        Button { showSources = true } label: {
                            HStack {
                                Text("Manage sources").font(Theme.Text.rowTitle).foregroundStyle(.primary)
                                Spacer()
                                if !sources.isEmpty {
                                    Text("\(sources.count - store.disabledSources.count) of \(sources.count) on")
                                        .font(Theme.Text.meta).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }

                    section("Briefing voice", icon: "waveform", footer: "The studio voice is a one-time 86 MB download and runs entirely on this device — nothing leaves your phone.") {
                        StudioVoiceControls()
                    }

                    section("Reading", icon: "doc.plaintext") {
                        Toggle(isOn: $store.readerMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open in Reader").font(Theme.Text.rowTitle)
                                Text("Distraction-free article view when available.")
                                    .font(Theme.Text.meta).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    }

                    section("Developer", icon: "wrench.and.screwdriver") {
                        Toggle(isOn: $store.showPriorityDebug) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Priority debug").font(Theme.Text.rowTitle)
                                Text("Show each article's raw score and tier on the feed.")
                                    .font(Theme.Text.meta).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    }

                    section("Notifications", icon: "bell.badge") {
                        Text("Keyword alerts, per-topic levels (all / high only), quiet hours and the daily brief arrive with the next phase.")
                            .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                    }

                    section("Account", icon: "person.crop.circle") {
                        AccountSection()
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.canvas)
        .preferredColorScheme(store.appearance.scheme)   // honour the user's own Appearance setting
        .task {
            await store.loadSources()   // cached in the store — no re-fetch per settings open
            sources = store.sources
        }
        .sheet(isPresented: $showSources) { SourcesView() }
        #if os(macOS)
        .frame(width: 393, height: 780)
        #endif
    }

    @ViewBuilder
    private func scrollContainer(@ViewBuilder _ content: () -> some View) -> some View {
        if snapshotStatic { content() } else { ScrollView { content() } }
    }

    private var header: some View {
        HStack {
            Text("Settings").font(Theme.Text.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .foregroundStyle(.primary)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, footer: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.caption.bold()).foregroundStyle(Theme.accent)
                Text(title.uppercased())
                    .font(Theme.Text.badge)
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.panelBorder, lineWidth: 1))
            if let footer {
                Text(footer).font(Theme.Text.meta).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
    }

    private func addTopic() {
        store.addCustomTopic(newTopic)
        newTopic = ""
    }
}

struct AccountSection: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.openAuth) private var openAuth
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthClient.shared

    var body: some View {
        if auth.isSignedIn {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Signed in as", value: auth.email ?? "—")
                    .font(Theme.Text.rowTitle)
                Button(role: .destructive) { auth.signOut() } label: {
                    Text("Sign out").font(Theme.Text.rowTitle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tierHigh)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Browsing as guest. Sign in to sync topics and enable keyword alerts.")
                    .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                Button {
                    dismiss()
                    openAuth()
                } label: {
                    Text("Sign in")
                        .font(Theme.Text.rowTitle).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.selectionGradient, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

/// Sources get their own page: 119 toggles were swallowing the settings sheet.
/// Sortable by category or A–Z.
struct SourcesView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private enum Sort { case category, alphabetical }
    @State private var sort: Sort = .category

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sources").font(Theme.Text.headline)
                Spacer()
                Button {
                    withAnimation(Theme.Motion.snappy) { sort = sort == .category ? .alphabetical : .category }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption2.bold())
                        Text(sort == .category ? "By category" : "A–Z").font(Theme.Text.badge)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassChip()
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.primary)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.sources.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 30)
                    } else if sort == .alphabetical {
                        ForEach(store.sources.sorted { $0.name < $1.name }) { sourceRow($0) }
                    } else {
                        let grouped = Dictionary(grouping: store.sources, by: \.category)
                        ForEach(grouped.keys.sorted(), id: \.self) { category in
                            Text(category.uppercased())
                                .font(Theme.Text.badge).foregroundStyle(.secondary).kerning(0.8)
                                .padding(.top, 12).padding(.horizontal, 4)
                            ForEach(grouped[category]!.sorted { $0.name < $1.name }) { sourceRow($0) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.canvas)
        .preferredColorScheme(store.appearance.scheme)
        .task { await store.loadSources() }
    }

    private func sourceRow(_ source: FeedSource) -> some View {
        Toggle(isOn: Binding(
            get: { !store.disabledSources.contains(source.name) },
            set: { on in
                if on { store.disabledSources.remove(source.name) }
                else { store.disabledSources.insert(source.name) }
            }
        )) {
            HStack(spacing: 8) {
                Text(source.name).font(Theme.Text.rowTitle)
                if sort == .alphabetical {
                    Text(source.category.capitalized)
                        .font(Theme.Text.badge)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.primary.opacity(0.07), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Kokoro studio voice: download → progress → voice picker.
struct StudioVoiceControls: View {
    @State private var engine = KokoroEngine.shared

    var body: some View {
        switch engine.state {
        case .notInstalled, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let why) = engine.state {
                    Text("Download failed: \(why)").font(Theme.Text.meta).foregroundStyle(Theme.tierHigh)
                }
                Button { engine.download() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").font(.footnote)
                        Text("Download studio voice · 86 MB").font(Theme.Text.rowTitle)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.selectionGradient, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                Text("Until then, playback uses the built-in Apple voice.")
                    .font(Theme.Text.meta).foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress).tint(Theme.accent)
                Text("Downloading… \(Int(progress * 100))%").font(Theme.Text.meta).foregroundStyle(.secondary)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Warming up…").font(Theme.Text.meta).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 8) {
                ForEach(KokoroEngine.voices, id: \.id) { v in
                    let selected = engine.voice == v.id
                    Button {
                        withAnimation(Theme.Motion.snappy) { engine.voice = v.id }
                    } label: {
                        Text(v.label)
                            .font(Theme.Text.meta)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glassChip(prominent: selected)
                            .foregroundStyle(selected ? .white : .secondary)
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer()
            }
        }
    }
}

/// Wrapping chip grid for topic toggles.
struct FlowChips: View {
    let items: [String]
    let isOn: (String) -> Bool
    let toggle: (String, Bool) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = isOn(item)
                Button { toggle(item, !on) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "checkmark" : "plus")
                            .font(.caption2.bold())
                        Text(item.capitalized).font(Theme.Text.meta)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .glassChip(prominent: on)
                    .foregroundStyle(on ? .white : .secondary)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

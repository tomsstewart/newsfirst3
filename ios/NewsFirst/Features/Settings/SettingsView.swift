import SwiftUI

/// Settings — a real page in the app's design language, not a stock form.
struct SettingsView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [FeedSource] = []
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
                                let enabled = a != .light   // light palette lands with the design pass
                                Button {
                                    withAnimation(Theme.Motion.snappy) { store.appearance = a }
                                } label: {
                                    Text(a == .light ? "Light · soon" : a.rawValue)
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
                                            .background(.white.opacity(0.06), in: Circle())
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                            HStack(spacing: 10) {
                                TextField("Add keyword (e.g. rare earth)", text: $newTopic)
                                    .textFieldStyle(.plain)
                                    .font(Theme.Text.rowTitle)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(.white.opacity(0.05), in: Capsule())
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
                        if sources.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 8)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(sources) { source in
                                    Toggle(isOn: Binding(
                                        get: { !store.disabledSources.contains(source.name) },
                                        set: { on in
                                            if on { store.disabledSources.remove(source.name) }
                                            else { store.disabledSources.insert(source.name) }
                                        }
                                    )) {
                                        HStack(spacing: 8) {
                                            Text(source.name).font(Theme.Text.rowTitle)
                                            Text(source.category.capitalized)
                                                .font(Theme.Text.badge)
                                                .padding(.horizontal, 7).padding(.vertical, 2)
                                                .background(.white.opacity(0.07), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.switch)
                                    .tint(Theme.accent)
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                    }

                    section("Notifications", icon: "bell.badge") {
                        Text("Keyword alerts, per-topic levels (all / high only), quiet hours and the daily brief arrive with the next phase.")
                            .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                    }

                    section("Account", icon: "person.crop.circle") {
                        Text("Browsing as guest. Sign in with Apple/Google lands with notifications — your topics will sync automatically.")
                            .font(Theme.Text.excerpt).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .task { sources = (try? await SupabaseAPI().fetchSources()) ?? [] }
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

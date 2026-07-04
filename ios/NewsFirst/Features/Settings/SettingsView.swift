import SwiftUI

/// Settings — mirrors v2's structure (Content / Account) with working controls.
/// Notification management lands with the alert wiring (next phase).
struct SettingsView: View {
    @Environment(FeedStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [FeedSource] = []
    @State private var newTopic = ""

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("Content") {
                    Picker("Appearance", selection: $store.appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Default view", selection: $store.defaultMode) {
                        ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Your topics") {
                    ForEach(FeedStore.presetTopics, id: \.self) { topic in
                        Toggle(topic.capitalized, isOn: Binding(
                            get: { store.enabledTopics.contains(topic) },
                            set: { on in
                                withAnimation(Theme.Motion.snappy) {
                                    if on { store.enabledTopics.append(topic) }
                                    else { store.enabledTopics.removeAll { $0 == topic } }
                                }
                            }
                        ))
                    }
                }

                Section {
                    ForEach(store.customTopics, id: \.self) { topic in
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                            Text(topic.capitalized)
                            Spacer()
                            Button(role: .destructive) { store.removeCustomTopic(topic) } label: {
                                Image(systemName: "trash").font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add custom topic (e.g. rare earth)", text: $newTopic)
                            .onSubmit(addTopic)
                        Button("Add", action: addTopic)
                            .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Custom topics")
                } footer: {
                    Text("Custom topics match any article mentioning your keywords — the heart of NewsFirst.")
                }

                Section("Sources") {
                    if sources.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    ForEach(sources) { source in
                        Toggle(isOn: Binding(
                            get: { !store.disabledSources.contains(source.name) },
                            set: { on in
                                if on { store.disabledSources.remove(source.name) }
                                else { store.disabledSources.insert(source.name) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.category.capitalized).font(Theme.Text.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Notifications") {
                    LabeledContent("Manage notifications", value: "After next demo")
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    LabeledContent("Status", value: "Guest — sign-in lands with notifications")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            sources = (try? await SupabaseAPI().fetchSources()) ?? []
        }
        #if os(macOS)
        .frame(width: 393, height: 700)
        #endif
    }

    private func addTopic() {
        store.addCustomTopic(newTopic)
        newTopic = ""
    }
}

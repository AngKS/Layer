import Observation
import SwiftUI

/// What the settings sheet knows about one hosted provider while it is open.
@MainActor @Observable
final class ProviderSettings: Identifiable {
    nonisolated let provider: HostedProvider
    var keyDraft = ""
    /// The server address being edited, for a self-hosted provider.
    var serverDraft: String
    private(set) var hasKey: Bool
    private(set) var models: [HostedModelInfo]
    private(set) var isFetching = false
    private(set) var error: String?
    @ObservationIgnored private var fetch: Task<Void, Never>?

    nonisolated var id: String { provider.id }

    init(_ provider: HostedProvider) {
        self.provider = provider
        hasKey = APIKeyStore.hasKey(for: provider)
        models = ModelPreferences.knownModels(for: provider)
        serverDraft = ModelPreferences.server(for: provider)
    }

    /// Whether the provider can be used now: it has a key, or needs none.
    var isConfigured: Bool { hasKey || !provider.requiresKey }

    /// Saves the server address and looks for the models it serves.
    func saveServer() {
        ModelPreferences.setServer(serverDraft, for: provider)
        serverDraft = ModelPreferences.server(for: provider)
        fetchModels()
    }

    /// Saves the typed key in the Keychain and fetches the models it can use.
    func saveKey() {
        do {
            try APIKeyStore.setKey(keyDraft, for: provider)
            keyDraft = ""
            hasKey = APIKeyStore.hasKey(for: provider)
            error = nil
            NotificationCenter.default.post(name: ModelPreferences.changed, object: nil)
            fetchModels()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeKey() {
        fetch?.cancel()
        try? APIKeyStore.removeKey(for: provider)
        hasKey = false
        error = nil
        NotificationCenter.default.post(name: ModelPreferences.changed, object: nil)
    }

    /// Asks the provider which models the saved key can use. The last list fetched stays
    /// in place, and on screen, if this fails.
    func fetchModels() {
        let key = APIKeyStore.key(for: provider)
        guard key != nil || !provider.requiresKey else { return }
        fetch?.cancel()
        isFetching = true
        error = nil
        fetch = Task { [weak self, provider] in
            do {
                let found = try await HostedModelClient.models(for: provider, key: key)
                guard let self, !Task.isCancelled else { return }
                models = found
                ModelPreferences.remember(found, for: provider)
                if found.isEmpty {
                    error = provider.isLocal ? "\(provider.name) has no models downloaded." : "This key can't use any models that answer chat."
                }
                NotificationCenter.default.post(name: ModelPreferences.changed, object: nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self?.isFetching = false
        }
    }
}

/// Layer's settings: which model reads sketches and names boards, and the keys for
/// hosted models. Opened from the cog on the document browser.
struct ModelSettingsView: View {
    var onDone: () -> Void = {}

    @State private var providers = HostedProvider.allCases.map { ProviderSettings($0) }
    @State private var defaultChoice = ModelPreferences.defaultChoice
    /// Whether squeezing Apple Pencil Pro over the canvas listens for a command. Off, the
    /// squeeze does what the system's Apple Pencil settings say, as in any other app; over a
    /// number field or the zoom control it still scrubs, unless those settings turn squeezing
    /// off or give it a shortcut.
    @AppStorage(AppModel.squeezesToTalkKey, store: AppSettings.defaults) private var squeezesToTalk = true
    /// Whether the pencil's bubble shows the words it hears, under the sound of them.
    /// Off, it is the model's icon and the waveform alone.
    @AppStorage("pencilVoice.showsWords") private var showsWords = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModelChoicePicker(choice: $defaultChoice, providers: providers)
                } header: {
                    Text("Model for New Designs")
                } footer: {
                    Text(defaultFooter)
                }

                Section {
                    // The app's setting, which every open design follows at once.
                    Toggle("Squeeze to Talk", isOn: Binding(get: { squeezesToTalk }, set: { AppModel.setSqueezesToTalk($0) }))
                    // The bubble is only there while the pencil listens.
                    if squeezesToTalk {
                        Toggle("Show Words in the Pencil Bubble", isOn: $showsWords)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(voiceFooter)
                }

                if HostedLanguageModel.isSupported {
                    ForEach(providers) { settings in
                        ProviderSection(settings: settings)
                    }
                } else {
                    Section {
                        Label("Models from Anthropic and OpenAI need iPadOS 27.2 or later.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .onChange(of: defaultChoice) { _, choice in ModelPreferences.defaultChoice = choice }
        // Lists are fetched again each time the sheet opens, so they stay current.
        .task {
            for settings in providers where settings.isConfigured { settings.fetchModels() }
        }
    }

    private var voiceFooter: String {
        squeezesToTalk
            ? "Squeeze Apple Pencil Pro over the canvas to speak a command about what the pen is over. "
                + "The bubble at the tip shows the model listening, and the words it hears if you like. "
                + "If the squeeze is turned off or runs a shortcut in Apple Pencil settings, that comes first."
            : "Squeezing Apple Pencil Pro does what you chose for it in Apple Pencil settings, as in any other app. "
                + "Over a number field or the zoom control it still scrubs, unless you turned squeezing off or gave it a shortcut there. "
                + "Turn this on to speak a command by squeezing over the canvas."
    }

    private var defaultFooter: String {
        "Each design keeps the model it was made with; change a design's own in its Magic Pen settings. "
            + "Apple Intelligence runs on this iPad. Anthropic and OpenAI models run on their servers, "
            + "and LM Studio on your own computer: descriptions of your sketches are sent to them."
    }
}

/// One provider: its key and the models it offers.
private struct ProviderSection: View {
    @Bindable var settings: ProviderSettings

    var body: some View {
        Section {
            if settings.provider.defaultServer != nil {
                LabeledContent("Server") {
                    TextField(settings.provider.defaultServer ?? "", text: $settings.serverDraft)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(settings.saveServer)
                        .accessibilityLabel("\(settings.provider.name) server address")
                }
                Button("Connect", systemImage: "network") { settings.saveServer() }
                    .disabled(settings.isFetching)
            }
            if settings.hasKey {
                LabeledContent("API Key") {
                    Label("Saved in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh Models", systemImage: "arrow.clockwise") { settings.fetchModels() }
                        .disabled(settings.isFetching)
                    Spacer()
                    Button("Remove Key", role: .destructive) { settings.removeKey() }
                }
                .buttonStyle(.borderless)
            } else {
                SecureField(settings.provider.keyPlaceholder, text: $settings.keyDraft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(settings.saveKey)
                    .accessibilityLabel("\(settings.provider.name) API key")
                Button("Save Key", systemImage: "key") { settings.saveKey() }
                    .disabled(settings.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !settings.provider.requiresKey, !settings.hasKey, !settings.models.isEmpty {
                Button("Refresh Models", systemImage: "arrow.clockwise") { settings.fetchModels() }
                    .disabled(settings.isFetching)
            }

            if settings.isFetching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding models…").foregroundStyle(.secondary)
                }
            } else if settings.isConfigured, !settings.models.isEmpty {
                Text(settings.models.count == 1 ? "1 model available" : "\(settings.models.count) models available")
                    .foregroundStyle(.secondary)
            }
            if let error = settings.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } header: {
            Label(settings.provider.name, systemImage: settings.provider.symbol)
        } footer: {
            if settings.provider.isLocal {
                Text("Runs on your own computer: start LM Studio's server, and use this Mac's address on the local network from an iPad.")
            } else if !settings.hasKey {
                Link("Get an \(settings.provider.name) API key", destination: settings.provider.keyPage)
            }
        }
    }
}

/// Chooses Apple Intelligence or one of the hosted models whose provider has a key.
/// Used both for the default and for a single design.
struct ModelChoicePicker: View {
    @Binding var choice: ModelChoice
    /// Live provider state when shown in Settings; nil reads what is saved.
    var providers: [ProviderSettings]?

    var body: some View {
        Picker("Model", selection: $choice) {
            Label(SketchProvider.appleIntelligence.name, systemImage: SketchProvider.appleIntelligence.symbol)
                .tag(ModelChoice.appleIntelligence)
            if HostedLanguageModel.isSupported {
                ForEach(HostedProvider.allCases) { provider in
                    let models = models(for: provider)
                    if !models.isEmpty {
                        Section(provider.name) {
                            ForEach(models) { model in
                                Text(model.name).tag(ModelChoice.hosted(provider, model: model.id))
                            }
                        }
                    }
                }
            }
            // A design's choice whose model or key isn't here any more still shows as chosen.
            if !isOffered(choice) {
                Text(choice.displayName).tag(choice)
            }
        }
        .pickerStyle(.menu)
    }

    private func models(for provider: HostedProvider) -> [HostedModelInfo] {
        if let live = providers?.first(where: { $0.provider == provider }) {
            return live.isConfigured ? live.models : []
        }
        return ModelPreferences.isConfigured(provider) ? ModelPreferences.knownModels(for: provider) : []
    }

    private func isOffered(_ choice: ModelChoice) -> Bool {
        guard let provider = choice.hostedProvider else { return true }
        return HostedLanguageModel.isSupported && models(for: provider).contains { $0.id == choice.model }
    }
}

import Observation
import SwiftUI

/// What the settings sheet knows about one hosted provider while it is open.
@MainActor @Observable
final class ProviderSettings: Identifiable {
    nonisolated let provider: HostedProvider
    var keyDraft = ""
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
        guard let key = APIKeyStore.key(for: provider) else { return }
        fetch?.cancel()
        isFetching = true
        error = nil
        fetch = Task { [weak self, provider] in
            do {
                let found = try await HostedModelClient.models(for: provider, key: key)
                guard let self, !Task.isCancelled else { return }
                models = found
                ModelPreferences.remember(found, for: provider)
                if found.isEmpty { error = "This key can't use any models that answer chat." }
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
            for settings in providers where settings.hasKey { settings.fetchModels() }
        }
    }

    private var defaultFooter: String {
        "Each design keeps the model it was made with; change a design's own in its Magic Pen settings. "
            + "Apple Intelligence runs on this iPad. Anthropic and OpenAI models run on their servers: "
            + "descriptions of your sketches are sent to them."
    }
}

/// One provider: its key and the models it offers.
private struct ProviderSection: View {
    @Bindable var settings: ProviderSettings

    var body: some View {
        Section {
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

            if settings.isFetching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding models…").foregroundStyle(.secondary)
                }
            } else if settings.hasKey, !settings.models.isEmpty {
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
            if !settings.hasKey {
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
            return live.hasKey ? live.models : []
        }
        return APIKeyStore.hasKey(for: provider) ? ModelPreferences.knownModels(for: provider) : []
    }

    private func isOffered(_ choice: ModelChoice) -> Bool {
        guard let provider = choice.hostedProvider else { return true }
        return HostedLanguageModel.isSupported && models(for: provider).contains { $0.id == choice.model }
    }
}

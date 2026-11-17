import Foundation

/// Which model a design reads its sketches and suggests its name with. Saved in the
/// design's own file (`CanvasSettings.model`), so each design keeps its own choice
/// wherever it is opened. The key isn't part of it: keys stay in this device's Keychain.
struct ModelChoice: Codable, Hashable, Sendable {
    /// `apple-intelligence`, or a `HostedProvider`'s raw value.
    var provider: String
    /// The model's identifier; nil for Apple Intelligence, which has one model.
    var model: String?

    static let appleIntelligence = ModelChoice(provider: SketchProvider.appleIntelligence.id, model: nil)

    static func hosted(_ provider: HostedProvider, model: String) -> ModelChoice {
        ModelChoice(provider: provider.rawValue, model: model)
    }

    var hostedProvider: HostedProvider? { HostedProvider(rawValue: provider) }

    /// "Apple Intelligence", or "Anthropic · Claude Sonnet 4.5".
    var displayName: String {
        guard let hosted = hostedProvider else { return SketchProvider.appleIntelligence.name }
        guard let model else { return hosted.name }
        let name = ModelPreferences.knownModels(for: hosted).first { $0.id == model }?.name ?? model
        return "\(hosted.name) · \(name)"
    }

    var symbol: String { hostedProvider?.symbol ?? SketchProvider.appleIntelligence.symbol }

    /// The sketch provider this choice runs. A hosted model this system can't run, or one
    /// a newer Layer added that this one doesn't know, falls back to Apple Intelligence.
    var sketchProvider: SketchProvider {
        guard let hosted = hostedProvider, let model, HostedLanguageModel.isSupported else { return .appleIntelligence }
        return .hosted(hosted, model: model)
    }
}

/// The app-wide part of model settings: the choice new designs start with, and the
/// models each provider was last found to offer. Neither is secret; keys live in
/// `APIKeyStore`.
enum ModelPreferences {
    /// Posted when a key, the default model, or a provider's model list changes.
    static let changed = Notification.Name("kahshin.Layer.modelPreferencesChanged")
    private static let defaultChoiceKey = "defaultModelChoice"
    private static func modelsKey(_ provider: HostedProvider) -> String { "knownModels.\(provider.rawValue)" }

    /// What a new design uses. Apple Intelligence until something else is chosen.
    static var defaultChoice: ModelChoice {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultChoiceKey),
                  let choice = try? JSONDecoder().decode(ModelChoice.self, from: data)
            else { return .appleIntelligence }
            return choice
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultChoiceKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func serverKey(_ provider: HostedProvider) -> String { "server.\(provider.rawValue)" }

    /// The server address set for a self-hosted provider, or its usual one.
    static func server(for provider: HostedProvider) -> String {
        UserDefaults.standard.string(forKey: serverKey(provider)) ?? provider.defaultServer ?? ""
    }

    static func setServer(_ address: String, for provider: HostedProvider) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: serverKey(provider))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The server's API root, `…/v1`, from the address as typed: with or without a scheme or `/v1`.
    static func serverURL(for provider: HostedProvider) -> URL {
        var address = server(for: provider)
        if !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        if !address.hasSuffix("/v1") { address += "/v1" }
        return URL(string: address) ?? URL(string: "http://localhost:1234/v1")!
    }

    /// Whether a provider can be used: it has a key, or needs none.
    static func isConfigured(_ provider: HostedProvider) -> Bool {
        !provider.requiresKey || APIKeyStore.hasKey(for: provider)
    }

    /// The models last fetched for a provider, so pickers can show them without asking again.
    static func knownModels(for provider: HostedProvider) -> [HostedModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: modelsKey(provider)) else { return [] }
        return (try? JSONDecoder().decode([HostedModelInfo].self, from: data)) ?? []
    }

    static func remember(_ models: [HostedModelInfo], for provider: HostedProvider) {
        UserDefaults.standard.set(try? JSONEncoder().encode(models), forKey: modelsKey(provider))
    }
}

extension SketchProvider {
    /// A hosted model as a sketch provider: ready once its provider has a key.
    static func hosted(_ provider: HostedProvider, model: String) -> SketchProvider {
        SketchProvider(
            id: "\(provider.rawValue):\(model)",
            name: ModelChoice.hosted(provider, model: model).displayName,
            symbol: provider.symbol,
            needsAPIKey: true,
            readiness: {
                ModelPreferences.isConfigured(provider) ? .ready : .unavailable(HostedModelError.missingKey(provider).errorDescription ?? "")
            },
            makeInterpreter: { _ in HostedSketchInterpreter(model: HostedLanguageModel(provider: provider, model: model)) }
        )
    }
}

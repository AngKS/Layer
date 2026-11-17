import Foundation

/// A company whose hosted models Layer can use in place of the on-device Apple
/// Intelligence model. Each is reached over HTTPS with the person's own API key, which
/// `APIKeyStore` keeps in the Keychain.
///
/// Adding another means a case here, its two HTTP calls in `HostedModelClient`, and
/// nothing else: the rest of the app (the model protocol conformance, the settings sheet,
/// what each design remembers) is written against this type.
enum HostedProvider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case anthropic
    case openAI = "openai"
    /// A model served by LM Studio, on this Mac or another computer on the network,
    /// through its OpenAI-compatible server.
    case lmStudio = "lmstudio"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .lmStudio: "LM Studio"
        }
    }

    /// Whether requests need an API key. LM Studio's server works without one.
    var requiresKey: Bool { self != .lmStudio }

    /// Whether the provider speaks OpenAI's chat completions format.
    var usesOpenAIFormat: Bool { self != .anthropic }

    /// Whether it runs on a computer the person controls, rather than a company's servers.
    var isLocal: Bool { self == .lmStudio }

    /// Where requests go: the provider's own API, or the server address set in Settings.
    var baseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .lmStudio: ModelPreferences.serverURL(for: self)
        }
    }

    /// The server address when none has been set.
    var defaultServer: String? {
        self == .lmStudio ? "http://localhost:1234" : nil
    }

    var symbol: String {
        switch self {
        case .anthropic: "sparkle"
        case .openAI: "circle.hexagongrid"
        case .lmStudio: "desktopcomputer"
        }
    }

    /// What the provider calls the key, so the field can say what to paste in.
    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .lmStudio: "Key, if the server asks for one"
        }
    }

    /// Where a key is made, shown under the field.
    var keyPage: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .lmStudio: URL(string: "https://lmstudio.ai/docs/app/api")!
        }
    }
}

/// One model a provider offers, as its model list describes it.
struct HostedModelInfo: Codable, Hashable, Sendable, Identifiable {
    /// What requests name it by, such as `claude-sonnet-4-5`.
    var id: String
    /// How people know it, such as "Claude Sonnet 4.5". The identifier when the provider gives no name.
    var name: String
}

/// Why a hosted model couldn't be reached, worded for the settings sheet and the canvas.
enum HostedModelError: LocalizedError, Equatable, Sendable {
    case missingKey(HostedProvider)
    case keyRejected(HostedProvider)
    case offline
    /// A server on the local network that isn't answering.
    case serverUnreachable(HostedProvider)
    case rateLimited(HostedProvider)
    case server(HostedProvider, status: Int, message: String?)
    case unreadableResponse(HostedProvider)
    case refused(HostedProvider, String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "Add an \(provider.name) API key in Settings."
        case .keyRejected(let provider): "\(provider.name) didn't accept this API key. Check it and try again."
        case .offline: "Can't reach the internet. Check the connection and try again."
        case .serverUnreachable(let provider): "Can't reach \(provider.name) at \(provider.baseURL.host() ?? "its address"). Check that its server is running."
        case .rateLimited(let provider): "\(provider.name) is limiting requests right now. Try again in a moment."
        case .server(let provider, let status, let message):
            message.map { "\(provider.name) said: \($0)" } ?? "\(provider.name) couldn't answer (error \(status))."
        case .unreadableResponse(let provider): "\(provider.name) sent an answer Layer couldn't read."
        case .refused(let provider, let reason): "\(provider.name) declined: \(reason)"
        }
    }
}

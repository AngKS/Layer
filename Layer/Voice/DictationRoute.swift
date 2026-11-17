import AVFoundation
import Foundation

/// Listens with the iPad's microphone and turns what is said into text on the iPad, so
/// that only words are ever sent to a model. This is the route every provider can use.
@MainActor
final class DictationRoute: VoiceRoute {
    enum Failure: LocalizedError {
        case microphoneRefused

        var errorDescription: String? {
            switch self {
            case .microphoneRefused:
                "Layer isn't allowed to use the microphone. Allow it in Settings, under Privacy & Security."
            }
        }
    }

    private let microphone = MicrophoneTap()
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    private var listening: Task<Void, Never>?

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        guard await MicrophoneTap.requestAccess() else { throw Failure.microphoneRefused }
        let sound = try microphone.start()
        let (events, continuation) = AsyncStream<VoiceRouteEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        // Off the main actor: sound arrives many times a second.
        listening = Task.detached {
            for await chunk in sound {
                for level in MicrophoneTap.levels(of: chunk.buffer, count: 2) {
                    continuation.yield(.level(level))
                }
            }
        }
        return events
    }

    func stop() {
        microphone.stop()
        listening?.cancel()
        listening = nil
        continuation?.finish()
        continuation = nil
    }
}

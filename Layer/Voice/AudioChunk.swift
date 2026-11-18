import AVFAudio
import Foundation

/// A buffer of sound on its way from the audio thread to whoever is listening. Whoever
/// makes one hands the buffer over once and doesn't touch it again, which is what makes
/// passing it between threads safe.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// When the sound was handed over by the microphone. Chunks can wait in a queue
    /// before they are listened to, and a pause is measured from when it was spoken.
    var time: ContinuousClock.Instant = .now
}

/// Where a call's sound comes from: the microphone, or a recording standing in for it.
@MainActor
protocol VoiceAudioSource: AnyObject {
    /// Starts the sound, asking for whatever permission it needs first. The stream ends
    /// when the source is stopped, or when the sound goes away of its own accord.
    func start() async throws -> AsyncStream<AudioChunk>
    func stop()
    /// The format the sound arrives in. Only meaningful once started.
    var format: AVAudioFormat { get }
}

/// A phrase as a speech recogniser reports it: first as a guess it may revise, then,
/// with `isFinal`, settled.
struct HeardPhrase: Sendable, Equatable {
    var text: String
    var isFinal: Bool
}

/// Something that turns sound into words. Layer's is Apple's recogniser on the iPad
/// (`AppleSpeechRecogniser`); tests have one that hears what they say it hears.
protocol PhraseRecogniser: Sendable {
    /// Gets ready to recognise speech: finds a recogniser for the language and fetches
    /// its model if it has to. Throws where speech can't be recognised at all. Called
    /// before the microphone is turned on, so that it is only on when it can be heard.
    func prepare() async throws
    /// Starts recognising `sound`, which arrives in `format`. `vocabulary` is words
    /// worth listening out for. Phrases come back as they are heard; the stream ends
    /// when the recogniser stops, and throws if it can't go on.
    func start(sound: AsyncStream<AudioChunk>, format: AVAudioFormat, vocabulary: [String]) async throws -> AsyncThrowingStream<HeardPhrase, any Error>
    /// Settles what has been heard so far, without waiting for the recogniser to decide
    /// for itself that the phrase is over. Says whether it did: a recogniser that hasn't
    /// started listening yet has settled nothing, however quickly it returns.
    func settle() async -> Bool
    func stop() async
}

/// How loud sound is, for the waveform.
enum AudioLevel {
    /// How loud a buffer is, from 0 for silence to 1 for a raised voice close to the
    /// microphone. Measured in decibels, as loudness is heard: -50 dB and below is 0,
    /// -10 dB and above is 1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        level(of: buffer, frames: 0..<Int(buffer.frameLength))
    }

    /// The loudness of each of `count` equal stretches of a buffer, in order, so that a
    /// waveform can move more often than buffers arrive.
    static func levels(of buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        let length = Int(buffer.frameLength)
        guard count > 1, length >= count else { return [level(of: buffer)] }
        return (0..<count).map { level(of: buffer, frames: length * $0 / count..<length * ($0 + 1) / count) }
    }

    private static func level(of buffer: AVAudioPCMBuffer, frames: Range<Int>) -> Float {
        guard let channels = buffer.floatChannelData, !frames.isEmpty else { return 0 }
        let samples = UnsafeBufferPointer(start: channels[0] + frames.lowerBound, count: frames.count)
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 40, 0), 1)
    }
}

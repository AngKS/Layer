import AVFoundation

/// A buffer of sound from the microphone, on its way from the audio thread to whoever is
/// listening. The engine hands each buffer over once and doesn't touch it again, which is
/// what makes passing it between threads safe.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// The microphone, as a stream of sound, for as long as a call is up.
@MainActor
final class MicrophoneTap {
    enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "The microphone isn't available right now."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    /// Asks to use the microphone, the first time, and says whether it may be used.
    static func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// The format the sound arrives in. Only meaningful once started.
    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// Starts the microphone. The stream ends when it is stopped.
    func start() throws -> AsyncStream<AudioChunk> {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.unavailable }
        // If the listener falls behind, the oldest sound is what it can best do without.
        let (sound, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        // A tenth of a second at a time, which is the shortest the engine hands over.
        // The underscored name is the one iOS 27's SDK gives the call that reports a
        // failure; the plain one is deprecated and has no Swift name of its own yet.
        // Its error parameter sits before the block, so Swift keeps an empty place for it.
        try input.__installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format, error: ()) { buffer, _ in
            continuation.yield(AudioChunk(buffer: buffer))
        }
        engine.prepare()
        try engine.start()
        return sound
    }

    func stop() {
        guard let continuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
        self.continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// How loud a buffer is, from 0 for silence to 1 for a raised voice close to the
    /// microphone. Measured in decibels, as loudness is heard: -50 dB and below is 0,
    /// -10 dB and above is 1.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        level(of: buffer, frames: 0..<Int(buffer.frameLength))
    }

    /// The loudness of each of `count` equal stretches of a buffer, in order, so that a
    /// waveform can move more often than buffers arrive.
    nonisolated static func levels(of buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        let length = Int(buffer.frameLength)
        guard count > 1, length >= count else { return [level(of: buffer)] }
        return (0..<count).map { level(of: buffer, frames: length * $0 / count..<length * ($0 + 1) / count) }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer, frames: Range<Int>) -> Float {
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

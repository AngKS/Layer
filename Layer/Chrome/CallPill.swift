import SwiftUI

/// Bottom right in a narrow window: starts voice mode. Like the other corner controls it
/// keeps to its corner; the pencil bar may sit over it while Draw is on.
struct PhoneButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.startVoiceCall()
        } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(.circle)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start voice mode")
    }
}

/// Voice mode's call, along the bottom of the canvas while it is up: the model being spoken
/// to, how long the call has run over the sound of the room, and the way to hang up. It
/// grows by a line while there is something to say: the words being heard, what the model
/// is doing, what it did, or what went wrong.
struct CallPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let call = model.voice {
            let canvas = model.store.canvas
            VStack(alignment: .leading, spacing: 8) {
                if let caption = call.caption {
                    CaptionLine(caption: caption, queuedCount: call.queuedCount)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
                HStack(spacing: 12) {
                    Image(systemName: model.modelChoice.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.primary.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        CallTimer(startedAt: call.startedAt)
                        // Read in a view of its own, so that only the bars redraw with each level.
                        CallLevels(call: call)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Voice mode with \(model.modelChoice.displayName)")
                    Spacer(minLength: 8)
                    Button {
                        model.endVoiceCall()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.red, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End voice mode")
                }
            }
            .padding(10)
            .frame(maxWidth: 420)
            // Tinted with the canvas, so the pill belongs to the board it is talking about.
            .glassEffect(.regular.tint(canvas.resolvedBackground.color.opacity(0.7)), in: .rect(cornerRadius: 32, style: .continuous))
            // On a dark canvas the pill is dark, and what is on it is light.
            .environment(\.colorScheme, canvas.isDark ? .dark : .light)
            .animation(.snappy(duration: 0.3), value: call.caption)
            .reportsChromeFrame("call pill", to: model)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// How long the call has been up, counted from when it began to listen.
struct CallTimer: View {
    let startedAt: Date?

    var body: some View {
        Group {
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.text(forSeconds: Int(context.date.timeIntervalSince(startedAt))))
                }
            } else {
                Text(Self.text(forSeconds: 0))
            }
        }
        .font(.system(size: 15, weight: .semibold).monospacedDigit())
        .foregroundStyle(.green)
    }

    /// `0:42`, `1:15`, and `1:02:03` once past the hour.
    static func text(forSeconds seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let (hours, minutes, rest) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// The sound of the room as a row of bars, newest on the right.
struct CallWaveform: View {
    let levels: [Float]

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let count = VoiceCall.levelCount
            // Until the row has filled, the bars heard so far sit at its right-hand end.
            let lead = count - levels.count
            for index in 0..<count {
                let level = index >= lead ? CGFloat(levels[index - lead]) : 0
                let barHeight = max(2, level * size.height)
                let bar = CGRect(
                    x: CGFloat(index) * (Self.barWidth + Self.gap), y: (size.height - barHeight) / 2,
                    width: Self.barWidth, height: barHeight
                )
                context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .style(.primary.opacity(level > 0 ? 0.75 : 0.3)))
            }
        }
        .frame(width: CGFloat(VoiceCall.levelCount) * (Self.barWidth + Self.gap) - Self.gap, height: Self.height)
        .accessibilityHidden(true)
    }
}

/// The line the pill grows to show.
private struct CaptionLine: View {
    let caption: VoiceCall.Caption
    let queuedCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            switch caption.kind {
            case .hearing:
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .said:
                // The model's own words, with nothing done: no tick.
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.secondary)
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(caption.kind == .hearing ? "“\(caption.text)”" : caption.text)
                .font(.subheadline.weight(caption.kind == .hearing ? .regular : .medium))
                .foregroundStyle(caption.kind == .hearing ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if queuedCount > 0 {
                Text("+\(queuedCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(queuedCount) more waiting")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("call caption")
    }
}

/// The call's waveform. The levels change about twenty times a second; read here, they
/// redraw this and not the whole pill.
private struct CallLevels: View {
    let call: VoiceCall

    var body: some View {
        CallWaveform(levels: call.levels)
    }
}

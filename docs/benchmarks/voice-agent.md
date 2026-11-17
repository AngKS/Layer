# Voice agent: commands carried out by a real model

Measured 2026-11-17. This is a first look, not a benchmark with a labelled corpus: each
command was run once.

## What was run

`VoiceAgentLiveTests` puts each command, as typed text, through the same path a call uses:
`VoiceAgent`, the dynamic profile's hosted branch, the fifteen tools, and the design's store.
Nothing was spoken, so speech recognition is not part of these numbers.

- Model: `google/gemma-4-26b-a4b`, served by LM Studio on this Mac through its
  OpenAI-compatible server, with tool calling.
- App: the Layer test host in the "Layer iPad Pro 11 (voice-mode)" simulator, iPadOS 27.2.
- Design: one iPhone screen, "Login", with a title, a "Sign in" button and an image.

To run it again:

```sh
TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b xcodebuild test \
  -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,id=<simulator>" \
  -only-testing:LayerTests/VoiceAgentLiveTests
```

LM Studio loads a model on its first request. A run that starts with the model unloaded
fails its first few commands with "Model is unloaded"; run it again.

## Results

All seven did what was asked.

| Command | What happened | Time |
|---|---|---|
| Make the sign in button green | Button restyled green | 5.7 s |
| Show me the first screen | Canvas went to "Login"; design unchanged | 1.9 s |
| Make the image half width and align it centrally | Resized to 197 pt, then centred | 6.3 s |
| Change the title's text colour to blue and make its content sound like a pirate | Text colour blue; reworded to "Ahoy, Matey!" | 7.5 s |
| Make the sign in button say Continue, then: Now make it half width | Reworded; then "it" resized to 197 pt | 1.6 s, 4.4 s |
| Make the slider wider (there is no slider) | Nothing changed; said "I don't see a slider on this screen." | 3.6 s |
| I want a profile page with user settings | New screen of 14 elements, one undo step | 37.6 s |

A new screen takes far longer than an edit because the screen itself is then written by
the screen generator, element by element.

## What it showed

- **A server can ask for several tools in one answer even when told not to.** LM Studio
  did, for the two-part commands. The session would run those at the same time and in no
  fixed order, so `HostedModelExecutor` now passes on only the first tool of an answer;
  the model asks for the next once it has the first one's result. The two-part commands
  above ran in the order spoken after that change.
- **"It" works across commands.** The second command of the pair found the button from
  the conversation and from the selection the first command left.
- **A command that fits nothing is declined in words,** with nothing changed.

## Not measured here

- Apple Intelligence, which can't answer in the simulator. Its profile is the compact one,
  with fewer tools on an empty canvas.
- Anthropic and OpenAI. Their requests and tool calls are covered by tests against
  stubbed responses, not by a live run.
- Speech recognition, and how misheard words affect a command.

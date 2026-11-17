# Screen generation and sketch hints: prompt changes (2026-11-18)

Branch `feature/generation-prompts`. Measured natively on macOS with the on-device
Apple Intelligence model (calls fail in the simulator).

## Screen generation: old prompt against `ScreenPrompt` (compact)

`Tools/ScreenBenchmarkHarness/run.sh 3`: 8 briefs (podcast settings, recipe detail,
coffee checkout, running profile, empty inbox, sign-in, weather dashboard, habit tracker),
each written 3 times by each prompt at temperature 0.7, so 24 screens per prompt.

| Per 24 screens | Old prompt | New prompt |
|---|---|---|
| Screens with more than one filled button | 2 | **0** |
| One primary action after `withOnePrimaryAction()` | 23 | **24** |
| Elements given a colour | 28 | **5** |
| Different kinds per screen (the old prompt's kitchen-sink sampler) | 8.9 | **5.3** |
| Elements per screen | 10.3 | 8.5 |
| Lines that parsed | 24 | 24 |

Found and fixed along the way:

- With an abstract `kind: words [look]` line far from the example, the model wrote
  `kind: title` literally. The grammar now shows real lines instead.
- It copied an example that matched its brief closely (a coffee checkout came back as the
  "Delivery address" form). The compact rules now start with "Write words for this exact
  product", and the rules come last, after the example. A line or two is still copied
  sometimes, such as "Same address for billing".
- With every look word on offer it decorated everything, and most screens had no filled
  button. "Most lines need no look" and the primary-action rule fixed most of this. The
  polish step makes the last bordered button the primary one when there was none.

Hosted models get the full rules and two examples. They weren't measured here: hosted
generation needs iPadOS 27.2, and the simulator runs 27.0.

## Sketch hints: all of them in the instructions, or only the candidates'

`SketchPrompt`'s hints now come from `ComponentSpec.sketchHint` in the catalogue, with
sizes from `SketchConventions`. `SketchHintTests.theMeasuredInstructionsAreUnchanged`
checks that they add up to the measured wording, word for word.

`Tools/SketchBenchmarkHarness/run.sh run LayerTests/Fixtures --model`, twice each:

| | All hints in the instructions (kept) | Only the candidates' hints, in the message |
|---|---|---|
| Top-1 with the model | **89.1%** (both runs) | 87.8% (both runs) |
| System 2 on escalated cases | **63.2%** | 52.6% |
| button–textField | **75%** | 50% |
| radio–avatar | **75%** | 50% |

The first column reproduces `stage1-radio-fix.md` exactly. Candidate-only hints are
worse, so `.all` stays the default; `LAYER_SKETCH_HINTS=candidates` still selects the
other placement in debug builds.

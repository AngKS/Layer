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

## The outline (plan 3), 2026-11-24

Branch `st3/lane-a` (from ae12bd3), macOS 27.2.1 on an Apple M4 Max, the on-device Apple Intelligence model natively
(its calls fail in the simulator). `Tools/ScreenBenchmarkHarness/run.sh outline 3`: the harness is now a Swift package
that links the A2UI SDK and compiles the app's own outline and A2UI readers, prompts and hosted client. Each of the 8
briefs above is written 3 times, 24 screens a run, with the app's own call: `ScreenPrompt.instructions(.compact, …)` as
the session's instructions, the description as the message, `streamResponse` with the session's default options (the
2026-11-18 runs used `respond` at temperature 0.7), and the answer read by `OutlineStream` as it streams.

The machine was quiet: no other lane and no `xcodebuild` ran during any run (checked before each, and sampled every
15 seconds). The 1-minute load stayed between 3.8 and 9.5 in every run but round 1's second, where something outside
the project raised it to between 12.9 and 17.8; its latencies are no slower than the others'. Round 3 ran later the
same morning, after waiting for Spotlight's indexing to settle, at 1-minute loads of 7.3 to 9.4.

What each number is, from the whole answer:

- **Valid**: the outline read by `Outline.parse` holds something and `TreeValidator.fixGenerated` had nothing to fix.
- **More than one filled button**: before the polish, from the lines as written; after `withOnePrimaryAction`, from
  the tree.
- **Coloured nodes**: nodes given a colour (a tint). "text grey" is a text colour and isn't counted, as the blueprint's
  scores didn't count it.
- **Kinds** and **leaves** per screen; **rows**, **cards** and **grids** per screen, the containers the tree holds.
- **Split sections**: sections the parser made beyond the ones the model's blank lines started, such as a grid 24 points
  from the heading written right above it.
- **Copied example lines**: lines of the examples, over 12 characters, found word for word in the answers. Nearly all
  are lines any such screen has: "text field: Email", "button: Sign in".
- **First content**: from the request until `OutlineStream` first hands on a screen, what the canvas first shows.
  **Completion**: until the answer ends.

| Per 24 screens | 2026-11-18 (new prompt, blueprint) | Round 0: today's prompt and parser | (a) `column:` taught | (b) the parser joins | Round 1 (2 runs) | Round 2 (3 runs) | **Round 3, final (the fix round)** |
|---|---|---|---|---|---|---|---|
| Valid | 24 (parsed) | 24 | 24 | 24 | 24, 24 | 24, 24, 24 | **24** |
| More than one filled button, before polish | 0 | 0 | 0 | 0 | 0, 0 | 0, 0, 0 | **0** |
| More than one filled button, after polish | 0 | 0 | 0 | 0 | 0, 0 | 0, 0, 0 | **0** |
| Coloured nodes | 5 | 7 | 6 | 10 | 3, 3 | 0, 5, 1 | **0** |
| Kinds per screen | 5.3 | 5.33 | 4.96 | 5.38 | 5.04, 4.83 | 5.58, 5.00, 5.12 | **5.42** |
| Leaves per screen | 8.5 | 8.79 | 8.00 | 8.42 | 8.12, 8.17 | 8.92, 8.12, 8.42 | **8.67** |
| Rows / cards / grids per screen | not measured | 1.71 / 0 / 0.17 | 1.92 / 0 / 0 | 1.50 / 0 / 0.25 | 1.92 / 0 / 0.04, 1.96 / 0.04 / 0.04 | 1.46 / 0.67 / 0.12, 1.46 / 0.62 / 0, 1.38 / 0.75 / 0.08 | **1.38 / 0.62 / 0.08** |
| Split sections | not measured | 7 | 0 | 0 | 0, 0 | 0, 0, 1 | **0** |
| Copied example lines | not measured | 10 | 7 | 8 | 6, 7 | 7, 12, 11 | **8** |
| First content p50 / p95 ms | not measured | 1013 / 1121 | 987 / 1209 | 996 / 1077 | 968 / 1129, 975 / 1080 | 1041 / 1163, 1041 / 1167, 1037 / 1225 | **1000 / 1129** |
| Completion p50 / p95 ms | not measured | 1701 / 2451 | 1655 / 2450 | 1731 / 2350 | 1669 / 2214, 1653 / 2245 | 1866 / 2596, 1809 / 2584, 1935 / 2598 | **2090 / 2904** |

The bar was the 2026-11-18 column: 24 valid, no screen with more than one filled button after the polish, at most 5
coloured nodes, at least 5 kinds and 5 to 14 leaves per screen. Round 2's wording met it in all three runs; its 72
screens together: 72 valid, 6 coloured nodes (2 per 24), 5.24 kinds and 8.49 leaves per screen, 0.68 cards per
screen, first content p50 1041 ms and p95 1225 ms, completion p50 1936 ms and p95 2598 ms. Round 3, the final wording,
meets it too (one run, as the fix round asked). Its completion is slower, p50 2090 ms: the settings screens came out
longer (13 to 14 leaves), and more lines use "text grey" (23, against 13 to 18 in round 2's runs).

### A heading with its container: the parser, not the prompt

The outline parser made a container written at the top level a section of its own, so a form's fields came out as
[name, street] / row / [phone], 24 points apart, and a profile's "Recent work" sat 24 points from its grid. Round 0
shows the model writing this way in 5 of 24 screens (7 split sections): a checkout's fields round a row of two, two
profiles' headings over their grids, a habit tracker's divider over its grid.

- (a) taught `column:` in the grammar ("a column keeps them together in one section", with a heading over a grid shown
  in one), and wrapped the form's and the profile's examples in `column:`. Only 3 of 24 screens wrote `column:`, all
  checkouts copying the form's shape; every profile stopped after its first section, with no grid (5 leaves each), and
  kinds and leaves per screen fell to 4.96 and 8.00.
- (b) changed the parser: a container written straight after a section's lines, with no blank line between, joins that
  section. With the prompt as it was, the run was 24 valid with 5.38 kinds and 8.42 leaves per screen and no split
  section; the 7 of round 0 are each of this kind, and the parser now joins them whatever the model writes.

(b) is kept: it needs no prompt change, takes nothing from what the model writes, and fixes every case measured. It is
decided as the container opens, so a key never changes as more lines stream in. A container that starts a section,
first or after a blank line, is still a section of its own, and lines straight after it start the next one: round 2's
third run has one such screen (a card, then a divider and a second card). Joining those would wrap a lone container in
a section once lines follow it, which changes its key mid-stream.

### The rounds

- Round 0 missed on colour (7): `[grey]` on fields and text, which reads as a tint, and blue or red on the main button.
- Round 1 changed the compact rules' colour line from "No colours unless the description names one." to "No colour
  words, not even blue, red or grey, unless the description names a colour. Quieter words are text grey." Colour fell
  to 3, but kinds per screen were 5.0, then 4.8 in a second run: under the bar. Profiles and empty states often came
  out as four elements of four kinds.
- Round 2 kept that and changed two more compact rules: the shape rule gains "Details that belong together, such as a
  summary or a set of figures, go in a card: or a grid 2:.", and "Use 5 to 12 elements." became "Use 6 to 12
  elements." Cards went from none to 0.7 per screen, kinds to 5.0 to 5.6, colour to 0 to 5. Three runs all meet the bar.
- Round 3, the fix round, after review: the compact prompt contradicted itself twice. Its settings example showed
  `button: Turn off all notifications [plain, red]` under a rule that says "not even blue, red or grey", and that rule
  banned grey, then prescribed text grey. Now the compact prompt shows its example without the colours its looks give
  elements (`ScreenPrompt.withoutColour`: a look word that names a colour is left out, "text grey" stays), so the
  settings example's button is `[plain]`; and the rule's last sentence, "Quieter words are text grey.", became "For
  quieter words use text grey, which isn't one." The example library itself is unchanged, so the full prompt and the
  Settings template keep the red Turn off button, which the full rules allow ("red only for something destructive").
  One run: 24 valid, no colour, 5.42 kinds and 8.67 leaves per screen.

The grammar, the example library and the full rules are as they were, so hosted models' outline prompt is word for word
unchanged; only the compact prompt changed, in its rules and in how it shows its example. Indentation cost nothing:
every screen of every run was valid, and none needed a fix, so the compact grammar keeps teaching `row:`, `card:` and
`grid 2:`. `ScreenPromptWordingTests` pins the final wording of both outline prompts and of the A2UI prompt, word for
word, and `OutlinePromptTests.theCompactPromptsExampleShowsNoColour` checks that no example the compact prompt can show
carries a colour, while the full prompt and the Settings template keep theirs.

### Hosted models: LM Studio, smoke only

`run.sh hosted google/gemma-4-26b-a4b a2ui 1` and `… outline 1`: one screen per brief, the full prompts, through
`HostedModelClient` as the app sends them. These only show that the hosted modes run end to end; the comparison that
picks the hosted default is plan 6's. The model reasons before it answers, so most of the time and the tokens are its
reasoning.

| Per 8 screens | A2UI | Outline (full prompt) |
|---|---|---|
| Valid | 5 | 8 |
| More than one filled button, before / after polish | 0 / 0 | 0 / 0 |
| Coloured nodes | 0 | 1 |
| Kinds / leaves per screen | 4.4 / 12.2 | 5.8 / 14.9 |
| Rows / cards / grids per screen | 2.2 / 0.9 / 0.1 | 3.5 / 0.9 / 0.0 |
| First content p50 / p95 ms | 52812 / 63155 | 27910 / 63867 |
| Completion p50 / p95 ms | 59592 / 69913 | 29164 / 66184 |
| Output tokens per screen, p50 (total) | 4525 (35641) | 2504 (26988) |

The three A2UI screens that weren't valid had lines that weren't JSON, children that named components never written,
and an `Icon` named with an SF Symbol name ("cloud.fill") rather than one of A2UI's icon names. Every outline screen was
valid; five of the eight ran past the full rules' 14 elements. Both ran one after the other with nothing else working,
at 1-minute loads of 4 to 10.

# Sketch benchmark: the Stage 1 checkbox/radio/avatar fix

This uses the same 156-fixture corpus as every earlier report, unchanged. The raw JSON is in `stage1-radio-fix-report.json`.
The model numbers come from the macOS harness (`Tools/SketchBenchmarkHarness/run.sh run … --model`).
They were stable across repeated runs.

## Cause

Stage 1's continuous scoring didn't break these pairs. Two older defects did, and the hard cutoff had been hiding them.

1. **The radio/avatar cutoff sat inside the radio range.** `radioFraction = 0.08` is 31 pt on a 393 pt screen.
   The measured width includes the pen's thickness, so a 30 pt radio circle measures at 0.082 and lands on the avatar side.
   The 28 pt ones measured 0.077, so close to the line that scoring them continuously made them a coin flip.
   The cutoff is now **0.085, about 33 pt**. That's halfway between the drawn radio circles (28–30 pt) and the smallest avatars (34 pt and up).
2. **The model was never told how big a shape is.** The prompt defined a radio button as "a tiny circle" and an avatar as "a circle too big to be a radio button".
   The sketch description gave only the shape, corners and inside, never the size. So on these close calls the model guessed, and it guessed avatar.
   Small outlines, those under `tinyFraction`, are now described as "about N points across", and the radio and avatar definitions name their sizes.
   Adding the size to wide boxes too lowered button vs text field to 25%, so wide boxes still get no number.
   Adding a size to the checkbox definition swapped one fixture between button–textField and radio–avatar without changing the total, so that wording was left out.

## Numbers

| Metric | Baseline (main) | stage-2-4 checkpoint | With this fix |
|---|---|---|---|
| Top-1, rules only | 86.5% | 85.9% | **87.8%** |
| Top-1, rules + Apple Intelligence | 88.5% | 87.2% | **89.1%** |
| Top-3 recall | 85.9% | 89.1% | 89.1% |
| Escalation rate | 12.2% | 14.1% | 12.2% |
| System 2 accuracy on escalated | 78.9% | 54.5% | 63.2% |
| checkbox–radio (+model) | 100% | 50% | **100%** |
| radio–avatar (+model) | 75% | 50% | **75%** |
| button–textField (+model) | 100% | 75% | 75% |
| System 2 latency p50/p95 | 392 / 728 ms | 651 / 697 ms | 656 / 1083 ms |

This is the first state of the branch that beats the original baseline end to end, with or without the model.

## Still open

- button–textField with the model is still below the baseline: 75% against 100%.
- System 2 is correct on fewer of its escalated cases than at the baseline (63% against 79%), although the cases it gets are harder ones.
- toggle–progress, image–textField and divider→body are unchanged at 50%.
- All of this is on synthetic strokes. Real handwriting on an iPad is the next real test.

# Voice commands on the on-device model

Measured 2026-11-17 on a Mac, macOS 27.2, with Apple Intelligence's on-device model.

## The short of it

- On commands written after everything was settled, the on-device model called the right
  tool with the right arguments for **9 of 12**.
- An edit takes about **2 seconds**: half of the commands were answered within 2.0 s, 19 in
  20 within 2.6 s, and the slowest took 3.3 s.
- The profile takes about **2,000 of the model's 8,192 tokens** with a screen on the
  canvas. The fifteen tools are four fifths of that.
- Two things it does badly: it **acts on something else when what was named isn't
  there**, and it **can't name elements on a screen that isn't in view**.

## What was run

`Tools/VoiceBenchmarkHarness/run.sh` builds the app's own voice rules, tools and canvas
picture for macOS and puts typed commands to the model through the same kind of profile
the app uses on-device: the compact rules, the compact canvas picture, six tools on an
empty canvas and fifteen otherwise, and 200 tokens to answer in.

Apple Intelligence can't answer in the iPadOS Simulator, which is why this runs on the
Mac. The app is not in the loop: a recorder stands in for it, notes each tool call and
answers as the app would. It has the app's two guards (below) but does not check that a
handle exists.

Three canvases: empty; one screen, "Login", with a title, a "Sign in" button and an
image; and three screens, "Login", "Profile" and "Settings", with "Profile" in view.

Fifty commands, each run once, in three groups:

| Group | Commands | What it is |
|---|---|---|
| Tuned on | 30 | Written first. The rules and tools were changed with these results in hand. |
| Held back | 8 | Written to be kept out of the tuning. Two later changes were made after looking at them, so they are no longer independent. |
| Fresh | 12 | Written after the last change, run once, and counted as they came. |

## Results

Right tool and right arguments, by group:

| What was run | Tuned on | Held back | Fresh |
|---|---|---|---|
| As first built, the model's own sampling | 27 of 30 | | |
| Three more lines of rules and two tools reworded, the model's own sampling | 26 of 30 | 5 of 8 | |
| The first rules, always the likeliest answer | 28 of 30 | 5 of 8 | |
| As it is now | 29 of 30 | 5 of 8 | 9 of 12 |

One command is 3 points of the first group, 12 of the second and 8 of the third, so
only the large differences here mean anything. The first two rows vary from run to run;
the last two give the same answers every time.

Tokens, as it is now:

| Canvas | Rules | Canvas picture | Tools | Total |
|---|---|---|---|---|
| Empty | 236 | 59 | 447 (6 tools) | 742 |
| One screen | 236 | 156 | 1,643 (15 tools) | 2,035 |
| Three screens | 236 | 190 | 1,643 (15 tools) | 2,069 |

Time is from the command to the model's last word, tool calls included. A new screen
looks as quick as an edit here because the recorder answers at once; in the app the
screen generator then writes the screen, which takes far longer.

## What it led to

- **More rules did not help.** Three more lines, about text colour, centring and things
  that aren't there, cost 56 tokens and scored one lower. They were taken out again.
- **Always the likeliest answer.** The on-device branch of the profile now sets
  `.samplingMode(.greedy)`. It scored one higher, which is within the noise; the reason
  to keep it is that the same words on the same canvas now do the same thing each time.
- **"Middle" and "centrally" are centre.** The model said `middle` for "align the image
  centrally", and the app took that as top-to-bottom. The app now takes both as centred
  from side to side; top-to-bottom needs "vertical centre".
- **A colour given as the words is the colour of the words.** Asked to change a text
  colour, the model calls `setText` with `blue`. No wording of the tools stopped it,
  including giving `styleElement` a text colour argument of its own. So the app now takes
  new "words" that are only a colour name in lower case, `blue` or `text blue`, as the
  colour of the words. "Blue" with a capital, or a colour among other words, is still text.
- **A delete names what it deletes.** Asked to make a dropdown bigger where there was
  none, the model once deleted the button. `deleteElement` and `deleteScreen` now carry
  the person's own word for the thing, and the app refuses when that word is neither the
  thing's kind nor on it. On the fresh commands this stopped "delete the log out button"
  from deleting a toggle.

## What still goes wrong

**Things that aren't there.** Four commands named something the canvas didn't have. The
model declined none of them.

| Command | What it did |
|---|---|
| Make the slider wider | Made the image full width |
| Make the dropdown bigger | Duplicated the button and made the copy full width |
| Make the map taller | Zoomed in |
| Make the checkbox blue | Asked to restyle E4, which doesn't exist; the app answers "There is no E4." and changes nothing |

Each is one "undo" away, and each shows on the canvas being watched. Only deletes are
guarded. A hosted model, in the one live run there has been, declined the slider in words.

**Elements on another screen.** With several screens, the compact picture lists the
elements of the screen in view and only the names of the others. "Turn the toggle off"
and "delete the log out button", said while "Profile" was in view, were about "Settings":
the model guessed at handles, restyling the wrong button for one and being refused by
the delete guard for the other. Saying "show me the settings screen" first puts its
elements in front of the model. There is room to list more: the profile uses a quarter of
the context.

**A name that could be two things.** "Change the name to Sam Lee", with a profile screen
in view, renamed the screen and not the title that held the name.

## On an iPad, 2026-11-18

Voice mode then ran on an iPad mini (A20 Pro) with Apple Intelligence: two calls and
about thirty spoken commands by one person, followed from the Mac through the app's log.
One session is not a benchmark, but it is the only time any of this has run on a device.

**It worked, after one fix.** The first try stopped the app as the microphone started;
that is fixed (see the commit that adds `MicrophoneTap.tapBlock`). After it, speech was
recognised on the iPad (`SpeechTranscriber`, en_SG, from a 48 kHz microphone) and the
model made screens, added, restyled, reworded and deleted elements, undid, zoomed and
went to screens.

**How long things took:**

| | Time |
|---|---|
| First command of a call | 14 s and 19 s |
| A command that changed the design, from the end of speech to done | 5.1 to 5.6 s |
| Of that, until the change was on the canvas | about 2 s |
| A command that changed nothing on the canvas (zoom) | 2.7 s |

The three seconds between the change and "done" were the model saying "Done". After a
step the app told it about the canvas again, and to say anything it had to read all it
was told again. Where the canvas was as before, the same closing word took 0.6 s.

**What went wrong in use**, and what was changed for it:

| Seen on the iPad | Change |
|---|---|
| The first command of each call waited 14 to 19 s | The model is warmed as the call starts, and again after a command is stopped or fails |
| A pause for thought cut a sentence into commands, and a leftover "So" or "make" was acted on | The pause that ends a command is 1.2 s, was 0.8 s; a word alone that is no command is let go |
| Three seconds to say "Done" after every change | The on-device model is told about the canvas once for a command, not again after each step |
| "Which element should I change—E24, E25, or E26?" | Handles in what the model says, and in what the pill shows, are put as the things they stand for |
| Screens named "A cashier screen with" | The model gives a new screen a short name |
| "Move down a bit" went to another screen | A tool to pan up, down, left or right |
| "Stack them into a column" put four images on top of one another | A tool to stack elements in a column or a row |

**Measured again on the Mac** with the seventeen tools as they now are, and eleven of
the commands from the iPad as the recogniser heard them:

| Group | Right tool and arguments |
|---|---|
| Tuned on | 28 of 30 |
| Held back | 5 of 8 |
| Fresh | 9 of 12 |
| Spoken to the iPad | 7 of 11 |

The profile is now 2,278 tokens with a screen on the canvas (tools 1,886). Panning as
one more thing `show` could be asked for did not work: the model still answered "move
down a bit" with a screen. As a tool of its own it did.

**Still wrong, and not changed:**

- "Can you edit the image to be a section?" deleted the image, on the iPad and on the
  Mac. With the dropdown and the checkbox above, that is three commands answered with a
  delete nobody asked for. A delete could be refused unless the command has a word for
  removing in it.
- "No, undo revert." was one undo on the iPad and two on the Mac.
- "Red" was heard as "rate", and the title was reworded to "rate".

**A second session on the iPad, the same night, with those changes:** one call of four
and a half minutes and about forty commands.

| | Before | After |
|---|---|---|
| First command of a call | 14 s and 19 s | 0.7 s |
| A command that changed the design, end of speech to done | 5.1 to 5.6 s | 1.9 to 3.3 s |
| Of that, from the change to "done" | about 3 s | 0.4 to 0.6 s |
| A new screen | 5.3 to 6.3 s | 4.0 to 5.3 s |

A new screen still takes two seconds to say "done": the screen is written by the same
model in a conversation of its own, and the first one has to find its place again.

"Okay." and "to." were let go. Stacking was used unprompted, three times. What it showed
that was wrong:

- **Screens named "S7" and "S8".** Asked for "another screen", the model had no name to
  give and gave the handle the screen was about to get. Fixed: a handle, or a word like
  "new", is no name, and the screen is named from its description as before.
- **"New screen “the screen “S7”” created."** A handle the model had put in quotes was
  put into words inside them. Fixed.
- **A sentence cut by a pause still runs if what is left has two words.** "I want a
  screen to" made a screen; "Inc increase the width of it to" made the image 171 points.
- **Putting one thing below or beside another has no tool.** "Move this image below the
  title", "align the avatar beside it" and "move the name and location fields down as
  well" were answered with what there is: a guess at a position, or an edge of the
  screen, which put two fields on top of each other.
- **"Align the image and the avatar"** lined each up with the screen, not with each
  other, and the model's try at naming both in one call was refused.
- **A correction leaves the mistake.** "Make the image bigger" resized a checkbox. "Not
  the check marks" then resized the image, and the checkbox stayed as it was. "No,
  that's wrong" was answered by doing the wrong thing again with another number.
- **Something loose on the canvas was picked for a command about the screen in view**:
  "make the width 50%" resized a sticky note.

## Prompt order (2026-11-18)

**Not kept.** Moving the canvas into the prompt makes an edit about 0.7 s quicker. In
every form tried, though, commands in a row went wrong in ways the canvas in the
instructions doesn't. The worst was "turn the toggle off", which deleted the toggle. The
app keeps the canvas in the instructions. The first pass is below, then the round that
tried to fix what it showed.

**What was tried.** The on-device profile puts the canvas between the rules and the
tools: `Instructions(VoiceRules.compact)`, then `CanvasBrief`, then the tools. The canvas
changes with nearly every command, so the model can keep only the rules from one
command to the next and reads the tools again each time. The change moved the canvas
for the on-device profile to the head of each command's prompt ("The canvas now: … The
command: …"), so the rules and the tools stayed the same. Hosted profiles were unchanged.

**How it was measured.** On this Mac, macOS 27.2, with the harness's new `latency` mode
(`Tools/VoiceBenchmarkHarness/run.sh latency 6`). One session per call, set up as the
app's on-device profile: the compact rules, 18 tools, the last two commands, greedy,
200 tokens to answer in. Each call is warmed with `prewarm()` as a call starts, waits
4 s, then runs eight edits in a row on the one-screen canvas, 1.5 s apart. The recorder
changes the canvas as the app would (a look, words, a size, a copy), so each command
after the first sees a changed canvas. Times are from the command to the first tool,
from the last tool to the model's last word (its "Done"), and the whole. Six calls in
each order, the order going first rotating from run to run. Accuracy is the existing
64 commands, run twice in each order (`baseline` and `canvasfirst`); greedy, so the two
runs gave the same answers.

A third order was tried: canvas in the prompt, with `prewarm(promptPrefix:)` reading
the starting canvas ahead too. It was slower everywhere, so it isn't used.

The canvas was not tried after the tools, in the instructions. A profile's instructions
are one transcript entry, its text first and the tool definitions after it
(`Transcript.Instructions(segments:toolDefinitions:)`), so an instruction can't be put
after the tools. The first place after them is the prompt.

**Latency**, median (min–max), seconds:

| | Canvas in instructions | Canvas in prompt | Change | Canvas in prompt, warmed with it |
|---|---|---|---|---|
| Edit, whole (42 per order) | 2.67 (2.39–2.74) | 1.91 (1.61–2.08) | −28% | 2.69 (1.83–2.84) |
| Edit, to the first tool | 2.22 (1.99–2.30) | 1.50 (1.22–1.65) | −32% | 2.06 (1.22–2.18) |
| First command after warming, whole (6) | 1.36 (1.33–1.38) | 1.72 (1.69–1.73) | +26% | 2.57 (2.54–2.68) |
| First command, to the first tool | 0.94 (0.92–0.96) | 1.30 (1.29–1.33) | +38% | 2.01 (2.00–2.12) |
| "Done", last tool to last word (48) | 0.44 (0.38–0.47) | 0.42 (0.39–0.49) | none | 0.63 (0.54–0.78) |

Each call's median edit was within 0.06 s of the others in the same order. An earlier
pass of six calls in two orders, the canvas in the instructions against the canvas in
the prompt warmed with it (its raw output labels the second "prompt"), gave the same
numbers for both: 2.67 and 1.36 s for the first, 2.72 and 2.59 s for the second.

- An edit is about **0.75 s quicker**. It is the larger part of a call: every command
  after the first.
- The **first command is 0.35 s slower**. Before, the warm-up read the whole profile,
  canvas included, and the first command found it all read if the canvas hadn't changed.
  Now its canvas is read with the command. Over a call of more than one command the
  change still saves time.
- **"Done" is unchanged.** On-device, the canvas is not told again between steps (see
  "On an iPad"), so this step already found everything read.

**Accuracy**, right tool and right arguments:

| Group | Canvas in instructions | Canvas in prompt |
|---|---|---|
| Tuned on | 27 of 30 | 29 of 30 |
| Held back | 5 of 8 | 5 of 8 |
| Fresh | 7 of 12 | 8 of 12 |
| Spoken to the iPad | 10 of 14 | 11 of 14 |
| All | 49 of 64 | 53 of 64 |
| Commands where more than one tool was called | 3 | 6 |

The baseline is lower than the 2026-11-18 table above: there are now 18 tools (2,140
tokens) where there were 17, and three more commands from the iPad. Four more right is
within the noise of commands this few, so the change is not counted as more accurate,
only as not less. What it did differently: it ended the call on "That's all, thanks",
took "the name" as the title, and wrote the text colour as `text red` and not `red, text
red`. Against that, on things that aren't there ("the slider", "the dropdown", "the
checkbox") it now strings several tools together, such as `show`, then `placeElement`,
then a resize, where before it called one wrong tool or a delete the app refused.

In the calls of eight commands in a row, where earlier commands and their canvases are
in the conversation, the canvas in the instructions got all eight right every time. With
the canvas in the prompt, seven: "Change the title's text colour to blue", the last of
the eight, reworded the title to "Welcome back blue" in all six calls. On its own, in the
64, the same command was right in both orders. "Make the title red" became `text red`
rather than `red`; for a title that is the same thing.

After the first pass the change was kept, then reviewed. The review asked for more
commands in a row and for fixes to what they showed.

### Fix round 1

**What was added to the harness.** Three sequences of eight commands, graded by the
same `Case.isRight` as the single commands, not by eye:

- **Edits:** the eight above.
- **Screens:** three screens; moving between them changes which one is in view and so
  what the canvas lists; a slider that isn't there; a rename.
- **Views:** zoom in and out, which leave the canvas as it is; a rename; a correction,
  "No, make the button bigger instead"; and a checkbox that isn't there. As in the app,
  the correction undoes the last change first and the model is told so.

The recorder now also deletes, renames and shows as the app would. A call that a build
or test run (`xcodebuild`) overlapped is thrown away and run again. Another agent was
testing on the simulator during these runs, and seven calls were run again for it.

**The forms tried** (`PromptForm` in the harness):

| Form | What the prompt is |
|---|---|
| instructions | The canvas in the instructions; the prompt is the command. As the app has it. |
| plain | The first pass: "The canvas now:\n…\n\nThe command: …" |
| quoted | "The canvas now (for reference only):\n…", then the app's notes, then `The person said: "…"`. Older prompts lose their canvas (`historyTransform`). |
| quotedkeep | As quoted, but older prompts keep their canvas. |
| commandfirst | The person's words in quotes, then the canvas. Older prompts lose theirs. |
| quotedrule | As quoted, with the note "(Act only on what the canvas lists. If they name something it doesn't list, call no tool and say it isn't there.)" before the words. |
| quotedonly | As quoted, with the canvas headed "Only what is listed here exists". |

Each form ran in two calls of each sequence. Greedy answers were the same in both runs
of every form. The 64 single commands ran once each.

**Edits in a row** (the first sequence, after its first command), median (min–max), s:

| Form | Edit | To the first tool | First command | "Done" |
|---|---|---|---|---|
| instructions | 2.66 (2.43–2.73) | 2.24 | 1.34 | 0.47 |
| plain | 1.93 (1.64–2.11) | 1.51 | 1.73 | 0.50 |
| quoted | 2.03 (1.87–2.17) | 1.44 | 1.83 | 0.57 |
| quotedkeep | 2.14 (1.77–2.31) | 1.55 | 1.84 | 0.58 |
| commandfirst | 2.05 (1.92–2.18) | 1.46 | 2.00 | 0.59 |
| quotedrule | 2.14 (1.97–2.38) | 1.54 | 1.87 | 0.60 |
| quotedonly | 2.00 (1.95–2.18) | 1.46 | 1.85 | 0.46 |

The instructions form measured 2.68 in a second batch run alongside the last two forms.

**Right, in a row** (of 8, the same in both runs):

| Form | Edits | Screens | Views | All | What went wrong |
|---|---|---|---|---|---|
| instructions | 8 | 7 | 7 | 22/24 | Slider: `pan right`. Checkbox: `styleElement` on "checkbox", which isn't a handle, so the app refuses it. Neither changes the design. |
| plain | 7 | 6 | 8 | 21/24 | Text colour reworded the title. **Toggle deleted.** Slider resized the avatar. |
| quoted | 8 | 6 | 7 | 21/24 | **Toggle deleted.** Slider made a new screen and added to it. Checkbox: a delete of E4, which isn't there, refused. |
| quotedkeep | 8 | 6 | 8 | 22/24 | **Toggle deleted.** Slider resized the avatar. |
| commandfirst | 8 | 5 | 7 | 20/24 | **Toggle and the log out button deleted.** Slider and checkbox changed the button. |
| quotedrule | 7 | 6 | 7 | 20/24 | Text colour reworded the title. Slider resized the avatar. Renamed the wrong screen. Checkbox: stacked the three elements. |
| quotedonly | 8 | 6 | 8 | 22/24 | **Toggle deleted.** Slider made a new screen. |

**The 64 single commands**, right tool and arguments:

| Form | Tuned on | Held back | Fresh | iPad | All | More than one tool |
|---|---|---|---|---|---|---|
| instructions | 27 | 5 | 7 | 10 | 49 | 3 |
| plain | 29 | 5 | 8 | 11 | 53 | 6 |
| quoted | 29 | 4 | 9 | 10 | 52 | 7 |
| commandfirst | 28 | 4 | 8 | 9 | 49 | 5 |
| quotedrule | 29 | 6 | 9 | 11 | 55 | 4 |
| quotedonly | 29 | 4 | 9 | 10 | 52 | 6 |

**Things that aren't there**, on their own: what each form did, and what the app would
then do. In the app, a handle that doesn't exist and a delete whose word doesn't fit are
both refused.

| Command | instructions | plain | quoted | quotedrule | quotedonly | commandfirst |
|---|---|---|---|---|---|---|
| Make the dropdown bigger | Delete of the button, refused: **nothing** | Moves and resizes the button | Moves and resizes the button | No tool, says so: **nothing** | Delete refused: **nothing** | Restyles the button |
| Make the checkbox blue | Show and delete of E4, which isn't there: **nothing** | Place and restyle E4: **nothing** | **Deletes the sign in button** | Restyles the image | Adds a checkbox | Restyles the button |
| Make the slider wider | Resizes the image | Moves and resizes the image | Moves and resizes the button | Shows the screen: **nothing** | Moves and resizes the button | Resizes the button |
| Make the map taller | Zooms in: **nothing** | Zooms in: **nothing** | Resizes the image | Resizes the image | Resizes the image | Resizes two elements |

**What it comes to.**

- Every form with the canvas in the prompt is 0.6–0.7 s quicker per edit. The first
  command is 0.4–0.7 s slower.
- None keeps the instructions form's behaviour in a row.
  - Five of the six delete the toggle when asked to turn it off, after "show me the
    settings screen". The instructions form never did.
  - quotedrule doesn't delete the toggle, but it is the worst of all in a row: the
    reworded title is back, and it renames the wrong screen.
- On their own, quotedrule scores best (55 of 64) and turns down the dropdown and the
  slider. It still restyles the image for the checkbox.
- Quoting the person's words and taking old canvases out of the history fixed the
  reworded title in a row; the absent things were still acted on.
- The reworded title is borderline rather than settled. The plain form reworded it in
  every clean call, 6 of 6 and then 2 of 2. It got it right once, in a call a build
  overlapped and that was then thrown away. Greedy answers seem to depend on the state
  the model was left in, not only on the words.

**Not kept.** The canvas stays in the instructions. Speed would be bought with real
edits nobody asked for, the deleted toggle above all. Reading the tools again each
command costs about 0.7 s per edit, and it stays. Two ways back to this:

- Guards in the app: refuse a delete unless the command has a word for removing in it
  (already noted above), and refuse tools for a kind of thing the canvas doesn't have.
- Rules that hold with the canvas in the prompt, tuned on commands kept apart from these.

## New tools (2026-11-18)

Measured 2026-11-21 on the same Mac. The question was whether the on-device model picks
the three tools added on 2026-11-18 for the words people use: `tidyScreen`,
`changeScreenDevice`, and a `device` for `createScreen`. Five controls check that commands
for the older tools still go to them.

**What was run.** `Tools/VoiceBenchmarkHarness/run.sh newtools 5`: 27 commands, each run
five times with the model's own sampling (the baseline variant). Commands spoken with the
pencil carry its hint in front of the words, as the app sends them, and have no tool to end
the call. Two descriptions were reworded before the run, and these numbers are for the new
wording only; the old wording wasn't run for comparison.

- `tidyScreen` now lists "space things out" and says it applies "even with one element
  pointed at".
- `createScreen`'s device says "webpage for a web page or website".

The profile is 2,792 tokens with one screen (20 tools) and 806 on an empty canvas (6 tools).
The pencil's profile is about 60 tokens smaller, because it has no end-call tool.

**Results, 135 calls:** 115 right, 12 with the right tool but a wrong argument, 8 with the
wrong tool.

| Commands | Right | Right tool |
|---|---|---|
| Tidy, 11 commands (the screen or a button pointed at) | 50 of 55 | 52 of 55 |
| Change device, 5 commands | 25 of 25 | 25 of 25 |
| New screen, 6 commands (empty canvas, or the pencil beside a screen) | 25 of 30 | 30 of 30 |
| Controls for the older tools, 5 commands | 15 of 25 | 20 of 25 |

**What goes wrong:**

- **"Make it look nice" with a button pointed at** went to `styleElement` 3 times in 5, and
  each of those also restyled the button. Pointing at one thing pulls the model towards
  editing it. Pointing at the screen gave the tidy 5 times in 5, and so did "tidy this up"
  and "clean up the layout" over the button.
- **"A Chinese calligraphy webpage" said with the pencil beside a screen** made a screen 5
  times in 5 but never set the device. On an empty canvas the same words set "webpage"
  every time.
- **"Centre these two"** went to `alignElement` but said `vertical centre` 5 times in 5.
  The tool's description says "centre" means side to side.
- **"Align the image to the left"** with nothing pointed at went to `placeElement` (left of
  the title) 5 times in 5, not to `alignElement`.

**What it led to.** The new tools are picked as intended. Nothing in the app was changed
for the misses. The last two are older tools and not part of this round. Two possible
fixes for the missing device: read a device word out of the description when `device` is
empty, or give the pencil's empty-canvas hint the same device sentence.

## Structure tools (plan 6)

Measured 2026-11-25 on the same Mac, macOS 27.2. Plan 6 gave voice four tools for the tree's containers:
`groupElements`, `setLayout`, `ungroup` and `reorder`. A call now has 25 tools with the end-call tool, and the
pencil's 24. The question was whether the on-device model picks them, and whether the call's profile still fits the
room set for it: 3,400 tokens with one screen (call 10).

**What was run.** Each run started with no `xcodebuild` running and a 1-minute load average under 10. The first
`structure` run (10:15 to 10:18) overlapped the last minute or so of another agent's UI test builds, which ran from
09:51 to 10:17. These modes record no times: what they count, the calls and the token sizes, doesn't depend on load.

| Run | Start | Load (1, 5, 15 min) before | Tools with one screen |
|---|---|---|---|
| `run.sh structure 5`, all tools | 10:15:54 | 8.63, 9.05, 17.87 | 25 |
| `run.sh newtools 5`, all tools | 10:18:30 | 3.89, 6.75, 15.40 | 25 |
| `run.sh structure 5`, the on-device list | 10:25:23 | 3.03, 3.84, 10.58 | 23 |
| `run.sh newtools 5`, the on-device list | 10:27:38 | 2.47, 3.36, 9.40 | 23 |

The all-tools runs were made before the harness took the on-device list. `run.sh structure 5 baseline --all-tools`
and `run.sh newtools 5 baseline --all-tools` hand the model all 25 tools again, with the compact rules as they now are
(fix round 1 changed them).

- Each case ran five times in the baseline variant: greedy, as the app has it. All five runs of every case gave the
  same calls.
- The harness printed the model's `contextSize` as **8,192 tokens**.
- The structure cases are spoken over a new canvas, "Account". It holds a title, a free card (E2: a text and a body),
  a row (E5: the text "Wi-Fi" and a toggle), two text fields (E8, E9), and a column (E10: a "Sign in" button and a
  text).
- The first two cases have the two fields selected. The rest have nothing selected.
- "Right" is the right tool with the right arguments and no other call. "Take the toggle out of the row" counts as
  right for `moveElement` on E7 with `takeOut` yes, with or without x and y.

**The profile's size.**

| Canvas | All tools | The on-device list |
|---|---|---|
| One screen | **3,578** (25 tools: 3,113) | **3,278** (23 tools: 2,813) |
| One screen, pencil | 3,519 (24 tools) | 3,219 (22 tools) |
| Three screens | 3,612 | 3,312 |
| The nested "Account" screen | 3,791 | 3,491 |
| Empty canvas | 891 (6 tools) | 891 |

The rules are 309 tokens and the one-screen canvas 156. On 2026-11-21 the profile with one screen was 2,792 tokens,
with 20 tools.

**The structure cases.**

| Command | Right tool | All tools | The on-device list |
|---|---|---|---|
| "Put these in a column" (two fields selected) | `groupElements` | 0 of 5: `stackElements` column, E8, E9 and E10 | 0 of 5: the same |
| "Make these a row" (two fields selected) | `groupElements` | 0 of 5: `stackElements` row, E6 and E7 | 0 of 5: the same |
| "Make the card a grid of two" | `setLayout` | 0 of 5: `groupElements` E3, E4 as "grid of two" | 0 of 5: `groupElements` E2 as grid |
| "Space the row out more" | `setLayout` | **5 of 5**: E5, spacing 24 | 0 of 5: `tidyScreen` |
| "Ungroup the row" | `ungroup` | **5 of 5** | **5 of 5** |
| "Move the toggle before the label" | `reorder` | 0 of 5: `placeElement` E7 before E6 | 0 of 5: the same |
| Control: "Take the toggle out of the row" | `moveElement` | 0 of 5: `ungroup` E5 | 0 of 5: the same |
| Control: "Make the button half width" (in a column) | `moveElement` | **5 of 5** | **5 of 5** |
| **Total** | | **15 of 40** | **10 of 40** |

**The older tools, against 2026-11-21.** These are `newtools` and its five controls. Task 7 of plan 6 reworded the
`device` guides of `createScreen` and `changeScreenDevice`, and gave `moveElement` its `takeOut`.

| Commands | 2026-11-21 (20 tools): right, right tool | 2026-11-25, all tools: right, right tool | 2026-11-25, the on-device list: right, right tool |
|---|---|---|---|
| Tidy, 11 commands | 50 of 55, 52 of 55 | 50 of 55, 50 of 55 | 50 of 55, 50 of 55 |
| Change device, 5 commands | 25 of 25, 25 of 25 | 25 of 25, 25 of 25 | 25 of 25, 25 of 25 |
| New screen, 6 commands | 25 of 30, 30 of 30 | **20 of 30**, 30 of 30 | **20 of 30**, 30 of 30 |
| Controls, 5 commands | 15 of 25, 20 of 25 | **20 of 25**, 20 of 25 | **20 of 25**, 20 of 25 |

Changes from 2026-11-21:
- **"A Chinese calligraphy webpage" on an empty canvas** no longer sets the device: 0 of 5, where it set "webpage"
  every time before. With the pencil beside a screen it still doesn't, as before. The screen is still asked for, with
  "webpage" in its description. The app reads a device from the spoken words when the model gives none, so it would
  still be a web page there. This is the new-screen row's fall of 5. The empty canvas's profile has neither the new
  tools nor the compact list, so the likely causes are Task 7's reworded device guide and the rules' new line.
- **"Make it look nice" with the button pointed at** went to `styleElement` 5 times in 5, where it did 3 times in 5.
- **"Centre these two"** is now right 5 times in 5. Before it said "vertical centre" every time.
- **"Align the image to the left"** still goes to `placeElement`, left of the title.

**What goes wrong with the new tools.**
- **`groupElements` was never picked for what is selected.** "Put these in a column" and "make these a row" went to
  `stackElements` every time. Both named the wrong things: the column E10 alongside the fields, or the row's own
  children E6 and E7.
- **Anything about a container's layout read as a new group.** "Make the card a grid of two" grouped the card's
  contents, or the card itself, as a grid.
- **`reorder` was never picked.** "Move the toggle before the label" went to `placeElement` with "before". The app
  refuses that, as the toggle is laid out in a row, and tells the model to call `reorder`.
- **Taking one thing out of a row read as taking the row apart.**
- `setLayout` was picked for the spacing, and `ungroup` for "ungroup", every time.

**What it led to.** With all 25 tools, the profile with one screen was 3,578 tokens, over the bar of 3,400. The
controls passed: 20 of 25 against the bar's 13. So the on-device model is now handed `VoiceTools.compact`: every tool
but `setLayout` and `reorder` (`VoiceProfile.onDeviceTools`). That brings the profile to 3,278 tokens, with the
controls unchanged at 20 of 25. It costs the spacing case, the one structure case `setLayout` won. A hosted model
still has all 25 tools. At first the compact rules and two refusal lines still named `setLayout` and `reorder`; fix
round 1, below, took them out.

**A live model in LM Studio.** `VoiceAgentLiveTests` ran with `TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b`
and passed 9 of 9, with all 25 tools as a hosted model has them.
- "Put the two texts at the bottom in a row" called `groupElements` once: "Put E8 and E9 in a row, E11.", a row 16
  apart, aligned to the start.
- "Move the toggle before the label" called `reorder` once: "Moved E7 before E6."

The run was made under other lanes' builds, at a load of 64 to 91, so its times aren't recorded here.

### Fix round 1 (2026-11-25)

**What changed.**
- On the on-device profile, nothing names a tool the model isn't handed.
  - The compact rules' line about containers names only `groupElements` and `ungroup`. It also gains the full rules'
    sentence: "An element inside a row, column or grid is placed by it: moveElement only resizes it unless the
    person asks to take it out."
  - Task 7's refusals for a laid-out child point at the Layers panel for its order, and at the Format panel's Layout
    section for an alignment, in place of "call reorder" and "call setLayout".
- The empty canvas's rules leave the containers line out (`VoiceRules.compactForEmptyCanvas`). This was ruling 2's
  second step, tried because the new-screen row was still below 25 of 30.

**What was run.** Each run started with no `xcodebuild` running, in the quiet window.

| Run | Start | Load (1, 5, 15 min) before |
|---|---|---|
| `run.sh structure 5`, the new wording | 11:18:25 | 18.65, 34.60, 41.76 |
| `run.sh newtools 5`, the new wording | 11:20:39 | 3.95, 22.94, 36.02 |
| `run.sh newtools 5`, with the empty canvas's rules too | 11:37:28 | 3.91, 6.11, 14.89 |

**The profile's size.**
- The rules are 321 tokens with a screen, up from 309.
- With one screen the profile is **3,290** tokens; the pencil's is 3,231. The nested canvas is 3,503.
- On an empty canvas, the rules without the containers line are 264 tokens, and the profile is 846.

**The structure cases.** They scored 10 of 40, as before.
- "Take the toggle out of the row" still went to `ungroup` 5 times in 5: the take-out sentence didn't move it.
- "Put these in a column" now names only the two fields, E8 and E9, but still goes to `stackElements`.

**The older tools.** The older tools' on-device numbers are lower than before: the controls are 15 of 25 right, against
20 in the run at 10:27:38 on 2026-11-25, and the new screen 20 of 30, against 25 on 2026-11-21. Both are within the bar, which needs 13 of 25
for the controls and sets no floor for the new-screen row.

Every run in this round handed the model the on-device list, without `--all-tools`. "Before the fix" is the run of
the on-device list at 10:27:38 on 2026-11-25; the all-tools run (10:18:30) scored the same in every row. Each cell is
two numbers: right, then right tool.

| Commands | Before the fix, on-device list: right, right tool | The new wording, on-device list: right, right tool | With the empty canvas's rules too, on-device list: right, right tool |
|---|---|---|---|
| Tidy, 11 commands | 50 of 55, 50 of 55 | 50 of 55, 50 of 55 | 50 of 55, 50 of 55 |
| Change device, 5 commands | 25 of 25, 25 of 25 | 25 of 25, 25 of 25 | 25 of 25, 25 of 25 |
| New screen, 6 commands | 20 of 30, 30 of 30 | **15 of 30**, 30 of 30 | **20 of 30**, 30 of 30 |
| Controls, 5 commands | 20 of 25, 20 of 25 | **15 of 25**, 20 of 25 | 15 of 25, 20 of 25 |

- **"Make an Apple product page on iPad" on an empty canvas** made the screen and then called `show` as well, 5 times
  in 5, with the containers line in its rules. Without the line it made the screen alone, 5 times in 5.
- **"A Chinese calligraphy webpage"** still sets no device, 0 of 5 on an empty canvas and 0 of 5 with the pencil.
  It wasn't chased further: the app reads "webpage" from the spoken words when the model gives no device, so the
  person still gets a web page.
- **"Centre these two"** went back to `vertical centre`, 5 times in 5. That costs the controls 5.

**The bar still holds.** The profile with one screen is 3,290 tokens, under 3,400. The controls are 15 of 25, at or
over the 13 the bar needs.

## Structure wording (2026-11-26)

Measured 2026-11-26 on the same Mac, macOS 27.2. The question was whether better wording in the rules and the tool
descriptions sends structure commands to the right tool. The tools stayed where they were: a hosted model has all 25,
the on-device model `VoiceTools.compact`. The hosted model is the one that had to improve; the on-device numbers are
measured against the bars only.

**The short of it.** The hosted model already picked the right tool for all eight cases, 24 of 24, before anything
changed. What it got wrong was how it called them. It gave the spacing as a bare number, which the tool can't read, so
"space the row out more" changed nothing. Its other misses were second calls. The wording now asks for every value as
text, and for a command to be carried out once, with a call for each of several things. Hosted "right" went from
**18 of 24 to 20 of 24**, and the spacing is read every time.
One thing it didn't fix: told "more", the model sometimes raises the spacing again each time the canvas shows the last
change (below). The on-device model is told and handed exactly what it was before, and scored the same. Fix round 1,
at the end, scores where the design ends up as well, and keeps a seventh wording.

**The hosted measurement.** `VoiceStructureLiveTests`, in `LayerTests/VoiceAgentLiveTests.swift`, puts the harness's
eight structure cases to LM Studio's `google/gemma-4-26b-a4b` through the app's own hosted profile: the full rules, the
whole canvas, all 25 tools and the app's settings, which send no temperature, so LM Studio samples as it is set to.

```sh
TEST_RUNNER_LAYER_LMSTUDIO=google/gemma-4-26b-a4b xcodebuild test \
  -project Layer.xcodeproj -scheme Layer -skipPackagePluginValidation -testPlan CI \
  -destination "platform=iOS Simulator,id=<simulator>" \
  -only-testing:LayerTests/VoiceStructureLiveTests
```

- The calls are carried out by the app's own toolbox on a design built as the harness's "Account" canvas is told, with
  the same handles and selection. A test checks that. The canvas is taken again after each tool, as a call does for a
  hosted model. The captured canvas differs from the harness's in two places: the toggle is "colour accent", not
  "colour green", and the label in the row is at y273, not y272, centred across the row. In these runs the screen
  wasn't marked "[in view]" either, as the harness's is; fix round 1, below, puts it in view.
- Each case runs three times, each on a fresh design in a fresh session.
- It is scored as the harness scores: "right" is the right tool with the right arguments and no other call; "right
  tool" is a first call to the right tool. A call whose arguments can't be read counts as that tool picked, not right.
- A ninth case is scored apart: "Stack the title, the button and the image into a column." over the harness's "Login"
  screen, which the harness counts right only for `stackElements`. It checks that wording sending "put these in a
  column" to `groupElements` doesn't take "stack" away from `stackElements`.
- A first version answered every call from a recorder that never changed the canvas, as the harness's does. Shown the
  same canvas after each call, the model made its change again and again: `setLayout` six times, `groupElements` ten.
  The numbers here are all from the app's own toolbox.

**What was run.** The model runs record counts, not times. None started while another lane's timed run was marked as
going, but some were under way when one was marked; those lanes wait for the load to fall below 20 before they time
anything. Four runs were stopped when that happened and are left out: an on-device `structure` run at 01:22; the hosted
round 2 at 04:48, 11 of its 27 runs done; and the first tries at round 4's hosted run and the after all-tools run, at
05:52, both run again in full. Three ran on to their end: round 1's hosted run, started 4 minutes before a mark at
03:46:02, which sent LM Studio 77 requests after it, until 03:57:14; round 2's all-tools run, started 6 s before the
same mark; and round 2's `newtools`, started 2 minutes before the mark at 04:42:42. Since then the live suites check
for the mark before every request they can see (`TEST_RUNNER_LAYER_QUIET_FILE`), and the scripts stop a run within
10 s of a mark appearing.

Every run, kept or not. Runs left out aren't in the tables below.

| Run | Start | Load (1, 5, 15 min) before | Kept? |
|---|---|---|---|
| `run.sh structure 5`, the on-device list | 01:21:17 | 8.49, 8.48, 6.89 | Left out: stopped at 01:22:46 for another lane's timed run |
| `run.sh` with "structure 5" as one argument, which ran the default commands | 01:58:05 | 2.45, 3.70, 5.54 | Only its "Stack … into a column" row is cited |
| `VoiceStructureLiveTests`, its first scoring, answered by a recorder | 02:00:26 | 78.49, 32.46, 16.56 | Left out: an unreadable call was scored as no call, and the canvas never changed |
| Before: `run.sh structure 5`, the on-device list | 02:05:29 | 521.30, 415.96, 207.04 | Yes |
| `VoiceStructureLiveTests`, answered by a recorder | 02:08:32 | 213.93, 409.90, 253.83 | Left out: the canvas never changed (below) |
| Before: `run.sh structure 5 baseline --all-tools` | 02:08:37 | 197.20, 403.17, 252.37 | Yes |
| Before: `run.sh newtools 5`, the on-device list | 02:12:49 | 103.69, 287.70, 243.83 | Yes |
| Before: `VoiceAgentLiveTests` | 02:13:29 | 229.26, 296.11, 248.87 | Yes |
| Round 1: `VoiceStructureLiveTests`, answered by a recorder | 02:17:33 | 64.05, 163.70, 202.17 | Left out: the canvas never changed |
| Before: `VoiceStructureLiveTests` | 02:39:00 | 4.53, 19.43, 87.18 | Yes |
| Round 1: `VoiceStructureLiveTests` | 03:41:51 | 2.80, 3.16, 7.42 | Yes |
| Round 2: `run.sh structure 5`, the on-device list | 03:42:16 | 39.83, 11.62, 10.34 | Yes |
| Round 2: `run.sh structure 5 baseline --all-tools` | 03:45:56 | 144.29, 75.13, 37.01 | Yes |
| Round 2: `VoiceStructureLiveTests` | 04:40:10 | 3.19, 3.63, 4.48 | Left out: stopped at 04:48:40, 11 of 27 runs done |
| Round 2: `run.sh newtools 5`, the on-device list | 04:40:39 | 146.04, 36.42, 16.23 | Yes |
| Round 3: `VoiceStructureLiveTests` | 05:33:32 | 3.36, 4.63, 6.33 | Yes |
| After: `run.sh structure 5`, the on-device list | 05:45:54 | 30.71, 66.56, 50.11 | Yes |
| Round 4: `VoiceStructureLiveTests`, first try | 05:46:08 | Not recorded: the retry wrote over it | Left out: stopped at 05:52:30, 20 of 27 runs done |
| After: `run.sh structure 5 baseline --all-tools`, first try | 05:48:24 | Not recorded: the retry wrote over it | Left out: stopped at 05:52:24 |
| After: `run.sh structure 5 baseline --all-tools` | 05:55:55 | 20.84, 47.85, 51.49 | Yes |
| Round 4 (after): `VoiceStructureLiveTests` | 05:56:00 | 19.33, 47.09, 51.20 | Yes |
| After: `run.sh newtools 5`, the on-device list | 05:59:45 | 8.08, 30.09, 43.29 | Yes |
| After: `VoiceAgentLiveTests` | 06:06:31 | 9.69, 51.44, 55.17 | Yes |

**The rounds.** Rounds 1, 3 and 4 changed only what a hosted model is told, so the on-device runs were made for round
2 and for the wording kept, not for each. The on-device model answers greedily.

1. **Values as text, and where a thing taken out goes.** The full rules gained "Give every value a tool takes as text in
   quotes, numbers too: a spacing of "24", not 24." The sentence about taking an element out of a row now says to give
   an x and y clear of the container, such as just below it. Before, the model left them out or gave the spot the
   toggle already had, and the app answered "Say where E7 goes" or "E7 is there already".
2. **The shared descriptions.** The descriptions of `stackElements`, `groupElements`, `ungroup` and `placeElement`,
   which the on-device model is handed too, each pointed at the right tool, such as `ungroup`'s "To take out just one
   thing, use moveElement with takeOut yes." The rules gained "Do each thing asked for once". Not kept, below.
3. **One call.** The rules' "once" line became "Carry out a command once. "More", "bigger" and "further" ask for one
   step from how things were when the person spoke. Never call the same tool on the same element twice in one command:
   give it everything in one call, and call it again only if its reply said it couldn't be done." The closing line now
   says to call no more tools once the change is made, "the canvas is told again after each tool, so it shows your
   change". Round 2's descriptions were taken out again.
4. **`setLayout`'s own words** (a hosted model's only). Its description gained "For “space it out more” or “tighter”,
   call it once, with a spacing one step from the one it had when the person spoke, such as "24" for 12." Its spacing
   guide gives the example as text, "16". The take-out sentence asks for takeOut "yes" and an x and a y "of their own".
   This is the wording kept.

**The hosted model, per case.** Each cell is right, then right tool, of 3.

| Command | Before | Round 1 | Round 3 | Round 4, kept |
|---|---|---|---|---|
| "Put these in a column" (two fields selected) | 2, 3 | 2, 3 | **3**, 3 | **3**, 3 |
| "Make these a row" (two fields selected) | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| "Make the card a grid of two" | 3, 3 | 3, 3 | 3, 3 | 2, 3 |
| "Space the row out more" | 0, 3 | 0, 3 | 1, 3 | **2**, 3 |
| "Ungroup the row" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| "Move the toggle before the label" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| Control: "Take the toggle out of the row" | 1, 3 | **3**, 3 | 1, 3 | 1, 3 |
| Control: "Make the button half width" (in a column) | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| **Total** | **18 of 24**, 24 | **20**, 24 | **20**, 24 | **20**, 24 |
| Apart: "Stack the title, the button and the image into a column." | 0, 0 | 0, 0 | 0, 0 | 0, 0 |

Round 2's run was stopped after 11 runs: "put these in a column" 1 of 3, "make these a row" 3 of 3, the grid 3 of 3,
and the spacing 0 of 2.

**What the misses were.**
- **The spacing.** Before, all three gave `spacing: 24`, a number, so the call couldn't be read and nothing changed. From
  round 1 the spacing is text every time, but the model then sometimes sets it again, each time a step past the
  spacing the canvas now shows: 24, 40, 60, … up to 800. The runs that did this set it 7, 12 and 15 times in round 1;
  15 and 4 times in round 3, beside one that stopped at 24; 5 times in round 4, beside two that stopped at 24. A command is one
  step to undo, so one "undo" takes it all back.
- **Taking the toggle out.** The score hides a change here. Before, both misses were a second call after a first the
  app turned down: one left x and y out, one gave the toggle's own spot. Both second calls took the toggle out, so
  every run ended with it out. In round 3 one miss was like those, but in the other the model put x and y inside
  takeOut, "yes x112 y305": five calls, all turned down, the toggle left in the row, and "Done". In round 4, the wording
  kept, it put them inside takeOut in both misses. One recovered on its second call; the other made **21 calls**, all
  turned down, and said "Done" with the toggle still in the row. This first appears in round 3, the round that added
  "give it everything in one call" to the rules. Round 4's `takeOut "yes" and an x and a y of their own` didn't remove
  it. Fix round 1, below, aims at it.
- **"Put these in a column"**, before and in round 1: after grouping the two fields, the model grouped everything on
  the screen, the new column too, then asked which elements were meant. From round 3, not once.
- **The grid**, once in round 4: `layout: grid`, with no count, which the app makes a grid of 1.
- **"Stack … into a column"** made a column with `groupElements` every time, before any change too. On the
  on-device model the same words went to `stackElements` (2026-11-26, 01:58).

Round 2 on the on-device model, per case:

| Command | Round 2, on-device list | Round 2, all tools |
|---|---|---|
| "Put these in a column" | 0 of 5: `stackElements` E8, E9 | **5 of 5** |
| "Make these a row" | 0 of 5: `groupElements` E6, E7 as row (right tool) | 0 of 5: `groupElements` E6, E7 as row (right tool) |
| "Make the card a grid of two" | 0 of 5: `groupElements` E2 as grid | 0 of 5: `groupElements` E3, E4 as grid of two |
| "Space the row out more" | 0 of 5: `tidyScreen` | **5 of 5** |
| "Ungroup the row" | **5 of 5** | **5 of 5** |
| "Move the toggle before the label" | 0 of 5: `placeElement` | 0 of 5: `placeElement` |
| Control: "Take the toggle out of the row" | 0 of 5: `ungroup` | 0 of 5: `ungroup` |
| Control: "Make the button half width" | **5 of 5** | **5 of 5** |
| **Total** | **10 of 40** (right tool 15) | **20 of 40** (right tool 25) |

Its `newtools` run gave every call the same as before.

**Why round 2's descriptions weren't kept.** They added 87 tokens to the on-device profile, 3,377 with one screen, and
won it nothing: still 10 of 40 on the structure cases. "Make these a row" moved to `groupElements` but named the row's
own children, E6 and E7. With all tools they lifted the structure cases from 15 to 20 of 40, all of it "put these in a
column". Its older tools were unchanged. The hosted model already picked the right tool every time.

**The on-device model.** With its list, every case gave the same calls before and after, in all five runs. With all
tools, `setLayout`'s longer description changed the elements two wrong calls named, not their score.

| Command | Before, on-device list | After, on-device list | Before, all tools | After, all tools |
|---|---|---|---|---|
| "Put these in a column" | 0 of 5: `stackElements` E8, E9 | 0 of 5: the same | 0 of 5: `stackElements` E8, E9, E11 | 0 of 5: `stackElements` E6, E7 |
| "Make these a row" | 0 of 5: `stackElements` E6, E7 | 0 of 5: the same | 0 of 5: the same | 0 of 5: the same |
| "Make the card a grid of two" | 0 of 5: `groupElements` E2 | 0 of 5: the same | 0 of 5: `groupElements` E2 | 0 of 5: `groupElements` E3, E4 |
| "Space the row out more" | 0 of 5: `tidyScreen` | 0 of 5: `tidyScreen` | **5 of 5** | **5 of 5** |
| "Ungroup the row" | **5 of 5** | **5 of 5** | **5 of 5** | **5 of 5** |
| "Move the toggle before the label" | 0 of 5: `placeElement` | 0 of 5: `placeElement` | 0 of 5: `placeElement` | 0 of 5: `placeElement` |
| Control: "Take the toggle out of the row" | 0 of 5: `ungroup` | 0 of 5: `ungroup` | 0 of 5: `ungroup` | 0 of 5: `ungroup` |
| Control: "Make the button half width" | **5 of 5** | **5 of 5** | **5 of 5** | **5 of 5** |
| **Total** | **10 of 40** | **10 of 40** | **15 of 40** | **15 of 40** |

Each cell of the older tools is right, then right tool.

| Commands | Before, on-device list | After, on-device list |
|---|---|---|
| Tidy, 11 commands | 50 of 55, 50 of 55 | 50 of 55, 50 of 55 |
| Change device, 5 commands | 25 of 25, 25 of 25 | 25 of 25, 25 of 25 |
| New screen, 6 commands | 20 of 30, 30 of 30 | 20 of 30, 30 of 30 |
| Controls, 5 commands | 15 of 25, 20 of 25 | 15 of 25, 20 of 25 |

**The profile's size.** The on-device profile with one screen is 3,290 tokens, as before; the pencil's is 3,231.
With all 25 tools it is 3,635, up from 3,590, from `setLayout`'s longer description.

**The live tests.** `VoiceAgentLiveTests` passed 9 of 9 before and after. After: "Put the two texts at the bottom in a
row" called `groupElements` once, and "Move the toggle before the label" called `reorder` once.

**What it led to, at first.** I stopped after round 4 and called the moves that were left noise. That was wrong for
take-out: its new failure has a cause in the wording (above), and the scores couldn't see a run that ended in "Done"
with nothing done. Three runs a case do let a case move by one between rounds: "put these in a column" went 2, 2, 3,
3. "More" set again and again held through three wordings, so it may need the app itself to stop it:
- refuse a second change to the same thing in one command;
- not tell a hosted model the canvas again after a tool for a command that says "more".

### Fix round 1 (2026-11-26)

A review found what the scores above can't see. In round 4, the wording first kept, one take-out run made 21 calls the
app turned down and said "Done" with the toggle still in the row. The review also found that the "once" rule had only
been tried on commands that never need a tool twice. So this round changed how the hosted cases are scored, added three
live commands, and ran three more rounds of wording. Only what a hosted model is told changed. The on-device profile is
the same, byte for byte.

**What changed in the measurement.**
- **Where the design ends up.** `VoiceStructureLiveTests` now also checks it, case by case. "Right" is now the
  harness's right with the design where the command asked. A run that ends in "Done" with nothing done is counted as
  "said done, not done". Spacing counts as done when it is raised once, in one call, to no more than 48: one step
  more, not a spacing raised again and again. (Fix round 2 tightened this from "anywhere from 13 to 48", which let one
  run of three raises, to 48, count as done; the figures here are scored the tightened way.)
- **In view.** The screen is now in view, marked "[in view]" as the harness's is. A test that runs in CI,
  `VoiceStructureDesignTests`, compares the whole canvas text with the harness's. The only differences it allows are
  the toggle's colour and the label's y.
- **Three live commands** that need a tool more than once, judged by where the design ends up: "Undo the last two
  changes", "Add three buttons", and "Rotate it 45 degrees, then 45 more", said with the button selected.
- **More runs of one case.** `TEST_RUNNER_LAYER_STRUCTURE_RUNS` and `_ONLY` run chosen cases ten times.
- Round 4 was measured again this way. The numbers below aren't comparable with the earlier rounds' for that reason.

**The rounds.** Each is a change to the full rules or `setLayout`, on top of round 4.

5. Takes out "Never call the same tool on the same element twice… give it everything in one call". In its place: "make
   that change once", a command for several things is "a call for each", and "If a tool's reply says it couldn't be
   done, fix what the reply names and call it again". The take-out sentence becomes: takeOut "yes", "and x and y as
   values of their own, never written into takeOut". `setLayout`'s layout guide adds "always said" to the grid's number.
6. Round 5's take-out sentence and "a call for each", with round 4's brake back: "Never call the same tool on the same
   element twice in one command, unless its reply said it couldn't be done." The guide is as before. `setLayout`'s
   description gains "For "a grid of two", the layout is "grid of 2": a grid always says how many columns."
7. **Kept.** Round 6, plus "'45 more' is rotateElement with by 45, from where it is." beside the full rules' line on
   turning. The on-device rules keep their own line.

**What was run.** The 1-minute load was 1.64 to 84.47 at the starts. Another lane built and ran LM Studio alongside,
untimed. MEASURING appeared twice, at 07:34:45 and 07:47:07. Each time the round 4 structure run was stopped and started
again. A third try, started 07:49:23, was stopped at 07:53 to change how the suite waits: from then on it pauses inside,
before each request, while MEASURING exists, and it paused for about 3 minutes in the run at 07:54:57. LM Studio crashed
at about 08:19 ("The model has crashed", then "Model is unloaded") during round 5's live tests. The 4 tests it hit were
run again and are counted from that rerun.

| Run | Start | Load (1, 5, 15 min) before |
|---|---|---|
| Round 4: `VoiceStructureLiveTests`, tries stopped for MEASURING | 07:33:52, 07:37:45 | 5.84, 21.92, 17.39 for the second; the first not recorded |
| Round 4: `VoiceStructureLiveTests`, third try, stopped at 07:53 | 07:49:23 | not recorded |
| Round 4: `VoiceStructureLiveTests` | 07:54:57 | 22.26, 32.40, 38.88 |
| Round 4: `VoiceAgentLiveTests`, 12 | 08:03:47 | 4.19, 14.48, 27.15 |
| Round 5: `VoiceStructureLiveTests` | 08:08:15 | 3.34, 12.10, 23.32 |
| Round 5: `VoiceAgentLiveTests`, 12 | 08:17:45 | 4.04, 7.22, 16.13 |
| Round 5: the 4 live tests the crash hit, again | 08:21:22 | 6.21, 12.28, 16.99 |
| Round 6: `VoiceStructureLiveTests` | 08:23:30 | 11.38, 15.18, 17.74 |
| Round 6: `VoiceAgentLiveTests`, 12 | 08:28:40 | 4.47, 13.17, 17.01 |
| Round 6: take-out, 10 runs | 08:31:57 | 4.34, 11.77, 15.94 |
| Round 6: spacing, 10 runs | 08:34:43 | 6.51, 13.23, 16.16 |
| Round 6: the new screen once, the turn three times | 08:44:34 | 1.64, 6.11, 12.18 |
| Round 4: take-out, 10 runs | 08:48:40 | 28.67, 29.73, 22.21 |
| Round 4: spacing, 10 runs | 08:50:56 | 14.43, 29.13, 23.56 |
| Round 4: the turn, 4 times | 08:52:56 | 12.80, 26.51, 23.47 |
| The wording before this task (8d92b8d): the turn, 4 times | 08:58:40 | 8.05, 29.69, 28.11 |
| Round 7: the turn, 4 times | 09:02:57 | 46.84, 54.26, 40.44 |
| Round 7: `VoiceStructureLiveTests` | 09:05:06 | 84.47, 68.92, 48.38 |
| Round 7: `VoiceAgentLiveTests`, 12 | 09:10:16 | 4.83, 33.76, 39.36 |
| Round 7: take-out, 10 runs | 09:13:42 | 6.61, 25.96, 35.39 |
| Round 7: spacing, 10 runs | 09:16:17 | 17.35, 31.20, 36.72 |
| Round 7: `run.sh structure 1`, the on-device list | 09:20:36 | 4.08, 19.21, 30.44 |
| Round 7: spacing, 10 more runs | 09:26:30 | 11.39, 21.98, 28.50 |
| Round 4: spacing, 10 more runs | 09:30:48 | 3.55, 14.04, 23.61 |

**The eight cases, 3 runs each.** Each cell is right, then done, of 3. Right tool was 3 of 3 in every cell.

| Command | Round 4 | Round 5 | Round 6 | Round 7, kept |
|---|---|---|---|---|
| "Put these in a column" | 3, 3 | 3, 3 | 2, 3 | 3, 3 |
| "Make these a row" | 3, 3 | 2, 3 | 3, 3 | 3, 3 |
| "Make the card a grid of two" | 1, **2** | 2, **2** | 3, 3 | 3, 3 |
| "Space the row out more" | 3, 3 | 1, **1** | 3, 3 | 2, **2** |
| "Ungroup the row" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| "Move the toggle before the label" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| Control: "Take the toggle out of the row" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| Control: "Make the button half width" | 3, 3 | 3, 3 | 3, 3 | 3, 3 |
| **Right** | **22 of 24** | **20** | **23** | **23** |
| **Said done, not done** | 1 | 3 | 0 | 1 |
| Apart: "Stack … into a column" (done) | 0 (3) | 1 (3) | 0 (3) | 0 (3) |

Where right and done differ, the model made a second call; done counts the design however it got there. The misses:
- **The grid.** In round 4 and round 5, `layout: grid` with no count, which the app makes a grid of 1. In round 5 one
  run went on to group and ungroup the card's contents in 6 calls and ended a grid of 1. None in rounds 6 and 7, after
  the description's example.
- **The spacing.** Raised again and again: in round 5, to 180 and 120; in round 7, to 80.
- **"Make these a row"** in round 5, and **"put these in a column"** in round 6: the group was made, then a second call
  changed something else. In round 5 run 2 the model resized Email to 170, unasked. In round 6 run 1 it wrapped E2, E5,
  the new column E13 and E10 in another column, E14. Both count as done, because done checks only what was asked (the
  fields in a row, or a column, of their own), not that nothing else changed.

**More runs of the cases that moved.** Done, of the runs made. Where the spacing was raised again and again, the calls
it took are in brackets.

| Case | Round 4 | Round 6 | Round 7, kept |
|---|---|---|---|
| "Take the toggle out of the row", 10 runs | 10 | 10 | 10 |
| "Space the row out more", first 10 runs | 8 (3 and 4 calls) | 7 (6, 6 and 10) | 7 (3, 4 and 4) |
| "Space the row out more", 10 more runs | 8 (4 and 4) | not run | 6 (4, 3, 10 and 3) |
| "Space the row out more", with the 3 above: done | **19 of 23** | 10 of 13 | **15 of 23** |

With the three runs above, round 4's take-out was done 13 of 13, and so was round 7's. The 21-call run of round 4's
first measurement didn't come back in 13 runs, so it can't be pinned on round 4's wording or cleared of it. Round 7 says
outright not to write x and y into takeOut.

**The live tests.** All 12 passed on round 4 and on round 7, each at the first try. Round 5 passed all 12 once the 4
tests the crash hit were run again. Round 6 failed 2. The new screen failed once with "Failed to parse generated
content" while the screen was being written, and passed when run again. The turn failed in the 12 and in 1 of 3 runs
after.

The turn, run again on each wording, 4 times (3 on round 6); the turn's run in the 12 is counted in the last column:

| Wording | Turned to 90° | All runs of the turn |
|---|---|---|
| Before this task (8d92b8d) | 2 of 4 | 2 of 4 |
| Round 4 | 3 of 4 | 4 of 5 |
| Round 6 | 2 of 3 | 2 of 4 |
| Round 7, kept | **4 of 4** | **5 of 5** |

The misses turned it to 45 twice, angle 45 and then angle 45 again. That happens before this task's wording too, so the
"once" rule didn't cause it. Round 7's "45 more" line fixes it in these runs: each turned to 45, then by 45. "Undo the
last two changes" undid two steps every time, and "Add three buttons" added three, on every wording. In round 5 the
model also aligned each new button to the bottom.

**The on-device model.** Rounds 5 to 7 changed only the full rules and `setLayout`, which it isn't handed. With round
7's wording, `run.sh structure 1` printed the same profile, 3,290 tokens with one screen, and made the same calls as the
first run before this task.

**What it led to.** Round 7's wording is kept: 23 of 24 right, take-out done 13 of 13, the grid 3 of 3, and the turn 5
of 5. All 12 live tests passed at the first try. Spacing is the case it doesn't settle. In every wording, some runs
raised the spacing again and again, two to nine steps more, and said "Done" or asked a question: round 4 in 4 of 23
runs, round 7 in 8 of 23 (corrected in fix round 2, which counts only one raise as done: one round-7 run raised it three
times, to 48, and was counted done). A difference that size would turn up by chance about a third of the time (Fisher's
exact, p ≈ 0.31). Round 7 is worse there by about one "space it out more" in six, and it doesn't meet the bar that no
case ends in "Done" with its end state unmet in 3 runs; neither does any wording tried, over enough runs. Seven
wordings haven't stopped it. One of the app-side fixes above is the next step.

### Fix round 2 (2026-11-26)

A second review found two things.
- One round-7 run raised the spacing three times, to 48, and was counted as done. The figures above are corrected for
  it: spacing is now done only when raised once, in one call.
- The kept rules say neither to combine nor to repeat when one command asks two things of one element, and no live
  test tried that. The "45 more" line is also the turn test's own phrase.

So three live commands were added, each judged by where the design ends up and by its calls, at most one for each
change asked for:
- "Make the title bigger and bold", with the title made regular first;
- "Move it down and make it half as wide", with the button selected; half of its 353 points or half the screen both
  count;
- "Rotate it 30 degrees, then 30 more".

**Spacing, scored the tightened way.** Done means raised once, in one call. The calls each runaway took are in brackets.

| Wording | Runs | Done | Ran away |
|---|---|---|---|
| Round 4 | 23 | 19 | 4 (4, 3, 4, 4) |
| Round 5 | 3 | 1 | 2 (7, 6) |
| Round 6 | 13 | 10 | 3 (6, 6, 10) |
| Round 7, kept | 23 | 15 | 8 (4; 4, 4, 3; 4, 3, 10, 3) |
| Round 8, below | 3 | 1 | 2 (3, 3) |

**The new commands on round 7,** 3 runs each, from 09:48:53 (load 1.74, 3.06, 9.66):

| Command | End state reached | Within a call for each change |
|---|---|---|
| "Make the title bigger and bold" | 3 of 3: bold, 32, 48 and 32 pt | 2 of 3. The miss restyled it 3 times, to 48 pt |
| "Move it down and make it half as wide" | 3 of 3: half width, moved down | 1 of 3. The misses moved it at least 7 and 5 times, to y830 and y750 of the screen's 852 |
| "Rotate it 30 degrees, then 30 more" | 3 of 3: 60° | 3 of 3: 30, then by 30 |

The misses are the spacing's runaway again: "bigger" and "down" made again each time the canvas showed the last change.

**Round 8,** the reviewer's wording, in the full rules only. The once line became "Give a tool everything one element
needs in one call, such as a colour and a size in one look, or a place and a width in one move, and call the same tool
on the same element again only if its reply said it couldn't be done", with "Carry out a command once", "more, bigger
and further" and "a call for each" kept.
- The eight cases, 3 runs each, from 10:01:12 (load 40.17, 53.34, 37.96): **20 of 24 right**, 22 of 24 done, 2 said
  done with it not done, against round 7's 23, 23 and 1. "Put these in a column" was right 1 of 3, done 3 of 3: a second
  call after the group. The spacing was raised 3 times in 2 runs, to 60.
- The live tests, once each, from 10:07:12 (load 3.31, 21.26, 28.14): 14 of 15 passed, the three new ones among them.
  "Move it down and make it half as wide" moved the button 5 times, then wrote on without end. The log shows it turning
  over "move it down" again and again, 12,554 streamed pieces in 10 minutes without a call or an answer. The run was
  stopped at 10:21.

Round 8 is worse on the eight cases and on the move, so it wasn't kept, and the rest of its runs weren't made. Round 7
stays.

**What it led to.** Round 7's wording stays, with its costs:
- about one "space it out more" in three runs away (8 of 23 runs);
- a compound command with "bigger" or "down" in it sometimes makes that change two to six times too many (3 of 6 runs
  above).

Every one of these ends with the design changed in the direction asked, and one undo takes back the whole command.
Eight wordings haven't stopped "more", "bigger" or "down" being carried out again each time the canvas shows the
change. One of the app-side fixes above is the next step: refuse a second change to the same thing in one command, or
don't tell a hosted model the canvas again mid-command.

The full CI plan, from 10:24:51 (load 19.32): 2,279 tests in 215 suites passed. An earlier full run, from 10:21:58,
failed only `OpeningDesignTests`' timing test, which passed when run alone and in the rerun.

## Not measured here

- Speech, on the Mac. The commands there were typed, so mishearing is not in its numbers.
- The app carrying the commands out. That is covered by the app's own tests, with a
  scripted model, and by the live run in [voice-agent.md](voice-agent.md).

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

## Not measured here

- An iPad. This is the Mac's on-device model; the iPad's has not been run.
- Speech. The commands were typed, so mishearing is not in these numbers.
- The app carrying the commands out. That is covered by the app's own tests, with a
  scripted model, and by the live run in [voice-agent.md](voice-agent.md).
- Commands in a row. Each command here started a new conversation.

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
- Whether the warm start and the shorter "Done" do on an iPad what the log says they
  should has not been measured yet.

## Not measured here

- Speech, on the Mac. The commands there were typed, so mishearing is not in its numbers.
- The app carrying the commands out. That is covered by the app's own tests, with a
  scripted model, and by the live run in [voice-agent.md](voice-agent.md).
- Commands in a row. Each command here started a new conversation.

# The zoom ruler and typed screen edits: design

Date: 2026-11-18. Status: the user asked for both to be built ("go ahead and implement the zoom
ruler and typed edits then"), skipping a separate design round; the calls below are mine.
Branch: `feature/zoom-screen-edits` (worktree `.claude/worktrees/zoom-screen-edits`), from
`feature/rotation` at 71e0c29 (it uses rotation's per-field ruler options and main's Pencil
push-to-talk, both on that branch).

Background: `reports/Rotation grouping selection and zoom.md` (sections on the zoom control and
on a scoped edit field) and `research_notes/Rotation grouping selection and zoom/`
(`pencil_pro_zoom_control.md`, `typed_screen_edits.md`, the code audit §6); the push-to-talk
design `docs/superpowers/specs/2026-11-18-pencil-ptt-design.md`.

## What the user asked for

- **Zoom:** "collapse the zoom button. remove the -/+ buttons. instead it'll get the same ruler
  treatment as the numerical values currently in the edit panel + the apple pencil hover squeeze
  and rotate gesture too. the zoom button will still show the value, and tapping on it still
  reveals the default zoom menus."
- **Typed edits:** "for a screen frame's edit menu, include a textfield enabling typed generative
  edits for the screen and all the elements in it, press and holding the textfield will trigger
  voice mode instead."

## Zoom ruler: my calls

- The −/+ buttons go. The percentage stays, and a tap on it opens the same menu as today (Lock
  Canvas, Zoom to Fit Content, 25/50/100/200/400%).
- **Hold and drag** on the percentage (0.35 s, then sideways) scrubs the zoom, with the same
  ruler as the format panel's fields. **Pencil Pro:** hovering over it and squeezing brings the
  ruler up; rolling the barrel steps it; squeezing again keeps it.
- **Steps are zoom stops, not single percents:** 10, 15, 20, 25, 33, 50, 67, 75, 100, 125, 150,
  200, 250, 300, 400% (within the canvas's 10–400% range). Equal finger travel then feels equally
  dense at any zoom (the research's multiplicative-step advice), and a scrub from a zoom between
  stops starts at the nearest stop. 16 pt of finger per stop; 10° of barrel per stop; a tick per
  stop. The canvas zooms about the middle of the view, as the menu's levels do.
- **One ruler for the window.** The `Scrubber` that today lives inside the format panel moves up
  to the canvas screen and is shared by the panel and the zoom control, with **one** squeeze
  handler for both (Apple fires every visible `.onPencilSqueeze`), present only while Draw is
  off, as the canvas's push-to-talk squeeze layer is (a handler while Draw is on stops the
  PencilKit palette's own squeeze). A squeeze that push-to-talk owns is left alone, as today.
- Zooming isn't an edit: a zoom scrub isn't an undo step.
- VoiceOver: the zoom control is adjustable (swipe up and down steps through the stops) and keeps
  its menu.

## Typed screen edits: my calls

- When **one screen** is selected, the popover above it gets a field, "Describe a change…", and a
  send arrow. What is typed goes to the same agent voice mode uses, about that screen and
  everything on it; the change is applied straight to the design as **one undo step**, and the
  field clears. While it runs, the field shows what the agent is doing ("Restyling…"); after,
  its reply line shows for a few seconds. The model is told the selected screen in full and other
  screens by name only, so it can't wander off the screen.
- **Press and hold** the field (0.35 s, push-to-talk's threshold) to speak instead: it listens
  while held, with push-to-talk's bubble at the field, and sends when let go. A quick tap starts
  typing. The hold works only before the field is being typed in (the system owns long presses
  in a text field it is editing), so the field shows as a plain line until tapped, as the format
  panel's number fields do.
- It reuses push-to-talk's listening machinery (one listener at a time; with a phone call up,
  holding only says what the next command is about, as a Pencil squeeze does).
- Without a model that can be asked (no Apple Intelligence and no hosted model), the field is
  disabled and says why, as voice mode does.
- VoiceOver: a "Speak a change" action starts listening and a second use sends.
- Rename isn't added: the request covers editing the screen and its elements with the tools voice
  already has (restyle, add, delete, move, align, stack, retext, tidy, device, turn).
- This makes voice reachable in wide windows for the first time (the phone button only shows in
  narrow ones).

## Non-goals

- A zoom slider or dial elsewhere; changing pinch zoom.
- Typed edits for elements, several things, or the open canvas (screens only, as asked).
- Regenerating a whole screen from a prompt (the library's generation does that).

---
name: build-screen
description: Builds a new phone or iPad screen, or rebuilds an existing one, in a Layer design from a spoken description of what is on it.
---
Use the build screen from spec tool when the person describes a whole screen or most of one, such as "a login screen with email, password and a sign in button". Use the add element tool instead when they add one or two things to a screen that already exists.

If no design is open and they didn't name one, ask whether to use a new design, and use the create design tool if so.

Keep the elements in the order the person said them, top to bottom. Put things they describe as side by side, such as "cancel and done buttons next to each other", in one row section. A screen usually starts with a title. Text fields come before the button that submits them.

Default to an iPhone screen unless they say iPad, iPhone Pro Max or iPhone SE. Name the screen after its purpose, such as Login or Settings.

To change an existing screen's whole layout, use the build screen tool with that screen as the screen to rebuild; it replaces what is on it, and it can be undone.

After building, say how many elements were added and offer to generate the SwiftUI code. Never delete a screen to rebuild it.

# Paste this into a fresh Claude session in your Swift app

I want to add a `/vim` slash command and full vim editor mode to a text
input in this Swift app. Pressing `/`, typing `vim`, then space or
Enter should toggle vim keybindings on the focused text field.
Subsequent keystrokes act as vim's normal mode (`hjkl`, `w/b/e`, `dd`,
`yy`/`p`, `i`/`a`/`o`, `R`, `v`, `/foo`, `f<x>`, `gU{motion}`, text
objects `iw`/`i"`/`i(`, marks `m<a-z>`, `.` repeat, etc.). Exit vim
with `:q<Enter>`, `:wq<Enter>`, or clicking the mode badge.

## What this is — and where the canonical reference lives

VimEngine is a portable Swift Package at
[`msjurset/swift-vim-engine`](https://github.com/msjurset/swift-vim-engine).
It's the engine only — the state machine, the `VimTextEditor`
protocol, and a built-in `NSTextView` conformance. Host-side
integration (text-view subclass, mode badge UI, slash-command
trigger) is **not** in the package; it lives in the consumer app.

Canonical host implementation: [`msjurset/jrnlbar`](https://github.com/msjurset/jrnlbar).
Adapt its patterns; don't blindly copy. Specifically:

- `Sources/JrnlBar/Views/EntryEditorView.swift` — NSTextView subclass
  with keyDown forwarding, block-cursor rendering, scroll-into-view
  override, autocomplete suspension while vim is active.
- `Sources/JrnlBar/Views/ContentView.swift` — search for `slashPrefix`,
  `vimEngine`, `modeBadge`, `activateMode`, `exitCurrentMode`. The
  lifecycle pattern is what to mimic.
- `Sources/JrnlBarMain/JrnlBarApp.swift` — search for `isVimActive` and
  `vimStateChanged`. Shows how a panel-level Esc monitor yields to
  vim while it's active, then takes Esc back on vim exit.
- `Sources/JrnlBar/Views/VimCheatsheetView.swift` — SwiftUI popover
  with every supported vim command. Copy verbatim if useful.

The engine's public API and supported commands are documented at
[`swift-vim-engine/README.md`](https://github.com/msjurset/swift-vim-engine/blob/main/README.md).
**Read it first.** It also documents deliberate omissions (insert-mode
`.` replay of `R` overstrike sessions, named registers, macros,
sentence motions, `:%s///`, automatic visual marks). Don't add these
without asking me.

## Centralize the integration — one shared component, not N copies

**Before you touch a single text input**, decide where the vim-host
integration code will live. It is **one** subclass / **one**
representable / **one** Coordinator. Every text input in the app that
wants vim mode uses that same component. Do not copy-paste the
`keyDown` forwarder, the `drawInsertionPoint` block-cursor, or the
`setSelectedRanges` override into multiple text-view subclasses.

Concrete pattern:

- **One** NSTextView subclass (call it `VimHostTextView`) that holds
  `vimEngineProvider` / `currentModeProvider` closures and implements
  every vim-related override (keyDown, drawInsertionPoint,
  setSelectedRanges, the insertText override for `R` overstrike).
- **One** NSViewRepresentable wrapper (call it `VimHostEditor`) that
  binds the engine, text, mode, and pendingCursor in/out of SwiftUI.
- **One** ContentView-side lifecycle helper (call it
  `VimModeController` or similar) that owns `vimEngine: VimEngine?`,
  exposes `activate()` / `exit()`, sets up `onExit`, `onSubmit`,
  `onSubmodeChanged`, and broadcasts `vimStateChanged`.

If the app has more than one input that needs vim (e.g. journal entry
field AND a comment field), they each instantiate `VimHostEditor` with
their own `@State` bindings — but the editor's *type* is shared. Same
keyDown logic, same cursor renderer, same scroll fix. Adding a vim
feature touches one file, not N.

If the existing app already has duplicated text-view subclasses
(common in larger codebases), the **first** task is to consolidate
them to a single base class. Do that before adding vim — adding to two
classes locks in the duplication.

## Integration steps

1. **Add the package dependency** to `Package.swift`. Use the lowest
   floor that contains the features you need. `2.0.0` is the
   `@MainActor`-isolated line and is the right default for AppKit /
   SwiftUI hosts:

       dependencies: [
           .package(url: "https://github.com/msjurset/swift-vim-engine.git", from: "2.0.0")
       ]

   and on every consumer target:

       .product(name: "VimEngine", package: "swift-vim-engine")

   Run `swift package resolve`, then commit `Package.resolved` so
   collaborators get the same version.

2. **Forward `keyDown` to the engine** in your NSTextView subclass:

       override func keyDown(with event: NSEvent) {
           if let vim = vimEngineProvider?() {
               let prevSubmode = vim.submode
               let handled = vim.handleKey(
                   chars: event.charactersIgnoringModifiers,
                   keyCode: event.keyCode,
                   modifiers: KeyModifiers(event.modifierFlags),
                   editor: self
               )
               if handled {
                   if prevSubmode != vim.submode {
                       invalidateBlockCursorArea()
                   }
                   return
               }
           }
           super.keyDown(with: event)
       }

   `Cmd+V/C/X/Z` and similar still go through `performKeyEquivalent`
   *before* `keyDown`, so they keep working.

3. **Block cursor** — override `drawInsertionPoint(in:color:turnedOn:)`.
   When `vim.submode != .insert`, fill a one-character-wide cell at
   the caret. Reference: `blockCursorRect()` and `approximateCharWidth()`
   in jrnlbar's `EntryEditorView.swift`. Handle the newline edge case
   (vim shows a normal-width block on empty lines, not a full
   line-width fill).

4. **Override `setSelectedRanges(_:affinity:stillSelecting:)`** — this
   one override has two responsibilities.

   **a. Scroll the caret into view.** VimEngine writes
   `editor.selectedRange = ...` directly to move the caret. That
   setter on `NSTextView` does **not** call `scrollRangeToVisible`
   (AppKit's "keep caret visible" behavior is a side effect of
   `insertText`, which vim's keystrokes bypass). Without this fix,
   `j`/`k`/`G`/`gg`/`n` walk the caret off the bottom of the visible
   area. After `super.setSelectedRanges`, when vim is active and the
   change isn't a mid-drag selection:

       if !stillSelecting,
          let primary = (ranges.first as? NSValue)?.rangeValue {
           scrollRangeToVisible(NSRange(location: primary.location, length: 0))
       }

   Zero-length range so visual-mode selections that span screens don't
   scroll to the far end — the caret position is what matters. Gated
   on vim being active so unrelated `setSelectedRange` calls
   (find-in-page, accessibility tooling) keep AppKit's defaults.

   **b. Invalidate the block-cursor cell.** Only when
   `vim.submode != .insert`. On vim→insert / insert→vim transitions in
   `keyDown`, also call `invalidateBlockCursorArea()` so the cursor
   shape flips immediately without needing a caret move.

   **Don't try to be clever with partial invalidation.** The original
   jrnlbar implementation computed OLD and NEW block-cursor rects and
   called `setNeedsDisplay(rect:)` on each. That looked right but
   caused stale "double cursor" pixels in practice: AppKit sometimes
   coalesced or skipped the partial invalidation under load, leaving
   the previous block visible after a fast move. The fix is to force
   a full repaint with `needsDisplay = true` whenever the caret moves
   in a block-cursor submode. The text view is small; the cost is
   fine.

5. **Mode badge UI.** A small button/pill in your toolbar or status
   area showing `engine.badge` (`VIM:N`, `VIM:I`, `:q`, `/term`).
   Click clears the mode. Wire `engine.onSubmodeChanged` and
   `engine.onCommandBufferChanged` to refresh the badge text.

6. **Esc arbitration.** If your app has its own Esc handler (e.g.
   dismiss a panel), check whether vim is active first and yield.
   Mirror the `vimStateChanged` notification pattern in jrnlbar's
   `JrnlBarApp.swift`.

7. **Activation trigger** — pick *one*:
   - **Simplest: a single global hotkey** (e.g. `Ctrl+Cmd+V`).
     Instantiate a `VimEngine`, set `onExit` to nil-out the reference.
     Done.
   - **`/vim` slash command** (the source-app UX): port the
     `SlashCommand` + `SlashCommandRegistry` + `SlashSuggestionView`
     files from jrnlbar. Wire prefix detection in `textDidChange`.
   - **Toolbar button** that toggles a `VimEngine?` state.

8. **Suspend other autocomplete while vim is active.** In your
   `textDidChange` (or equivalent), short-circuit any `@tag` /
   autocomplete logic when `currentMode == .vim`. Reference:
   `EntryEditorView.swift`'s `Coordinator.textDidChange` in jrnlbar.

## What "done" looks like — smoke test

After integration:

- Open the app, focus the text input.
- Trigger vim (your chosen activation).
- Mode badge shows `VIM:N`. Caret becomes a translucent block.
- Press `i`, type "hello world", press `Esc`. Badge flips
  `VIM:I` → `VIM:N`. Block returns.
- Press `0` to go to line start, `w` to next word, `x` to delete char,
  `dd` to delete line, `u` to undo. All work.
- Press `yy`, then `p`. Line is duplicated.
- Press `v`, move with `l`, press `d`. Selection is deleted.
- Type `/hello<Enter>`. Cursor jumps to first "hello". Press `n` to
  repeat.
- Type `:q<Enter>` or click the badge. Vim exits, beam cursor returns.
- Plain typing works again outside vim mode.

## Future updates

**Add a Makefile target so the update incantation is documented:**

    .PHONY: update-vim
    update-vim:
        @echo "Updating swift-vim-engine to the latest tagged release..."
        @swift package update swift-vim-engine
        @echo "Review Package.resolved, smoke test, then commit."

Then run `make update-vim` whenever you want to pick up a release in
the configured version range. Review `Package.resolved`, smoke-test,
commit.

**If a bump breaks your build, pin to the previous version while you
sort it out** — don't leave the app broken:

    .package(url: "https://github.com/msjurset/swift-vim-engine.git", exact: "2.0.0")

Then either adapt your host code to the new release's requirements,
or wait for a release that restores the expected behavior. Tell the
package maintainer if you think a release got the semver wrong (e.g.
a source-breaking change shipped as a patch bump instead of a major).

## Don't change behavior

- Slash commands are **case-insensitive** and use alphanumeric + `_` +
  `-` characters only. Reject anything else.
- The block cursor is a translucent fill (no border), one char wide,
  rendered behind the glyph so the character stays readable.
- Vim's `j` and `k` move by **visual** (post-wrap) lines, not logical
  lines. This is intentional.
- `/uc` mode in jrnlbar transforms typed chars to uppercase. If
  you're copying the SlashCommand framework, you can drop `/uc`
  unless you want it.

## Deliver

When you're done, give me:

1. The diff of files added/modified (including `Package.swift` and
   `Package.resolved`).
2. The integration verification you ran (the smoke test above).
3. A 3-line summary of any deviations from the source pattern and
   why.

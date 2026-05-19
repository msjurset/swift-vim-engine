# Paste this into a fresh Claude session in your other Swift app

---

I want to add a `/vim` slash command + full vim editor mode to a text input
in this Swift app. Pressing `/`, typing `vim`, then space or Enter should
toggle vim keybindings on the focused text field. Subsequent keystrokes act
as vim's normal mode (`hjkl`, `w/b/e`, `dd`, `yy`/`p`, `i`/`a`/`o`, `R`, `v`,
`/foo`, `f<x>`, `gU{motion}`, text objects `iw`/`i"`/`i(`, marks `m<a-z>`,
`.` repeat, etc.). Exit vim with `:q<Enter>`, `:wq<Enter>`, or clicking the
mode badge.

## Where the working implementation lives

A complete, tested implementation exists at:

    /Users/msjurseth/workspace/swift/jrnlbar

Read these two files **first** to understand the surface area:

1. `Sources/VimEngine/README.md` — the engine's public API and supported
   commands.
2. `Sources/JrnlBar/Views/EntryEditorView.swift` — the only host-side
   integration code you need to model.

## What to reuse

**Must copy (the engine):**

- `Sources/VimEngine/VimEngine.swift` — single-file pure-logic state machine
  with a `VimTextEditor` protocol. Includes a built-in `NSTextView`
  conformance behind `#if canImport(AppKit)`. ~1000 lines. Zero dependencies
  beyond Foundation + AppKit.

**Optional (the slash-command framework):**

- `Sources/JrnlBar/Models/SlashCommand.swift` — enum wrapping templates +
  built-in mode commands; `TextMode` and `ModeCommand` types.
- `Sources/JrnlBar/Models/Template.swift` — file-backed template with token
  substitution (`{{date}}`, `{{cursor}}`, …).
- `Sources/JrnlBar/Services/TemplateStore.swift` — disk seeding from
  `~/.local/share/jrnl/templates/`. Skip if your app doesn't need
  templates — replace with an in-memory list of just `/vim`.
- `Sources/JrnlBar/Services/SlashCommandRegistry.swift` — combines
  templates + built-in mode commands; `match(prefix:)`, `exactMatch(prefix:)`,
  `unescape(_:)` for `//cmd` save-time escape.
- `Sources/JrnlBar/Views/SlashSuggestionView.swift` — horizontal-scroll
  capsule dropdown.
- `Sources/JrnlBar/Views/VimCheatsheetView.swift` — a SwiftUI popover with
  every supported vim command. Copy verbatim.

**Reference only (do NOT copy verbatim — adapt the shape):**

- `Sources/JrnlBar/Views/EntryEditorView.swift` — NSTextView subclass with
  keyDown→engine forwarding, block-cursor rendering, autocomplete-suspended
  textDidChange, vim-aware selection invalidation, vim→off focus restoration.
- `Sources/JrnlBar/Views/ContentView.swift` — search for `slashPrefix`,
  `vimEngine`, `modeBadge`, `activateMode`, `exitCurrentMode`. The lifecycle
  pattern is what to mimic.
- `Sources/JrnlBarMain/JrnlBarApp.swift` — search for `isVimActive` and
  `vimStateChanged`. Shows how a panel-level Esc monitor yields to vim
  while it's active, then takes Esc back on vim exit.

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

This avoids the most common failure mode in cross-component
integrations: feature X works in editor A but is silently broken in
editor B because someone forgot to copy-paste the latest fix.

If the existing app already has duplicated text-view subclasses
(common in larger codebases), the *first* task is to consolidate them
to a single base class. Do that before adding vim — adding to two
classes locks in the duplication.

## Integration steps

1. **Add `VimEngine.swift` to the target.** Either drop it into your
   `Sources/` directly, or add it as a separate SwiftPM target (mirror
   what `Package.swift` does in the source repo).

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

3. **Block cursor** — override `drawInsertionPoint(in:color:turnedOn:)`. When
   `vim.submode != .insert`, fill a one-character-wide cell at the caret.
   Reference: `blockCursorRect()` + `approximateCharWidth()` in
   `EntryEditorView.swift`. Handle the newline edge case (vim shows a
   normal-width block on empty lines).

4. **Override `setSelectedRanges(_:affinity:stillSelecting:)`** — this
   one override has two responsibilities:

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

   **b. Invalidate the block-cursor cell.** Capture the OLD block
   rect before `super`, then after, invalidate both the OLD and NEW
   rects so AppKit repaints them (clears the previous block, draws
   the new one). Only needed when `vim.submode != .insert`. On
   vim→insert / insert→vim transitions in `keyDown`, also call
   `invalidateBlockCursorArea()` so the cursor shape flips
   immediately without needing a caret move.

   See `setSelectedRanges` in `EntryEditorView.swift` for the
   reference implementation that does both.

5. **Mode badge UI.** A small button/pill in your toolbar or status area
   showing `engine.badge` (`VIM:N`, `VIM:I`, `:q`, `/term`). Click clears the
   mode. Wire `engine.onSubmodeChanged` and `engine.onCommandBufferChanged`
   to refresh the badge text.

6. **Esc arbitration.** If your app has its own Esc handler (e.g. dismiss a
   panel), check whether vim is active first and yield. Mirror the
   `vimStateChanged` notification pattern in `JrnlBarApp.swift`.

7. **Activation trigger** — pick *one*:
   - **Simplest: a single global hotkey** (e.g. `Ctrl+Cmd+V`). Instantiate
     a `VimEngine`, set `onExit` to nil-out the reference. Done.
   - **`/vim` slash command** (the source-app UX): port the
     `SlashCommand` + `SlashCommandRegistry` + `SlashSuggestionView` files
     above. Wire prefix detection in `textDidChange`.
   - **Toolbar button** that toggles a `VimEngine?` state.

8. **Suspend other autocomplete while vim is active.** In your
   `textDidChange` (or equivalent), short-circuit any `@tag` / autocomplete
   logic when `currentMode == .vim`. Reference: `EntryEditorView.swift`'s
   `Coordinator.textDidChange`.

## What "done" looks like

Smoke test after integration:

- Open the app, focus the text input.
- Trigger vim (your chosen activation).
- Mode badge shows `VIM:N`. Caret becomes a translucent block.
- Press `i`, type "hello world", press `Esc`. Badge flips `VIM:I` → `VIM:N`.
  Block returns.
- Press `0` to go to line start, `w` to next word, `x` to delete char,
  `dd` to delete line, `u` to undo. All work.
- Press `yy`, then `p`. Line is duplicated.
- Press `v`, move with `l`, press `d`. Selection is deleted.
- Type `/hello<Enter>`. Cursor jumps to first "hello". Press `n` to repeat.
- Type `:q<Enter>` or click the badge. Vim exits, beam cursor returns.
- Plain typing works again outside vim mode.

## Don't add features

The engine is feature-complete enough (~290 unit tests in the source repo).
The cheatsheet view lists every supported command. If something feels
missing, check that first — it's probably already there. Deliberate
omissions are documented in `Sources/VimEngine/README.md` under "Deliberate
limitations" (`.` replay of `R` overstrike sessions, named registers,
macros, sentence motions, `:%s///`, automatic visual marks). Don't add
these without asking me.

## Don't change behavior

- Slash commands are **case-insensitive** and use alphanumeric + `_` + `-`
  characters only. Reject anything else.
- The block cursor is a translucent fill (no border), one char wide,
  rendered behind the glyph so the character stays readable.
- Vim's `j` and `k` move by **visual** (post-wrap) lines, not logical
  lines. This is intentional.
- `/uc` mode in jrnlbar transforms typed chars to uppercase. If you're
  copying the SlashCommand framework, you can drop `/uc` unless you want
  it.

## Deliver

When you're done, give me:

1. The diff of files added/modified.
2. The integration verification you ran (the smoke test above).
3. A 3-line summary of any deviations from the source pattern and why.

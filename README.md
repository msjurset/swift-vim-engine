# VimEngine

A portable mini-vim component for Swift apps that need vim-style
keyboard navigation in a text editor. Pure logic — no SwiftUI, no
project-specific types. Integrate by conforming your editor to
`VimTextEditor` and forwarding `keyDown` events to `handleKey`.

## Integration (macOS / AppKit)

`NSTextView` already conforms out of the box. Wire it up:

```swift
import VimEngine

let engine = VimEngine()
engine.onExit = { /* clear vim mode */ }
engine.onSubmit = { /* :w fired */ }
engine.onSubmodeChanged = { /* update badge / cursor shape */ }
engine.onCommandBufferChanged = { /* refresh ":foo" display */ }

// Inside your NSTextView subclass:
override func keyDown(with event: NSEvent) {
    let handled = engine.handleKey(
        chars: event.charactersIgnoringModifiers,
        keyCode: event.keyCode,
        modifiers: KeyModifiers(event.modifierFlags),
        editor: self
    )
    if !handled { super.keyDown(with: event) }
}
```

To render a vim-style block cursor in normal / command / replace mode,
override `drawInsertionPoint(in:color:turnedOn:)` and fill the cell
rect when `engine.submode != .insert`.

## Integration (iOS / UIKit)

`UITextView` is not built in. Add an extension in your app:

```swift
import VimEngine

extension UITextView: VimTextEditor {
    public var text: String {
        get { self.text ?? "" }
        set { self.text = newValue }
    }
    public var selectedRange: NSRange {
        get { /* convert UITextRange ↔ NSRange */ ... }
        set { ... }
    }
    public func replace(in range: NSRange, with string: String) { ... }
    public func vimUndo() { undoManager?.undo() }
    public func vimRedo() { undoManager?.redo() }
    public func visualLineLocation(from: Int, lines: Int) -> Int? {
        // Use UITextView's tokenizer / position(within:offset:inDirection:) to
        // compute visual lines, or return nil to fall back to logical lines.
        return nil
    }
}
```

## Submodes

- `.normal` — keystrokes are commands.
- `.insert` — typing inserts; Esc returns to normal.
- `.command` — `:` command-line buffer (`:q`, `:vim`, `:w`, `:wq`).
- `.replace` — `R` overstrike; chars overwrite next chars until Esc.
- `.visual` / `.visualLine` — char-wise / line-wise selection.
- `.search` — `/` or `?` term entry.

`engine.submode` and `engine.badge` are the two properties to surface in
UI.

## Supported commands (highlights)

**Movement**: `h j k l` (visual lines), `gj gk` (logical lines),
`w b e`, `ge`, `W B E`, `0 ^ $`, `gg G`, `NG`/`Ngg`/`:N<Enter>` (jump
to line N), `{ }`, `%`, `f<x> F<x> t<x> T<x>`, `; ,`, `Ctrl-d Ctrl-u`
(half-page), `Ctrl-f Ctrl-b` (full-page), `H M L` (top / middle /
bottom visible line), `zz zt zb` (scroll cursor line to center / top
/ bottom), arrow keys.

**Insert mode**: `i a I A o O s` enter; `Esc` returns.

**Delete / change / yank**: `x X dd D dw db de d$ d0 d^`, `cc C cw ce
c$`, `yy Y yw ye`, `p P`. With text objects: `iw aw iW aW i" a" i' a'
i\` a\` i( a( i[ a[ i{ a{`. Counts as prefix.

**Replace**: `r<x>` (one char), `Nr<x>`, `R` (overstrike mode).

**Indent**: `>>` / `<<` indent / outdent current line. `>{motion}` /
`<{motion}` over a motion. Visual `>` / `<` on a selection. Indent
width comes from `engine.indentString` (default 2 spaces).

**Case**: `~`, `gU{motion}`, `gu{motion}`, `g~{motion}`, `gUU guu g~~`.
In visual: `U u ~`.

**Search**: `/<term>` `?<term>` `n N`, `*` `#` (word under cursor).

**Marks**: `m<a-z>` set, `'<a-z>` jump to line, `` `<a-z>`` jump exact.

**Repeat**: `.` replays the last text-mutating command, including
characters typed in insert mode after `i/a/I/A/o/O/s/c{motion}/cc/C`.

**Visual**: `v V`, motions extend selection, `d y c ~ U u > <` operate,
`Esc` cancels, `gv` re-enters last selection.

**Undo / redo**: `u`, `Ctrl-r` (delegated to `UndoManager`).

**Command line**: `:q :vim :w :wq`. `:w` calls `onSubmit`; `:q` calls
`onExit`.

## Viewport-aware commands

`Ctrl-d`/`Ctrl-u`/`Ctrl-f`/`Ctrl-b` need a viewport line count.
`zz`/`zt`/`zb` need to scroll a specific line into a vertical
position. `H`/`M`/`L` need to know what line currently sits at a
given viewport slot. All three go through optional `VimTextEditor`
methods with no-op defaults:

```swift
func viewportLineCount() -> Int?
func scrollLineToVerticalPosition(location: Int, alignment: VimLineAlignment)
func visibleLineLocation(at position: VimViewportPosition) -> Int?
```

NSTextView's built-in conformance implements all three via
`enclosingScrollView`. Stubs (and editors without a scroll view) get
the defaults — Ctrl-d/u/f/b fall back to ~10/20 logical lines;
zz/zt/zb become silent no-ops; H/M/L become no-ops.

## Deliberate limitations

- `.` replay does not record `R` overstrike sessions or text typed
  after entering insert via visual `c` (only via i/a/I/A/o/O/s and
  c{motion}/cc/C).
- No named registers (single unnamed register only).
- No macros (`q...q`, `@reg`).
- No sentence motions (`(` `)`).
- No `:%s/foo/bar/g`.
- No automatic visual marks (`'<` / `'>`).

These are deliberate trade-offs to keep the file small. PRs welcome in
the host project.

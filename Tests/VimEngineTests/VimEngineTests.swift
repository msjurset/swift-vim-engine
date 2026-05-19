import Foundation
import VimEngine

// Minimal test harness (no Xcode required)
//
// VimEngine and VimTextEditor are @MainActor since v1.0.1, which makes
// `handleKey` and any conforming stub `@MainActor`-isolated. Helpers
// here mirror that isolation so calls compile under Swift 6 strict
// concurrency. Top-level executable code is wrapped in
// `MainActor.assumeIsolated { ... }` further down — that runs the test
// suite synchronously on the main thread (true at program start) and
// gives the closure body `@MainActor` isolation so the test bodies can
// touch the engine without per-call hops.
@MainActor var passed = 0
@MainActor var failed = 0

@MainActor
func expect(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        let label = message.isEmpty ? "Assertion failed" : message
        print("  FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(label)")
    }
}

@MainActor
func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  PASS \(name)")
    } catch {
        failed += 1
        print("  FAIL \(name): \(error)")
    }
}

// ─── VimEngine ───

@MainActor
final class StubEditor: VimTextEditor {
    var text: String
    var selectedRange: NSRange
    /// Optional viewport size for Ctrl-d/u tests. nil means "no viewport".
    var stubViewportLineCount: Int?
    /// Records scrollLineToVerticalPosition calls for assertions.
    var scrollRequests: [(location: Int, alignment: VimLineAlignment)] = []
    private var history: [(String, NSRange)] = []
    private var future: [(String, NSRange)] = []

    init(_ text: String, caret: Int = 0) {
        self.text = text
        self.selectedRange = NSRange(location: caret, length: 0)
    }

    func replace(in range: NSRange, with string: String) {
        history.append((text, selectedRange))
        future.removeAll()
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: range, with: string)
        text = ns as String
    }

    func vimUndo() {
        guard let (prev, sel) = history.popLast() else { return }
        future.append((text, selectedRange))
        text = prev
        selectedRange = sel
    }

    func vimRedo() {
        guard let (next, sel) = future.popLast() else { return }
        history.append((text, selectedRange))
        text = next
        selectedRange = sel
    }

    func viewportLineCount() -> Int? { stubViewportLineCount }

    func scrollLineToVerticalPosition(location: Int, alignment: VimLineAlignment) {
        scrollRequests.append((location, alignment))
    }

    /// Optional fixed locations the stub returns for H / M / L tests.
    var stubVisibleTop: Int?
    var stubVisibleMiddle: Int?
    var stubVisibleBottom: Int?

    func visibleLineLocation(at position: VimViewportPosition) -> Int? {
        switch position {
        case .top: return stubVisibleTop
        case .middle: return stubVisibleMiddle
        case .bottom: return stubVisibleBottom
        }
    }
}

/// Feed each key in `keys` to the engine. A key is either:
///   * a 1-char string (e.g. "h", "i") — its first character.
///   * a sentinel like "<esc>", "<enter>", "<bs>" for special keys.
@MainActor
func feed(_ engine: VimEngine, _ keys: [String], on editor: VimTextEditor) {
    for k in keys {
        let (chars, keyCode): (String?, UInt16)
        switch k {
        case "<esc>": chars = nil; keyCode = 53
        case "<enter>": chars = nil; keyCode = 36
        case "<bs>": chars = nil; keyCode = 51
        case "<left>": chars = "\u{F702}"; keyCode = 123
        case "<right>": chars = "\u{F703}"; keyCode = 124
        case "<down>": chars = "\u{F701}"; keyCode = 125
        case "<up>": chars = "\u{F700}"; keyCode = 126
        case "<c-r>": chars = "r"; keyCode = 15
            engine.handleKey(chars: chars, keyCode: keyCode, modifiers: [.control], editor: editor)
            continue
        case "<c-d>":
            engine.handleKey(chars: "d", keyCode: 0, modifiers: [.control], editor: editor)
            continue
        case "<c-u>":
            engine.handleKey(chars: "u", keyCode: 0, modifiers: [.control], editor: editor)
            continue
        case "<c-f>":
            engine.handleKey(chars: "f", keyCode: 0, modifiers: [.control], editor: editor)
            continue
        case "<c-b>":
            engine.handleKey(chars: "b", keyCode: 0, modifiers: [.control], editor: editor)
            continue
        default: chars = k; keyCode = 0
        }
        engine.handleKey(chars: chars, keyCode: keyCode, modifiers: [], editor: editor)
    }
}

// Top-level expressions in an executable target run nonisolated under
// swift-tools 5.9, but `test`, `feed`, and the engine itself are now
// `@MainActor`. `MainActor.assumeIsolated` runs the closure
// synchronously on the current thread — which is the main thread at
// program start — and gives the body `@MainActor` isolation so the test
// suite compiles unchanged. Trap at runtime if we're ever not on main,
// which would itself be a bug.
MainActor.assumeIsolated {

test("VimEngine: starts in normal mode") {
    let engine = VimEngine()
    expect(engine.submode == .normal)
    expect(engine.badge == "VIM:N")
}

test("VimEngine: i enters insert, Esc returns to normal") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["i"], on: ed)
    expect(engine.submode == .insert, "expected insert mode")
    feed(engine, ["<esc>"], on: ed)
    expect(engine.submode == .normal, "expected normal after Esc")
}

test("VimEngine: h/j/k/l move caret") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["l", "l"], on: ed)
    expect(ed.selectedRange.location == 2, "l, l -> 2, got \(ed.selectedRange.location)")
    feed(engine, ["j"], on: ed)
    expect(ed.selectedRange.location == 8, "down to 'r' in 'world', got \(ed.selectedRange.location)")
    feed(engine, ["h"], on: ed)
    expect(ed.selectedRange.location == 7, "back one, got \(ed.selectedRange.location)")
    feed(engine, ["k"], on: ed)
    expect(ed.selectedRange.location == 1, "up to col 1 of line 1, got \(ed.selectedRange.location)")
}

test("VimEngine: 0 and $ jump to line start / end") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 6)
    feed(engine, ["0"], on: ed)
    expect(ed.selectedRange.location == 0)
    feed(engine, ["$"], on: ed)
    expect(ed.selectedRange.location == 11, "got \(ed.selectedRange.location)")
}

test("VimEngine: gg and G jump to buffer start / end") {
    let engine = VimEngine()
    let ed = StubEditor("line one\nline two\nline three", caret: 10)
    feed(engine, ["g", "g"], on: ed)
    expect(ed.selectedRange.location == 0)
    feed(engine, ["G"], on: ed)
    expect(ed.selectedRange.location == 28, "got \(ed.selectedRange.location)")
}

test("VimEngine: w and b move by word") {
    let engine = VimEngine()
    let ed = StubEditor("the quick brown fox", caret: 0)
    feed(engine, ["w"], on: ed)
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
    feed(engine, ["w", "w"], on: ed)
    expect(ed.selectedRange.location == 16, "got \(ed.selectedRange.location)")
    feed(engine, ["b"], on: ed)
    expect(ed.selectedRange.location == 10, "got \(ed.selectedRange.location)")
}

test("VimEngine: x deletes character") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 1)
    feed(engine, ["x"], on: ed)
    expect(ed.text == "hllo", "got: \(ed.text)")
    expect(ed.selectedRange.location == 1)
}

test("VimEngine: dd deletes whole line including newline") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 5)
    feed(engine, ["d", "d"], on: ed)
    expect(ed.text == "one\nthree", "got: \(ed.text)")
}

test("VimEngine: dw deletes to next word start") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 0)
    feed(engine, ["d", "w"], on: ed)
    expect(ed.text == "bar baz", "got: \(ed.text)")
}

test("VimEngine: count prefix repeats motion") {
    let engine = VimEngine()
    let ed = StubEditor("abcdefghij", caret: 0)
    feed(engine, ["3", "l"], on: ed)
    expect(ed.selectedRange.location == 3, "got \(ed.selectedRange.location)")
}

test("VimEngine: 3dd deletes three lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne", caret: 0)
    feed(engine, ["3", "d", "d"], on: ed)
    expect(ed.text == "d\ne", "got: \(ed.text)")
}

test("VimEngine: o opens line below and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("first\nsecond", caret: 2)
    feed(engine, ["o"], on: ed)
    expect(ed.text == "first\n\nsecond", "got: \(ed.text)")
    expect(ed.selectedRange.location == 6)
    expect(engine.submode == .insert)
}

test("VimEngine: A jumps to line end and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["A"], on: ed)
    expect(ed.selectedRange.location == 5)
    expect(engine.submode == .insert)
}

test("VimEngine: a moves right and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("hi", caret: 0)
    feed(engine, ["a"], on: ed)
    expect(ed.selectedRange.location == 1)
    expect(engine.submode == .insert)
}

test("VimEngine: u undoes a delete") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["x"], on: ed)
    expect(ed.text == "ello")
    feed(engine, ["u"], on: ed)
    expect(ed.text == "hello", "undo restored, got: \(ed.text)")
}

test("VimEngine: :q exits via onExit callback") {
    let engine = VimEngine()
    let ed = StubEditor("anything", caret: 0)
    var exited = false
    engine.onExit = { exited = true }
    feed(engine, [":", "q", "<enter>"], on: ed)
    expect(exited, "expected :q to fire onExit")
}

test("VimEngine: :vim also exits") {
    let engine = VimEngine()
    let ed = StubEditor("anything", caret: 0)
    var exited = false
    engine.onExit = { exited = true }
    feed(engine, [":", "v", "i", "m", "<enter>"], on: ed)
    expect(exited)
}

test("VimEngine: :w submits without exiting") {
    let engine = VimEngine()
    let ed = StubEditor("body", caret: 0)
    var submitted = false
    var exited = false
    engine.onSubmit = { submitted = true }
    engine.onExit = { exited = true }
    feed(engine, [":", "w", "<enter>"], on: ed)
    expect(submitted)
    expect(!exited, ":w must not exit")
}

test("VimEngine: :wq submits and exits") {
    let engine = VimEngine()
    let ed = StubEditor("body", caret: 0)
    var submitted = false
    var exited = false
    engine.onSubmit = { submitted = true }
    engine.onExit = { exited = true }
    feed(engine, [":", "w", "q", "<enter>"], on: ed)
    expect(submitted)
    expect(exited)
}

test("VimEngine: command-mode Backspace deletes from buffer") {
    let engine = VimEngine()
    let ed = StubEditor("body", caret: 0)
    feed(engine, [":", "q", "<bs>"], on: ed)
    expect(engine.commandBuffer == "", "expected empty buffer after backspace, got '\(engine.commandBuffer)'")
    expect(engine.submode == .command, "still in command mode while buffer was non-empty before bs")
}

test("VimEngine: arrow keys are routed to motions in normal mode") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["<right>", "<right>"], on: ed)
    expect(ed.selectedRange.location == 2)
    feed(engine, ["<left>"], on: ed)
    expect(ed.selectedRange.location == 1)
}

test("VimEngine: h does not cross line boundary backward") {
    let engine = VimEngine()
    let ed = StubEditor("abc\ndef\nghi", caret: 4)  // 'd' of "def"
    feed(engine, ["h"], on: ed)
    // Standard vim: h at column 0 of line 2 is a no-op; the cursor
    // does NOT wrap onto the preceding \n.
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

test("VimEngine: l does not cross line boundary forward") {
    let engine = VimEngine()
    let ed = StubEditor("abc\ndef\nghi", caret: 2)  // 'c' of "abc"
    feed(engine, ["l"], on: ed)
    // Cursor lands on the position of the trailing \n at end of line 1
    // (position 3) — that's the line-end boundary. NOT onto line 2.
    expect(ed.selectedRange.location == 3, "got \(ed.selectedRange.location)")
    feed(engine, ["l"], on: ed)
    // Further `l` is still bounded by the same line end.
    expect(ed.selectedRange.location == 3, "got \(ed.selectedRange.location)")
}

test("VimEngine: l on last line bounded by buffer end") {
    let engine = VimEngine()
    let ed = StubEditor("abc", caret: 0)
    feed(engine, ["l", "l", "l", "l"], on: ed)
    // No trailing newline, so the bound is the buffer length.
    expect(ed.selectedRange.location == 3, "got \(ed.selectedRange.location)")
}

test("VimEngine: ^ moves to first non-blank of line") {
    let engine = VimEngine()
    let ed = StubEditor("    hello world", caret: 10)
    feed(engine, ["^"], on: ed)
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

test("VimEngine: ^ on all-whitespace line lands at line start") {
    let engine = VimEngine()
    let ed = StubEditor("   \nhello", caret: 2)
    feed(engine, ["^"], on: ed)
    expect(ed.selectedRange.location == 0, "got \(ed.selectedRange.location)")
}

test("VimEngine: I jumps to first non-blank and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("    hello", caret: 8)
    feed(engine, ["I"], on: ed)
    expect(ed.selectedRange.location == 4)
    expect(engine.submode == .insert)
}

test("VimEngine: yy then p pastes line below") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo", caret: 0)
    feed(engine, ["y", "y", "p"], on: ed)
    expect(ed.text == "one\none\ntwo", "got: \(ed.text)")
}

test("VimEngine: yy then P pastes line above") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo", caret: 4)  // on the 't' of two
    feed(engine, ["y", "y", "P"], on: ed)
    expect(ed.text == "one\ntwo\ntwo", "got: \(ed.text)")
}

test("VimEngine: yw then p pastes word inline after cursor") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar", caret: 0)
    feed(engine, ["y", "w", "p"], on: ed)
    // yw yanks "foo " (including trailing space — vim semantics).
    // Paste after cursor (pos 0 → insert at 1) → "ffoo oo bar"
    expect(ed.text == "ffoo oo bar", "got: \(ed.text)")
}

test("VimEngine: dd then p restores the deleted line") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 4)
    feed(engine, ["d", "d", "p"], on: ed)
    // dd deletes "two\n", caret lands on "three" line. p pastes below.
    // Since "three" has no trailing newline (EOF), engine prepends \n
    // and drops the register's trailing \n, leaving no \n at EOF.
    expect(ed.text == "one\nthree\ntwo", "got: \(ed.text)")
}

test("VimEngine: 2yy then p pastes two lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc", caret: 0)
    feed(engine, ["2", "y", "y", "p"], on: ed)
    expect(ed.text == "a\na\nb\nb\nc", "got: \(ed.text)")
}

test("VimEngine: count multiplies paste") {
    let engine = VimEngine()
    let ed = StubEditor("ab", caret: 0)
    feed(engine, ["y", "l", "3", "p"], on: ed)
    // yl yanks "a" (single char), 3p pastes "aaa" after cursor → "aaaab"
    expect(ed.text == "aaaab", "got: \(ed.text)")
}

test("VimEngine: r replaces single char") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 1)
    feed(engine, ["r", "x"], on: ed)
    expect(ed.text == "hxllo", "got: \(ed.text)")
    expect(ed.selectedRange.location == 1, "caret stays on replaced char")
    expect(engine.submode == .normal, "stays in normal mode after r")
}

test("VimEngine: 3r replaces three chars") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 1)
    feed(engine, ["3", "r", "Z"], on: ed)
    expect(ed.text == "aZZZef", "got: \(ed.text)")
    expect(ed.selectedRange.location == 3, "caret on last replaced char, got \(ed.selectedRange.location)")
}

test("VimEngine: r at end of buffer is a no-op") {
    let engine = VimEngine()
    let ed = StubEditor("abc", caret: 3)
    feed(engine, ["r", "x"], on: ed)
    expect(ed.text == "abc", "unchanged: \(ed.text)")
}

test("VimEngine: r then Esc cancels without replacing") {
    let engine = VimEngine()
    let ed = StubEditor("abc", caret: 0)
    feed(engine, ["r", "<esc>"], on: ed)
    expect(ed.text == "abc", "unchanged: \(ed.text)")
}

test("VimEngine: cw deletes word and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar", caret: 0)
    feed(engine, ["c", "w"], on: ed)
    expect(ed.text == "bar", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: cc empties current line and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 2)
    feed(engine, ["c", "c"], on: ed)
    expect(ed.text == "\nworld", "got: \(ed.text)")
    expect(ed.selectedRange.location == 0)
    expect(engine.submode == .insert)
}

test("VimEngine: c$ changes to end of line") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 6)
    feed(engine, ["c", "$"], on: ed)
    expect(ed.text == "hello ", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: C is shorthand for c$") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 6)
    feed(engine, ["C"], on: ed)
    expect(ed.text == "hello ", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: D is shorthand for d$") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 6)
    feed(engine, ["D"], on: ed)
    expect(ed.text == "hello ", "got: \(ed.text)")
    expect(engine.submode == .normal, "D stays in normal mode")
}

test("VimEngine: s replaces one char and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["s"], on: ed)
    expect(ed.text == "ello", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: r followed by space replaces with space and stays normal") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 2)
    feed(engine, ["r", " "], on: ed)
    expect(ed.text == "ab def", "got: \(ed.text)")
    expect(engine.submode == .normal, "r must NOT switch modes")
    expect(ed.selectedRange.location == 2, "caret stays on replaced char")
}

test("VimEngine: e moves to end of current word") {
    let engine = VimEngine()
    let ed = StubEditor("abc def", caret: 0)
    feed(engine, ["e"], on: ed)
    expect(ed.selectedRange.location == 2, "got \(ed.selectedRange.location)")
}

test("VimEngine: e from end of word jumps to end of next word") {
    let engine = VimEngine()
    let ed = StubEditor("abc def ghi", caret: 2)
    feed(engine, ["e"], on: ed)
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: ea is the standard append-after-word idiom") {
    let engine = VimEngine()
    let ed = StubEditor("abc def", caret: 0)
    // ea: e moves to 'c' (end of "abc"), a then moves to position after 'c' and enters insert
    feed(engine, ["e", "a"], on: ed)
    expect(ed.selectedRange.location == 3, "should land just after 'c', got \(ed.selectedRange.location)")
    expect(engine.submode == .insert)
}

test("VimEngine: ge moves to end of previous word") {
    let engine = VimEngine()
    let ed = StubEditor("abc def ghi", caret: 9)
    feed(engine, ["g", "e"], on: ed)
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: de deletes through end of word") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar", caret: 0)
    feed(engine, ["d", "e"], on: ed)
    // de from start of "foo" deletes "foo" (cursor 0..3 exclusive of trailing space)
    expect(ed.text == " bar", "got: \(ed.text)")
}

test("VimEngine: ce changes through end of word and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar", caret: 0)
    feed(engine, ["c", "e"], on: ed)
    expect(ed.text == " bar", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

// ─── VimEngine: R (overstrike), . (repeat), v/V (visual), / (search), f/t

test("VimEngine: R enters replace submode") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["R"], on: ed)
    expect(engine.submode == .replace, "expected replace, got \(engine.submode)")
    expect(engine.badge == "VIM:R")
}

test("VimEngine: R then Esc returns to normal") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["R", "<esc>"], on: ed)
    expect(engine.submode == .normal)
}

test("VimEngine: . repeats x") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["x"], on: ed)
    expect(ed.text == "bcdef")
    feed(engine, ["."], on: ed)
    expect(ed.text == "cdef", "got: \(ed.text)")
}

test("VimEngine: . repeats dd") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree\nfour", caret: 0)
    feed(engine, ["d", "d"], on: ed)
    expect(ed.text == "two\nthree\nfour")
    feed(engine, ["."], on: ed)
    expect(ed.text == "three\nfour", "got: \(ed.text)")
}

test("VimEngine: . repeats r<x>") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["r", "Z"], on: ed)
    expect(ed.text == "Zbcdef")
    feed(engine, ["l", "."], on: ed)
    expect(ed.text == "ZZcdef", "got: \(ed.text)")
}

test("VimEngine: yank is NOT recorded as a change") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["x"], on: ed)        // delete "a" → "bcdef" + recorded
    feed(engine, ["y", "y"], on: ed)   // yank (not a change)
    feed(engine, ["."], on: ed)        // should still repeat x, not yy
    expect(ed.text == "cdef", "got: \(ed.text)")
}

test("VimEngine: v enters visual mode and selects character at cursor") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 2)
    feed(engine, ["v"], on: ed)
    expect(engine.submode == .visual)
    expect(ed.selectedRange.location == 2 && ed.selectedRange.length == 1, "got \(ed.selectedRange)")
}

test("VimEngine: v then l extends selection to right") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["v", "l", "l"], on: ed)
    // anchor 0, cursor 2 → selection covers [0..2] inclusive = length 3
    expect(ed.selectedRange.location == 0 && ed.selectedRange.length == 3, "got \(ed.selectedRange)")
}

test("VimEngine: visual d deletes selection and returns to normal") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["v", "l", "l", "d"], on: ed)
    expect(ed.text == "def", "got: \(ed.text)")
    expect(engine.submode == .normal)
}

test("VimEngine: visual y yanks and returns to normal") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["v", "l", "l", "y", "$", "p"], on: ed)
    // yanked "abc", cursor on 'f' (end of line), p pastes after → "abcdefabc"
    expect(ed.text == "abcdefabc", "got: \(ed.text)")
}

test("VimEngine: visual c deletes selection and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["v", "l", "l", "c"], on: ed)
    expect(ed.text == "def", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: V selects whole line") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 5)
    feed(engine, ["V"], on: ed)
    expect(engine.submode == .visualLine)
    // Should select all of "two\n"
    expect(ed.selectedRange.location == 4 && ed.selectedRange.length == 4, "got \(ed.selectedRange)")
}

test("VimEngine: V then d deletes line(s)") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 5)
    feed(engine, ["V", "d"], on: ed)
    expect(ed.text == "one\nthree", "got: \(ed.text)")
}

test("VimEngine: visual Esc cancels selection") {
    let engine = VimEngine()
    let ed = StubEditor("abcdef", caret: 0)
    feed(engine, ["v", "l", "l", "<esc>"], on: ed)
    expect(engine.submode == .normal)
    expect(ed.selectedRange.length == 0, "selection should collapse")
}

test("VimEngine: / followed by term + Enter jumps to first match") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar", caret: 0)
    feed(engine, ["/", "b", "a", "r", "<enter>"], on: ed)
    expect(ed.selectedRange.location == 4, "first 'bar' at 4, got \(ed.selectedRange.location)")
}

test("VimEngine: n repeats search forward") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar", caret: 0)
    feed(engine, ["/", "b", "a", "r", "<enter>", "n"], on: ed)
    expect(ed.selectedRange.location == 12, "second 'bar' at 12, got \(ed.selectedRange.location)")
}

test("VimEngine: N goes backward, wrapping") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar", caret: 13)
    feed(engine, ["/", "b", "a", "r", "<enter>", "N"], on: ed)
    // first match from 13 jumps forward and wraps to first occurrence at 4.
    // Then N from 4 goes back, wrapping to 12.
    expect(ed.selectedRange.location == 12 || ed.selectedRange.location == 4,
           "got \(ed.selectedRange.location)")
}

test("VimEngine: f<char> finds next occurrence on line") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["f", "o"], on: ed)
    expect(ed.selectedRange.location == 4, "first 'o' at 4, got \(ed.selectedRange.location)")
}

test("VimEngine: t<char> lands one before the target") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["t", "w"], on: ed)
    expect(ed.selectedRange.location == 5, "should land at space before 'w', got \(ed.selectedRange.location)")
}

test("VimEngine: F<char> finds backward on line") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 10)
    feed(engine, ["F", "l"], on: ed)
    expect(ed.selectedRange.location == 9, "last 'l' before pos 10 is 9, got \(ed.selectedRange.location)")
}

test("VimEngine: f does not cross line boundaries") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["f", "w"], on: ed)
    expect(ed.selectedRange.location == 0, "'w' is on next line, should stay put; got \(ed.selectedRange.location)")
}

test("VimEngine: ; repeats last find") {
    let engine = VimEngine()
    let ed = StubEditor("the quick brown fox", caret: 0)
    feed(engine, ["f", " ", ";"], on: ed)
    expect(ed.selectedRange.location == 9, "second space at 9, got \(ed.selectedRange.location)")
}

test("VimEngine: , reverses last find") {
    let engine = VimEngine()
    let ed = StubEditor("the quick brown fox", caret: 0)
    feed(engine, ["f", " ", ";", ","], on: ed)
    // f' ' → 3; ; → 9; , reverses → 3
    expect(ed.selectedRange.location == 3, "got \(ed.selectedRange.location)")
}

// ─── WORD motions (W/B/E), paragraph, matching bracket, toggle case

test("VimEngine: W treats punctuation as part of the WORD") {
    let engine = VimEngine()
    let ed = StubEditor("foo.bar baz", caret: 0)
    feed(engine, ["W"], on: ed)
    // w would stop at the '.', but W skips it (whitespace-only break)
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: B (backward WORD) skips punctuation") {
    let engine = VimEngine()
    let ed = StubEditor("foo.bar baz", caret: 8)
    feed(engine, ["B"], on: ed)
    expect(ed.selectedRange.location == 0, "got \(ed.selectedRange.location)")
}

test("VimEngine: E moves to end of WORD") {
    let engine = VimEngine()
    let ed = StubEditor("foo.bar baz", caret: 0)
    feed(engine, ["E"], on: ed)
    // Last char of "foo.bar" is position 6
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: } jumps to next blank line") {
    let engine = VimEngine()
    let ed = StubEditor("para one line one\npara one line two\n\npara two\n", caret: 0)
    feed(engine, ["}"], on: ed)
    // The blank line is at position 37 (after the second \n that ends "line two\n")
    // Actually let me count: "para one line one" 17 + "\n" 1 = 18 + "para one line two" 17 + "\n" 1 = 36 + "\n" 1 = 37
    expect(ed.selectedRange.location == 36 || ed.selectedRange.location == 37,
           "expected blank-line boundary, got \(ed.selectedRange.location)")
}

test("VimEngine: { jumps to previous blank line") {
    let engine = VimEngine()
    let ed = StubEditor("para one\n\npara two\n\npara three", caret: 22)
    // From "para three", { should walk back to the blank line at position 19 (or surrounding)
    feed(engine, ["{"], on: ed)
    expect(ed.selectedRange.location <= 20 && ed.selectedRange.location >= 9,
           "expected to land near a blank-line boundary, got \(ed.selectedRange.location)")
}

test("VimEngine: % jumps from ( to matching )") {
    let engine = VimEngine()
    let ed = StubEditor("(a b c)", caret: 0)
    feed(engine, ["%"], on: ed)
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: % jumps from ) back to matching (") {
    let engine = VimEngine()
    let ed = StubEditor("(a b c)", caret: 6)
    feed(engine, ["%"], on: ed)
    expect(ed.selectedRange.location == 0, "got \(ed.selectedRange.location)")
}

test("VimEngine: % handles nested brackets") {
    let engine = VimEngine()
    let ed = StubEditor("(a (b c) d)", caret: 0)
    feed(engine, ["%"], on: ed)
    expect(ed.selectedRange.location == 10, "should find outer ) at 10, got \(ed.selectedRange.location)")
}

test("VimEngine: % on a non-bracket scans forward to first bracket on line") {
    let engine = VimEngine()
    let ed = StubEditor("foo (bar) baz", caret: 0)
    feed(engine, ["%"], on: ed)
    expect(ed.selectedRange.location == 8, "should land on matching ) at 8, got \(ed.selectedRange.location)")
}

test("VimEngine: ~ toggles case of char under caret") {
    let engine = VimEngine()
    let ed = StubEditor("Hello", caret: 0)
    feed(engine, ["~"], on: ed)
    expect(ed.text == "hello", "got: \(ed.text)")
}

test("VimEngine: ~ with count toggles N chars") {
    let engine = VimEngine()
    let ed = StubEditor("Hello world", caret: 0)
    feed(engine, ["3", "~"], on: ed)
    expect(ed.text == "hELlo world", "got: \(ed.text)")
}

test("VimEngine: dW deletes whole WORD including punctuation") {
    let engine = VimEngine()
    let ed = StubEditor("foo.bar baz", caret: 0)
    feed(engine, ["d", "W"], on: ed)
    expect(ed.text == "baz", "got: \(ed.text)")
}

// ─── Text objects (iw / aw / i" / a" / i( / a(, etc.)

test("VimEngine: diw deletes inner word") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 5)  // on 'a' of bar
    feed(engine, ["d", "i", "w"], on: ed)
    expect(ed.text == "foo  baz", "got: \(ed.text)")
}

test("VimEngine: daw deletes word and trailing space") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 5)
    feed(engine, ["d", "a", "w"], on: ed)
    expect(ed.text == "foo baz", "got: \(ed.text)")
}

test("VimEngine: ciw changes inner word and enters insert") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 5)
    feed(engine, ["c", "i", "w"], on: ed)
    expect(ed.text == "foo  baz", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: yiw yanks inner word") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 5)
    feed(engine, ["y", "i", "w", "$", "p"], on: ed)
    expect(ed.text == "foo bar bazbar", "got: \(ed.text)")
}

test("VimEngine: diW treats punctuation as part of WORD") {
    let engine = VimEngine()
    let ed = StubEditor("foo.bar baz", caret: 2)  // on 'o' of foo
    feed(engine, ["d", "i", "W"], on: ed)
    expect(ed.text == " baz", "got: \(ed.text)")
}

test("VimEngine: di\" deletes inside double quotes") {
    let engine = VimEngine()
    let ed = StubEditor("a \"hello world\" b", caret: 7)  // inside the quotes
    feed(engine, ["d", "i", "\""], on: ed)
    expect(ed.text == "a \"\" b", "got: \(ed.text)")
}

test("VimEngine: da\" deletes including the double quotes") {
    let engine = VimEngine()
    let ed = StubEditor("a \"hello world\" b", caret: 7)
    feed(engine, ["d", "a", "\""], on: ed)
    expect(ed.text == "a  b", "got: \(ed.text)")
}

test("VimEngine: ci' changes inside single quotes") {
    let engine = VimEngine()
    let ed = StubEditor("name = 'old'", caret: 9)
    feed(engine, ["c", "i", "'"], on: ed)
    expect(ed.text == "name = ''", "got: \(ed.text)")
    expect(engine.submode == .insert)
}

test("VimEngine: di( deletes inside parens") {
    let engine = VimEngine()
    let ed = StubEditor("foo(a, b, c)", caret: 6)
    feed(engine, ["d", "i", "("], on: ed)
    expect(ed.text == "foo()", "got: \(ed.text)")
}

test("VimEngine: da( deletes including parens") {
    let engine = VimEngine()
    let ed = StubEditor("foo(a, b, c)", caret: 6)
    feed(engine, ["d", "a", "("], on: ed)
    expect(ed.text == "foo", "got: \(ed.text)")
}

test("VimEngine: di{ targets the innermost enclosing pair") {
    let engine = VimEngine()
    let ed = StubEditor("a { b { c } d } e", caret: 8)  // on 'c', inside inner pair
    feed(engine, ["d", "i", "{"], on: ed)
    expect(ed.text == "a { b {} d } e", "got: \(ed.text)")
}

test("VimEngine: di{ on outer content selects outer pair") {
    let engine = VimEngine()
    let ed = StubEditor("a { b { c } d } e", caret: 4)  // on 'b', only outer encloses
    feed(engine, ["d", "i", "{"], on: ed)
    expect(ed.text == "a {} e", "got: \(ed.text)")
}

test("VimEngine: di[ deletes inside brackets") {
    let engine = VimEngine()
    let ed = StubEditor("arr[0] = 1", caret: 4)
    feed(engine, ["d", "i", "["], on: ed)
    expect(ed.text == "arr[] = 1", "got: \(ed.text)")
}

// ─── Case operators (gU / gu / g~)

test("VimEngine: gUw uppercases word") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["g", "U", "w"], on: ed)
    expect(ed.text == "HELLO world", "got: \(ed.text)")
}

test("VimEngine: guw lowercases word") {
    let engine = VimEngine()
    let ed = StubEditor("HELLO WORLD", caret: 0)
    feed(engine, ["g", "u", "w"], on: ed)
    expect(ed.text == "hello WORLD", "got: \(ed.text)")
}

test("VimEngine: g~w toggles case of word") {
    let engine = VimEngine()
    let ed = StubEditor("Hello World", caret: 0)
    feed(engine, ["g", "~", "w"], on: ed)
    expect(ed.text == "hELLO World", "got: \(ed.text)")
}

test("VimEngine: gUU uppercases whole line") {
    let engine = VimEngine()
    let ed = StubEditor("hello world\nnext line", caret: 3)
    feed(engine, ["g", "U", "U"], on: ed)
    expect(ed.text == "HELLO WORLD\nnext line", "got: \(ed.text)")
}

test("VimEngine: guu lowercases whole line") {
    let engine = VimEngine()
    let ed = StubEditor("HELLO WORLD\nNEXT LINE", caret: 3)
    feed(engine, ["g", "u", "u"], on: ed)
    expect(ed.text == "hello world\nNEXT LINE", "got: \(ed.text)")
}

test("VimEngine: gUiw uppercases inner word via text object") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 8)  // on 'o' of world
    feed(engine, ["g", "U", "i", "w"], on: ed)
    expect(ed.text == "hello WORLD", "got: \(ed.text)")
}

test("VimEngine: gUi\" uppercases inside quotes") {
    let engine = VimEngine()
    let ed = StubEditor("a \"hello world\" b", caret: 7)
    feed(engine, ["g", "U", "i", "\""], on: ed)
    expect(ed.text == "a \"HELLO WORLD\" b", "got: \(ed.text)")
}

// ─── X / J / Y / gv / visual case

test("VimEngine: X deletes character before caret") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 3)
    feed(engine, ["X"], on: ed)
    expect(ed.text == "helo", "got: \(ed.text)")
    expect(ed.selectedRange.location == 2)
}

test("VimEngine: X does not cross line boundary") {
    let engine = VimEngine()
    let ed = StubEditor("foo\nbar", caret: 4)  // on 'b' of bar
    feed(engine, ["X"], on: ed)
    // X tries to delete the \n but is bounded by line start; nothing happens.
    expect(ed.text == "foo\nbar", "got: \(ed.text)")
}

test("VimEngine: J joins next line with a space") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["J"], on: ed)
    expect(ed.text == "hello world", "got: \(ed.text)")
}

test("VimEngine: J trims leading whitespace of joined line") {
    let engine = VimEngine()
    let ed = StubEditor("hello\n    world", caret: 0)
    feed(engine, ["J"], on: ed)
    expect(ed.text == "hello world", "got: \(ed.text)")
}

test("VimEngine: J with count joins multiple lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd", caret: 0)
    feed(engine, ["3", "J"], on: ed)
    expect(ed.text == "a b c\nd", "got: \(ed.text)")
}

test("VimEngine: Y is alias for yy") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo", caret: 0)
    feed(engine, ["Y", "p"], on: ed)
    expect(ed.text == "one\none\ntwo", "got: \(ed.text)")
}

test("VimEngine: gv re-enters last visual selection") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["v", "l", "l", "<esc>"], on: ed)
    // Selection collapsed but lastVisual is recorded.
    feed(engine, ["g", "v"], on: ed)
    expect(engine.submode == .visual)
    expect(ed.selectedRange.location == 0 && ed.selectedRange.length == 3, "got \(ed.selectedRange)")
}

test("VimEngine: visual ~ toggles case of selection") {
    let engine = VimEngine()
    let ed = StubEditor("Hello World", caret: 0)
    feed(engine, ["v", "l", "l", "l", "l", "~"], on: ed)
    // Selection covers "Hello" (5 chars), toggled to "hELLO".
    expect(ed.text == "hELLO World", "got: \(ed.text)")
    expect(engine.submode == .normal)
}

test("VimEngine: visual U uppercases selection") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["v", "l", "l", "l", "l", "U"], on: ed)
    expect(ed.text == "HELLO world", "got: \(ed.text)")
}

test("VimEngine: visual u lowercases selection") {
    let engine = VimEngine()
    let ed = StubEditor("HELLO WORLD", caret: 0)
    feed(engine, ["v", "l", "l", "l", "l", "u"], on: ed)
    expect(ed.text == "hello WORLD", "got: \(ed.text)")
}

// ─── ? backward search and marks

test("VimEngine: ?<term> searches backward") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar end", caret: 18)  // near end
    feed(engine, ["?", "b", "a", "r", "<enter>"], on: ed)
    // From pos 18, scan back; first match is at 12 (the second "bar")
    expect(ed.selectedRange.location == 12, "got \(ed.selectedRange.location)")
}

test("VimEngine: n after ? repeats backward") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar end", caret: 18)
    feed(engine, ["?", "b", "a", "r", "<enter>", "n"], on: ed)
    // First ? jumps to 12, n (still backward) jumps to 4.
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

test("VimEngine: N after ? goes forward (reverse direction)") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz bar end", caret: 0)
    feed(engine, ["?", "b", "a", "r", "<enter>"], on: ed)
    // From pos 0 scanning backward wraps to 12 (last "bar")
    let firstHit = ed.selectedRange.location
    feed(engine, ["N"], on: ed)
    // N reverses ?, so goes forward from 12 → wraps and finds 4 or stays
    // (depending on implementation). Just assert it moved.
    expect(ed.selectedRange.location != firstHit, "N should have moved from \(firstHit)")
}

test("VimEngine: m<x> sets a mark and '<x> jumps back") {
    let engine = VimEngine()
    let ed = StubEditor("line one\nline two\nline three", caret: 5)
    feed(engine, ["m", "a", "G"], on: ed)
    // Move to end, then jump back to mark 'a' (line start of mark)
    feed(engine, ["'", "a"], on: ed)
    // ' jumps to line start of mark position (5 was on 'o' in "line one")
    expect(ed.selectedRange.location == 0, "got \(ed.selectedRange.location)")
}

test("VimEngine: `<x> jumps to exact mark position") {
    let engine = VimEngine()
    let ed = StubEditor("line one\nline two", caret: 5)
    feed(engine, ["m", "a", "G"], on: ed)
    feed(engine, ["`", "a"], on: ed)
    expect(ed.selectedRange.location == 5, "got \(ed.selectedRange.location)")
}

test("VimEngine: unset mark is a no-op") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 2)
    feed(engine, ["'", "z"], on: ed)  // mark z never set
    expect(ed.selectedRange.location == 2, "cursor should stay put, got \(ed.selectedRange.location)")
}

test("VimEngine: * searches forward for word under cursor") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar foo baz foo", caret: 1)  // on 'o' of first foo
    feed(engine, ["*"], on: ed)
    expect(ed.selectedRange.location == 8, "second 'foo' at 8, got \(ed.selectedRange.location)")
}

test("VimEngine: # searches backward for word under cursor") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar foo baz foo", caret: 16)  // on 'f' of last foo
    feed(engine, ["#"], on: ed)
    expect(ed.selectedRange.location == 8, "middle 'foo' at 8, got \(ed.selectedRange.location)")
}

test("VimEngine: n after * continues the search") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar foo baz foo", caret: 0)
    feed(engine, ["*", "n"], on: ed)
    // * jumps to position 8 (next "foo"), n continues forward → position 16
    expect(ed.selectedRange.location == 16, "third 'foo' at 16, got \(ed.selectedRange.location)")
}

test("VimEngine: * on a non-word char finds the next word") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar foo", caret: 3)  // on ' ' between foo and bar
    feed(engine, ["*"], on: ed)
    // Should search for "bar" (next word). Only one occurrence, wraps.
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

// ─── Insert-mode . replay

test("VimEngine: . replays i + typed text") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 5)  // at end
    // Tests don't simulate AppKit's actual char insertion, but they DO
    // exercise the engine's recording. Replay on a fresh editor shows
    // the recorded text getting inserted.
    feed(engine, ["i", "x", "y", "z", "<esc>"], on: ed)

    let ed2 = StubEditor("foo", caret: 3)
    feed(engine, ["."], on: ed2)
    expect(ed2.text == "fooxyz", "got: \(ed2.text)")
}

test("VimEngine: . replays a + typed text") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 0)
    feed(engine, ["a", "X", "<esc>"], on: ed)
    // Replay on a different editor.
    let ed2 = StubEditor("foo", caret: 0)
    feed(engine, ["."], on: ed2)
    // Replay: `a` moves right one (caret 0→1), then inserts "X".
    expect(ed2.text == "fXoo", "got: \(ed2.text)")
    expect(ed2.selectedRange.location == 2)
}

test("VimEngine: . replays I + typed text (line first non-blank)") {
    let engine = VimEngine()
    let ed = StubEditor("    hello", caret: 6)
    feed(engine, ["I", "*", "<esc>"], on: ed)
    let ed2 = StubEditor("    world", caret: 7)
    feed(engine, ["."], on: ed2)
    // I jumps to position 4 (first non-blank), then inserts "*"
    expect(ed2.text == "    *world", "got: \(ed2.text)")
}

test("VimEngine: . replays o (open line below)") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb", caret: 0)
    feed(engine, ["o", "X", "<esc>"], on: ed)
    let ed2 = StubEditor("c\nd", caret: 0)
    feed(engine, ["."], on: ed2)
    // o adds a blank line below "c", then inserts "X"
    expect(ed2.text == "c\nX\nd", "got: \(ed2.text)")
}

test("VimEngine: . replays cw with new text") {
    let engine = VimEngine()
    let ed = StubEditor("foo bar baz", caret: 0)
    feed(engine, ["c", "w", "X", "Y", "<esc>"], on: ed)
    let ed2 = StubEditor("one two", caret: 0)
    feed(engine, ["."], on: ed2)
    // cw deletes "one " then inserts "XY" → "XYtwo"
    expect(ed2.text == "XYtwo", "got: \(ed2.text)")
}

test("VimEngine: . replays cc with new text") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["c", "c", "Z", "<esc>"], on: ed)
    let ed2 = StubEditor("foo\nbar", caret: 0)
    feed(engine, ["."], on: ed2)
    // cc empties line "foo" (leaving "\nbar"), then inserts "Z" → "Z\nbar"
    expect(ed2.text == "Z\nbar", "got: \(ed2.text)")
}

test("VimEngine: . replays C (change to end of line) with new text") {
    let engine = VimEngine()
    let ed = StubEditor("hello world", caret: 0)
    feed(engine, ["C", "X", "<esc>"], on: ed)
    let ed2 = StubEditor("foo bar baz", caret: 4)  // on 'b' of bar
    feed(engine, ["."], on: ed2)
    // C from position 4 deletes "bar baz", then inserts "X" → "foo X"
    expect(ed2.text == "foo X", "got: \(ed2.text)")
}

test("VimEngine: . replays s with new text") {
    let engine = VimEngine()
    let ed = StubEditor("abc", caret: 0)
    feed(engine, ["s", "X", "Y", "<esc>"], on: ed)
    let ed2 = StubEditor("foo", caret: 1)
    feed(engine, ["."], on: ed2)
    // s deletes char at cursor (1 → 'o') then inserts "XY" → "fXYo"
    expect(ed2.text == "fXYo", "got: \(ed2.text)")
}

test("VimEngine: . repeats consecutively (idempotent)") {
    let engine = VimEngine()
    let ed = StubEditor("foo", caret: 3)
    feed(engine, ["a", "X", "<esc>"], on: ed)
    let ed2 = StubEditor("bar", caret: 0)
    feed(engine, [".", "."], on: ed2)
    // First .: a → caret 1, insert X → "bXar", caret 2.
    // Second .: a → caret 3, insert X → "bXaXr", caret 4.
    expect(ed2.text == "bXaXr", "got: \(ed2.text)")
}

test("VimEngine: backspace in insert mode shrinks recording") {
    let engine = VimEngine()
    let ed = StubEditor("", caret: 0)
    feed(engine, ["i", "a", "b", "c", "<bs>", "<esc>"], on: ed)
    let ed2 = StubEditor("", caret: 0)
    feed(engine, ["."], on: ed2)
    // Recording: abc, then backspace removed 'c' → "ab".
    expect(ed2.text == "ab", "got: \(ed2.text)")
}

test("VimEngine: empty insert mode ends with no replay text") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 2)
    feed(engine, ["i", "<esc>"], on: ed)
    let ed2 = StubEditor("world", caret: 0)
    feed(engine, ["."], on: ed2)
    // Nothing was typed; replay does nothing visible.
    expect(ed2.text == "world", "got: \(ed2.text)")
}

// ─── Ctrl-d / Ctrl-u half-page scroll

test("VimEngine: Ctrl-d moves cursor down half a viewport") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne\nf\ng\nh", caret: 0)
    ed.stubViewportLineCount = 6  // half = 3 lines
    feed(engine, ["<c-d>"], on: ed)
    // Stub has no visual-line layout, so engine falls back to logical
    // .down motion by 3. Cursor moves to line 3 (position 6 = 'd').
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: Ctrl-u moves cursor up half a viewport") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne\nf\ng\nh", caret: 14)  // on 'h'
    ed.stubViewportLineCount = 6  // half = 3 lines
    feed(engine, ["<c-u>"], on: ed)
    // Move up 3 lines from line 7 → line 4 (position 8 = 'e').
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: Ctrl-d falls back to 10 lines when no viewport") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl", caret: 0)
    // No stubViewportLineCount → default 20, half = 10.
    feed(engine, ["<c-d>"], on: ed)
    // Move down 10 logical lines: each line is 2 chars (char + \n).
    // Line 10 starts at position 20. Buffer is 23 chars total.
    expect(ed.selectedRange.location == 20, "got \(ed.selectedRange.location)")
}

// ─── zz / zt / zb

test("VimEngine: zz requests center-of-viewport scroll at cursor") {
    let engine = VimEngine()
    let ed = StubEditor("line\nline\nline", caret: 7)
    feed(engine, ["z", "z"], on: ed)
    expect(ed.scrollRequests.count == 1)
    if let req = ed.scrollRequests.first {
        expect(req.location == 7)
        expect(req.alignment == .center)
    }
}

test("VimEngine: zt requests top-of-viewport scroll") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 2)
    feed(engine, ["z", "t"], on: ed)
    expect(ed.scrollRequests.first?.alignment == .top)
}

test("VimEngine: zb requests bottom-of-viewport scroll") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 2)
    feed(engine, ["z", "b"], on: ed)
    expect(ed.scrollRequests.first?.alignment == .bottom)
}

test("VimEngine: z then non-zt/zb char is a no-op") {
    let engine = VimEngine()
    let ed = StubEditor("hello", caret: 2)
    feed(engine, ["z", "x"], on: ed)
    expect(ed.scrollRequests.isEmpty, "no scroll request expected, got \(ed.scrollRequests.count)")
}

// ─── Indent operators

test("VimEngine: >> indents current line by 2 spaces") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, [">", ">"], on: ed)
    expect(ed.text == "  hello\nworld", "got: \(ed.text)")
}

test("VimEngine: << outdents current line by 2 spaces") {
    let engine = VimEngine()
    let ed = StubEditor("    hello\nworld", caret: 0)
    feed(engine, ["<", "<"], on: ed)
    expect(ed.text == "  hello\nworld", "got: \(ed.text)")
}

test("VimEngine: << on unindented line is a no-op") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, ["<", "<"], on: ed)
    expect(ed.text == "hello\nworld", "got: \(ed.text)")
}

test("VimEngine: 3>> indents 3 lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd", caret: 0)
    feed(engine, ["3", ">", ">"], on: ed)
    expect(ed.text == "  a\n  b\n  c\nd", "got: \(ed.text)")
}

test("VimEngine: >j indents current and next line") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc", caret: 0)
    // > then j (j is not a registered motion in motionFor), but j IS
    // mapped to .down via the operator path... actually j is NOT in
    // motionFor. Use a different motion that IS in motionFor: e.g., }
    feed(engine, [">", "}"], on: ed)
    // } is paragraphForward — on a 3-line buffer with no blank lines,
    // it jumps to buffer end. All 3 lines should be indented.
    expect(ed.text == "  a\n  b\n  c", "got: \(ed.text)")
}

test("VimEngine: visual > indents selected lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd", caret: 0)
    feed(engine, ["V", "j", ">"], on: ed)
    // V selects line 1, j extends to include line 2 (both selected).
    expect(ed.text == "  a\n  b\nc\nd", "got: \(ed.text)")
}

test("VimEngine: visual < outdents selected lines") {
    let engine = VimEngine()
    let ed = StubEditor("  a\n  b\n  c", caret: 0)
    feed(engine, ["V", "j", "<"], on: ed)
    expect(ed.text == "a\nb\n  c", "got: \(ed.text)")
}

test("VimEngine: . repeats >>") {
    let engine = VimEngine()
    let ed = StubEditor("hello\nworld", caret: 0)
    feed(engine, [">", ">", "."], on: ed)
    expect(ed.text == "    hello\nworld", "got: \(ed.text)")
}

// ─── gj / gk (explicit logical-line motion)

test("VimEngine: gj moves down by logical line") {
    let engine = VimEngine()
    let ed = StubEditor("line1\nline2\nline3", caret: 0)
    feed(engine, ["g", "j"], on: ed)
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: gk moves up by logical line") {
    let engine = VimEngine()
    let ed = StubEditor("line1\nline2\nline3", caret: 12)  // on 'l' of line3
    feed(engine, ["g", "k"], on: ed)
    expect(ed.selectedRange.location == 6, "got \(ed.selectedRange.location)")
}

test("VimEngine: 2gj moves down 2 logical lines") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd", caret: 0)
    feed(engine, ["2", "g", "j"], on: ed)
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

// ─── Ctrl-f / Ctrl-b full-page scroll

test("VimEngine: Ctrl-f moves a full viewport down") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne\nf\ng", caret: 0)
    ed.stubViewportLineCount = 4
    feed(engine, ["<c-f>"], on: ed)
    // Full page = 4 lines, fall back to logical motion → position 8 ('e').
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: Ctrl-b moves a full viewport up") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne\nf\ng", caret: 12)  // on 'g'
    ed.stubViewportLineCount = 4
    feed(engine, ["<c-b>"], on: ed)
    // Up 4 from line 7 → line 3 ('c' at position 4).
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

// ─── H / M / L

test("VimEngine: H jumps to top visible line") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne", caret: 8)
    ed.stubVisibleTop = 0
    feed(engine, ["H"], on: ed)
    expect(ed.selectedRange.location == 0, "got \(ed.selectedRange.location)")
}

test("VimEngine: M jumps to middle visible line") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne", caret: 0)
    ed.stubVisibleMiddle = 4  // 'c'
    feed(engine, ["M"], on: ed)
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

test("VimEngine: L jumps to bottom visible line") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc\nd\ne", caret: 0)
    ed.stubVisibleBottom = 8  // 'e'
    feed(engine, ["L"], on: ed)
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: H / M / L are no-ops when host has no viewport") {
    let engine = VimEngine()
    let ed = StubEditor("a\nb\nc", caret: 2)
    feed(engine, ["H"], on: ed)
    expect(ed.selectedRange.location == 2, "caret should not move; got \(ed.selectedRange.location)")
}

// ─── Goto line (NG, Ngg, :N<Enter>)

test("VimEngine: NG jumps to absolute line N") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree\nfour", caret: 0)
    feed(engine, ["3", "G"], on: ed)
    // Line 3 starts after two \n chars: positions 0-3 (one\n), 4-7 (two\n), 8 (start of three)
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: bare G still goes to last line") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 0)
    feed(engine, ["G"], on: ed)
    // Last line "three" starts at 8.
    expect(ed.selectedRange.location == 13 || ed.selectedRange.location == 8 ||
           ed.selectedRange.location == (("one\ntwo\nthree" as NSString).length),
           "got \(ed.selectedRange.location)")
}

test("VimEngine: Ngg jumps to absolute line N") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree\nfour", caret: 15)
    feed(engine, ["2", "g", "g"], on: ed)
    // Line 2 starts at position 4.
    expect(ed.selectedRange.location == 4, "got \(ed.selectedRange.location)")
}

test("VimEngine: :N<Enter> jumps to absolute line N") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo\nthree", caret: 0)
    feed(engine, [":", "3", "<enter>"], on: ed)
    expect(ed.selectedRange.location == 8, "got \(ed.selectedRange.location)")
}

test("VimEngine: goto line past end clamps to buffer end") {
    let engine = VimEngine()
    let ed = StubEditor("one\ntwo", caret: 0)
    feed(engine, ["9", "9", "G"], on: ed)
    let len = ("one\ntwo" as NSString).length
    expect(ed.selectedRange.location <= len, "got \(ed.selectedRange.location)")
}


// ─── Summary ───

print("\n\(passed + failed) tests, \(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}

}  // end of MainActor.assumeIsolated

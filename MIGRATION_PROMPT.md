# Migrate this app from copied VimEngine source to the swift-vim-engine package

Paste this into a Claude session in an app that **already has VimEngine
copied in** (typically a `VimEngine.swift` file under `Sources/` and a
target in `Package.swift`). The migration replaces the bundled copy
with a versioned dependency on
[`msjurset/swift-vim-engine`](https://github.com/msjurset/swift-vim-engine)
so future fixes propagate via a version bump rather than another copy.

## Before you start

**Check for local modifications first.** Run:

    diff Sources/VimEngine/VimEngine.swift <(curl -sSL https://raw.githubusercontent.com/msjurset/swift-vim-engine/v1.0.0/Sources/VimEngine/VimEngine.swift)

If the diff is non-empty, this app has local edits to the engine.
**Stop and surface them to me before continuing.** Options are:

1. Upstream them as a PR to `msjurset/swift-vim-engine`, wait for a
   release, then migrate.
2. Keep them as a fork (point the package URL at the fork).
3. Decide they were workarounds for an old bug already fixed upstream
   and discard.

Pick one explicitly. Don't silently lose changes.

## What to do

1. **Add the package dependency** to `Package.swift`:

       dependencies: [
           .package(url: "https://github.com/msjurset/swift-vim-engine.git", from: "1.0.0")
       ]

2. **Switch every consumer target** that depended on the local
   `VimEngine` target to depend on the product instead:

       .target(
           name: "MyAppLib",
           dependencies: [
               .product(name: "VimEngine", package: "swift-vim-engine")
           ],
           path: "Sources/MyAppLib"
       )

3. **Remove the local VimEngine target** definition from `Package.swift`
   (the entire `.target(name: "VimEngine", path: "Sources/VimEngine")`
   block).

4. **Delete the bundled source files**:

       git rm Sources/VimEngine/VimEngine.swift
       git rm -f Sources/VimEngine/README.md            # if present
       git rm -f Sources/VimEngine/INTEGRATION_PROMPT.md # if present

   If `Sources/VimEngine/` ends up empty afterward, you can remove the
   directory. If it has app-specific files (e.g. integration notes,
   icon prompts), leave those alone.

5. **Resolve and pin** the new dependency:

       swift package resolve

   Commit `Package.resolved` so other contributors get the same version.

6. **Verify the build**:

       swift build
       swift test  # or whatever this app's test command is

7. **Smoke-test vim mode** in the running app. The smoke test from the
   integration prompt still applies — `/vim` → `i` insert → Esc →
   `dd`, `yy`, `p`, `cwTODO<Esc>`, `:q<Enter>`.

## What stays in this app

These are NOT in the package — they're integration-side and stay in
this app's source tree:

- The `NSTextView` subclass that forwards `keyDown` to `engine.handleKey`
  and overrides `drawInsertionPoint` + `setSelectedRanges`.
- The mode-badge UI.
- The slash-command machinery (if used) — `SlashCommand` /
  `TemplateStore` / `SlashCommandRegistry` / `SlashSuggestionView` /
  `VimCheatsheetView`. The package doesn't ship these because they're
  app-specific UX patterns, not engine logic.
- The Esc-arbitration notification pattern, if the host panel has its
  own dismiss-on-Esc handler.

For canonical reference implementations of all of the above, see
[`msjurset/jrnlbar`](https://github.com/msjurset/jrnlbar) — that's
the source repo where this package was incubated.

## Future updates

When swift-vim-engine releases a new version:

    swift package update swift-vim-engine

Then `Package.resolved` updates and you build/test as usual. If a new
release requires a host-side change (e.g. a new protocol method on
`VimTextEditor`), the release notes / `CHANGELOG.md` in the package
repo will say so. Read those before bumping past a major version.

## Deliver

When you're done, give me:

1. The diff (Package.swift change, deleted source files, Package.resolved).
2. Confirmation the smoke test passed.
3. If there were local modifications, what you did with them.

# CLAUDE.md

## Project Overview

**Window Ninja** — Raycast extension that lists and switches between **individual open windows** across all applications and all macOS Spaces. Solves the limitation of Raycast's built-in "Switch Windows" which only shows one entry per app.

## Architecture

Two components:

1. **Swift helper binary** (`swift-helper/Sources/ListWindows/main.swift` → compiled to `assets/list-windows`)
   - Structured as a Swift Package Manager project for LSP support
   - Uses macOS Accessibility API + private APIs to enumerate windows across all Spaces
   - Outputs JSON to stdout; accepts subcommands: `focus`, `close`, `minimize`, `maximize`, `fullscreen`, `unfullscreen` (all `<pid> <idx>`), and `hide-app`, `show-app` (`<pid>`)
   - CLI arg parsing is centralized via `parsePidAndIndex()` and `parsePid()` helpers
   - Window resolution (scan + lookup + bounds check) is centralized via `resolveWindow()`
   - Automatically recompiled by `npm run dev` and `npm run build`

2. **Raycast extension** (`src/window-ninja.tsx`)
   - Calls the Swift binary via `child_process.execFile`, parses JSON, renders Raycast `<List>`
   - Reads the `showMinimizedWindows` preference and filters accordingly
   - Minimal logic — all window discovery and manipulation is in Swift

## Key Private APIs Used (from AltTab)

- `_AXUIElementCreateWithRemoteToken` — brute-force find windows on other Spaces
- `_AXUIElementGetWindow` — bridge AXUIElement to CGWindowID
- `CGSMainConnectionID` / `CGSCopySpacesForWindows` — determine which CG windows are real windows vs tabs

## Development

```bash
npm install
npm run dev          # Compile Swift binary + start Raycast dev mode
npm run build        # Compile Swift binary + production build
npm run build:swift  # Compile Swift binary only
npm run typecheck    # TypeScript type checking
npm run lint         # Lint check
npm run fix-lint     # Auto-fix lint issues
npm run format       # Format code with Prettier
npm run format:swift # Format Swift code with swift-format
```

A pre-commit hook runs format, typecheck, and lint before each commit.

`npm run dev` and `npm run build` automatically recompile the Swift binary first — no need to run the compiler manually unless you want to.

## Permissions

- **Accessibility** — required (Raycast already has this). The compiled binary inherits Accessibility trust.
- **Screen Recording** — NOT required.

## Tab vs Window Deduplication

The brute-force method finds AX elements for individual tabs too. Tabs are filtered out using `CGSCopySpacesForWindows`: real windows are assigned to a macOS Space, tab CG windows are not. This correctly handles fullscreen windows on different Spaces (each has its own Space ID).

## Performance

The Swift binary uses five optimizations to keep enumeration fast:

1. **Skip windowless apps** — `cgWindowScan()` does a single `CGWindowListCopyWindowInfo` pass to collect which PIDs own at least one window. Apps with no windows are skipped before the AX brute-force runs.
2. **Parallel enumeration** — `DispatchQueue.concurrentPerform` processes all eligible apps concurrently across CPU threads.
3. **Bounded brute-force** — The element ID sweep is capped at 500 IDs / 50ms per app (down from 1000 / 100ms).
4. **Consecutive-miss early exit** — The brute-force loop stops after 50 consecutive misses, since element IDs cluster in low numbers. Most apps exit after ~60 IDs instead of 500.
5. **Skip brute-force when unnecessary** — `cgWindowScan()` counts real windows per PID. If the standard AX API already found all of an app's windows, brute-force is skipped entirely for that app.

## Window Close Strategy

`closeWindow()` uses a two-strategy cascade **without post-close verification**:

1. **Close button** (non-fullscreen only) — Gets the AX close button (`kAXCloseButtonAttribute`) and presses it. If `AXUIElementPerformAction` returns `.success`, reports success immediately.
2. **AppleScript** — Falls back to `tell application id "..." to close (first window whose name is "...")`. Matches by window title (not index, since AX enumeration order differs from AppleScript's). If AppleScript returns no error, reports success immediately.
3. **Terminate app** — If the app has only one window and the above strategies failed, terminates the app entirely.

If all strategies fail, returns `{"success":false}`.

### Why no post-close verification (DO NOT re-add)

Previous versions used `windowExists()` (a `CGWindowListCopyWindowInfo` scan) after each strategy to confirm the window was gone. This was removed because:

- **Fullscreen windows**: macOS keeps the CGWindowID alive during the Space-collapse animation (~500ms-1s+). A 200ms check always sees the window as "still there", causing false failure reports.
- **Non-fullscreen windows**: Some apps (e.g. iTerm2) also exhibit delayed CGWindowID cleanup, causing the same false failures.
- **Close button unreliable on fullscreen**: For apps like iTerm2, `AXUIElementPerformAction` on the close button returns `.success` but doesn't actually close fullscreen windows. Only AppleScript works. So for fullscreen windows, strategy 1 is skipped entirely.

This matches how every mature macOS window manager handles closing:

- **AltTab** (`lwouis/alt-tab-macos`, `src/logic/Window.swift`) — fires the AX close button with `try?` (fire-and-forget), no verification. Uses `kAXUIElementDestroyedNotification` reactively to update its window list.
- **AeroSpace** (`nikitabobko/AeroSpace`, `Sources/AppBundle/tree/MacApp.swift`) — fires the AX close button, removes from internal tracking on AX success, no verification.
- **Rectangle** and **Amethyst** — don't implement window closing at all.

None of these projects use AppleScript fallbacks or poll `CGWindowListCopyWindowInfo` post-close. The `windowExists()` helper is retained in the codebase for use by other operations (e.g. minimize verification) but is intentionally not used in the close path.

## Window Minimize Strategy

`minimizeWindow()` handles fullscreen windows by exiting fullscreen first, then retrying minimization for up to ~2s. The retry loop tracks the target window by `CGWindowID` (not positional index) to avoid operating on the wrong window if macOS reorders AX elements during the fullscreen transition.

## User Preferences

| Preference             | Type     | Default | Description                           |
| ---------------------- | -------- | ------- | ------------------------------------- |
| `showMinimizedWindows` | checkbox | false   | Include minimized windows in the list |

The Swift binary always outputs `isMinimized` on each window. Filtering happens on the TypeScript side based on the preference value.

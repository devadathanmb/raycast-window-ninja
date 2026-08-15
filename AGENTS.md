# AGENTS.md

## Project

Window Ninja is a Raycast extension that lists and controls individual macOS windows across applications and Spaces.

## Architecture

- `src/window-ninja.tsx`: Raycast List UI, preferences, helper execution, feedback, and refresh polling.
- `win-ninja/Sources/WinNinja/main.swift`: window discovery and macOS Accessibility actions.
- `assets/win-ninja`: compiled helper shipped with the extension.
- `WORKING.md`: detailed discovery and action design.

The extension launches the helper with `execFile`. `list` returns a JSON array. Each action returns one JSON `ActionResponse`.

Window commands use `<command> <pid> <window-id>`. Application commands use `<command> <pid>`.

`window-id` is `CGWindowID`. Actions use `(pid, window-id)` because each helper invocation re-enumerates windows; array positions and titles are not stable identities.

## Behavioral invariants

- **Close Window** presses the selected AX close button. It does not terminate the application or target a title through AppleScript.
- Fullscreen close exits fullscreen, waits for the Space transition, and reacquires the same WID before closing.
- Focus closes Raycast only after the helper reports success.
- Management actions use Toasts because the List remains visible and refreshes.
- Transition polling uses 120, 350, and 700 ms action-relative deadlines and compares normalized window state.
- Helper stdout contains one JSON value. Diagnostics go to stderr.
- PID and WID input must be positive and nonzero.

## macOS APIs

Cross-Space discovery depends on these undocumented symbols:

- `_AXUIElementCreateWithRemoteToken`
- `_AXUIElementGetWindow`
- `CGSMainConnectionID`
- `CGSCopySpacesForWindows`

Raycast's public API cannot enumerate and focus arbitrary windows across all Spaces. These private symbols have no ABI guarantee, so keep their declarations isolated and describe their behavior as observed rather than guaranteed by Apple.

Current bounds:

- AX messaging timeout: 1 second.
- Helper process timeout: 5 seconds.
- Remote-token scan: 500 IDs, 50 consecutive misses, or 50 ms per application.

## Development

```bash
npm install
npm run dev          # Rebuild helper and start Raycast development mode
npm run build        # Rebuild helper, type-check, and build dist
npm run build:swift  # Rebuild assets/win-ninja
npm run typecheck
npm run lint         # ESLint, Prettier check, and Swift format lint
npm run fix-lint
npm run format
npm run format:swift
```

The pre-commit hook runs `npm run format` and `npm run lint`. Run `npm run typecheck` separately before committing TypeScript changes.

For Swift changes:

1. Run `npm run build:swift` so `assets/win-ninja` matches the source.
2. Run `npm run lint` and `npm run typecheck`.
3. Parse `assets/win-ninja list` as JSON and test malformed arguments without invoking destructive actions.

For Raycast UI changes, run `npm run typecheck`, `npm run lint`, and `npm run build`, then exercise the changed interaction in Raycast.

Keep `WORKING.md` synchronized with protocol, discovery, permission, and action behavior.

## Conventions

- License: AGPL-3.0-only.
- Prefer direct functions and existing files over new abstractions.
- Keep TypeScript focused on UI and protocol handling; keep macOS behavior in Swift.
- Comments explain private API assumptions, safety boundaries, and non-obvious timing.
- Retry mutating AX actions only when duplicate execution is safe.

# Window Ninja

A Raycast extension that lists and switches between **individual open windows** across all applications and all macOS Spaces.

Raycast's built-in window switcher shows one entry per app. If multiple windows are open — even fullscreen on different Spaces — they are grouped together. Window Ninja lists every real window and lets you switch directly to the one you want.

<img width="3024" height="1964" alt="image" src="https://github.com/user-attachments/assets/c252dd37-a01c-4d01-9d79-0cb77d4646a3" />

## Why?

Coming from Linux, window switching was never a problem. Tools like [`dmenu`](https://tools.suckless.org/dmenu/) and [`rofi`](https://github.com/davatorium/rofi) let you script anything — write custom window switching scripts, fuzzy-search across windows, hook into any part of the system. Everything was accessible and scriptable.

On macOS, things are more locked down. There's very limited scope for scripting without breaking something (or signing away your system's soul to bypassing security restrictions). [Raycast](https://raycast.com/) gets close to filling that gap, but its window switcher only works at the application level. Multiple browser windows, multiple VS Code windows, fullscreen windows on different Spaces — all grouped into one entry. You can't reliably switch to a specific window.

Turns out I'm not alone in wanting this. There are many threads about it:

- [Is there any way to switch between different windows of the same app?](https://www.reddit.com/r/raycastapp/comments/1i4q0nf/is_there_any_to_switch_between_different_window/)
- [Action/Hotkey for switching between windows of the same app](https://www.reddit.com/r/raycastapp/comments/1aoyfp5/actionhotkey_for_switching_between_windows_of_the/)
- [Many more on Reddit](https://www.google.com/search?q=raycast+switch+between+windows+reddit)

I ended up raising a feature request with Raycast hoping they'd implement it, but what I got was the classic "we'll look into it" reply.

But then I thought — I'm a programmer myself, and I've seen [AltTab](https://github.com/lwouis/alt-tab-macos) doing exactly this. There has to be a way, right?

So armed with Claude, DeepWiki, and approximately zero Swift knowledge, I decided to hack my own solution.

## Demo

https://github.com/user-attachments/assets/099fa2f1-58b6-40a3-a1a3-41e451118dab

## Installation

1. Clone the repository:

```bash
git clone https://github.com/devadathanmb/window-ninja
cd window-ninja
```

2. Install dependencies:

```bash
npm install
```

3. Build the extension (generates a `dist/` directory containing the built extension):

```bash
npm run build
```

4. Import into Raycast:
   - Open Raycast
   - Search for "Import Extension"
   - Select the `dist` folder inside the `window-ninja` folder

The extension will now be available in Raycast.

## Usage

Open Raycast, type `Window Ninja`, search by window title or app name, and press Enter to switch.

## Performance

This extension is blazingly fast. Below is the benchmark of the binary, done using [hyperfine](https://github.com/sharkdp/hyperfine):

```
❯ hyperfine --warmup 20 --runs 100 ./assets/list-windows 2>&1
Benchmark 1: ./assets/list-windows
  Time (mean ± σ):      45.5 ms ±   2.8 ms    [User: 4.6 ms, System: 3.5 ms]
  Range (min … max):    39.4 ms …  55.5 ms    100 runs
```

## Development

To start development mode with hot reloading:

```bash
npm run dev
```

Make your changes to the TypeScript files in `src/`. The extension will automatically reload in Raycast.

### Modifying the Swift Helper

If you modify the Swift helper in the `swift-helper/` directory, recompile it:

```bash
npm run build:swift
```

The Raycast extension is intentionally minimal. All window discovery logic lives in the Swift helper.

## Acknowledgements

- [AltTab](https://github.com/lwouis/alt-tab-macos) — the cross-Space window enumeration technique and private API usage are directly based on AltTab's implementation.

## License

[AGPL-3.0](./LICENSE)

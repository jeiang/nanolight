<p align="center"><img src="src/icon-256.png" alt="Nanolight's icon" width="96" height="96"></p>

<h1 align="center">Nanolight</h1>
<p align="center"><b>A launcher for the Mac, Windows and Linux, drawn by <a href="https://github.com/justrach/nanoui">nanoui</a>.</b><br>
Apps, math, Google, Grok, X and Raycast script commands: one keystroke away. Native Zig, no Electron, about 2 MB.</p>

<p align="center"><sub>Forked from <a href="https://github.com/justrach/nanolight">justrach/nanolight</a>, built on <a href="https://github.com/justrach/nanoui">nanoui</a>.</sub></p>

<p align="center"><a href="https://github.com/jeiang/nanolight/raw/refs/heads/main/docs/promo.mp4"><img src="docs/promo-preview.gif" alt="Introducing Nanolight 2.0, now on Mac, Windows and Linux, in 40 seconds: a MacBook Air and a Dell XPS 13 side by side, then Settings, a Raycast extension and a script command on a MacBook Air, then Windows and Linux on a Dell XPS 13" width="760"></a><br><sub><a href="https://github.com/jeiang/nanolight/raw/refs/heads/main/docs/promo.mp4"><b>Watch it with sound →</b></a> · <a href="docs/promo.md">How it was made</a></sub></p>

<p align="center"><img src="docs/images/nanolight.jpg" alt="Nanolight's panel has found Safari from &quot;saf&quot;" width="760"></p>

## What it does

- **Finds apps as you type**: whole names, starts of words, initials (`ss` is System Settings), letters in order, and typos (`chorme` is Chrome). What you open often climbs.
- **System Settings panes** (Mac): "login items", "wifi" or "dark mode" lists the pane, under the apps, and Return opens System Settings right at it.
- **Completes inline**: the rest of the top app's name, or of Google's top suggestion, is drawn faintly after the caret. Tab or → takes it; Return never does.
- **Does math**: `2^10 * 3` answers 3,072 (and `0xC00`). Return copies it.
- **Google suggestions**: up to four, under the apps, the words you add in bold. Nothing that reads as an address (a dot, a slash, an @) is sent.
- **Results in the panel**: Return on a search shows Google's page in the panel itself. Esc goes back to the list, ⌘↩ opens it in your browser, ⌘[ goes back a page. Prefer the browser? Turn on **Open Searches in Browser** in Settings: Return opens your browser, and ⌘↩ shows the page in the panel.
- **Ask Grok, search X**, a row away.
- **Raycast script commands** ([raycast/script-commands](https://github.com/raycast/script-commands), MIT): any script with `@raycast.*` comments, dropped in the Script Commands folder, is a row. Nanolight runs it itself: its arguments as a form, its output as it prints (`fullOutput`), its last line (`compact`), or nothing (`silent`).
- **Settings in the panel**: ⌘, (Ctrl+, on a PC), the gear in the footer, or type "settings".
- **⌘1–⌘9** run a row at once; ↑ ↓ and ⌃N ⌃P move.
- **Config file**: `config.toml` seeds the settings (see [Configuration](#configuration)).
- On the Mac it lives in the menu bar: no Dock icon, and nothing drawn while it's idle. **Show in Menu Bar** in Settings hides the icon; Settings stays a ⌘, away in the panel.

## Sync across computers (optional)

Off until you turn it on: choose **Sign In with Codegraff** in Settings (or the menu bar icon's menu on the Mac). Your browser opens codegraff.com to approve the sign-in, and from then on every computer signed in to the same account shares:

- the key that opens Nanolight,
- whether Google suggestions are on,
- how often you open each app, so an empty panel suggests the same apps everywhere.

Two Macs merge rather than overwrite: the key and the suggestions setting follow whichever Mac changed them last, and each app keeps its higher count. Nothing else is sent: no queries, no history, no files. The sign-in key is kept in your Keychain, and **Sign Out of Codegraff** revokes it.

Syncing goes through your Codegraff account, so [Codegraff's terms](https://codegraff.com/terms) and [privacy policy](https://codegraff.com/privacy) apply to it. New accounts made by signing in from Nanolight get $2 of Codegraff credit.

## Configuration

Nanolight reads `config.toml` at launch: from `$NANOLIGHT_CONFIG` if that is set, otherwise from Nanolight's data folder, next to `script-commands` (`~/Library/Application Support/Nanolight` on the Mac, `%APPDATA%\Nanolight` on Windows, `~/.local/share/Nanolight` on Linux). No file means the defaults. A file that fails to parse is logged to stderr with its line number and ignored; nothing else breaks.

The file seeds the settings and the app's own changes win. Nanolight remembers the last value it applied from each key, and applies a key only when the file's value differs from that: edit `hotkey` in the file and the new key takes over (and syncs, as a change made just now); leave it alone and a key chosen in Settings stays. A key you delete from the file leaves the app's value as it is. `hotkey` is a preset name (`cmd_space`, `opt_space`, `ctrl_space`, `opt_cmd_space`) or a recorded `key:<code>:<mods>:<char>`.

```toml
hotkey = "cmd_space"          # shortcut.Choice name or recorded "key:..."; default per OS as shortcut.zig has it (Alt Space off the Mac)
suggestions = true            # Google completions
open_searches_in_browser = false
show_in_menu_bar = true
pop_to_root_seconds = 90      # 0 = never

[apps]
extra_dirs = []               # scanned like /Applications (depth 1)

[script_commands]
dirs = []                     # in addition to <data dir>/script-commands

[[quicklinks]]                # if any are given, they replace the defaults
name = "DuckDuckGo"
url = "https://duckduckgo.com/?q={argument}"
keyword = "ddg"               # optional

[clipboard]
enabled = true
retention_days = 7
max_entries = 1000
paste_plain_text = true       # Return pastes as plain text (vs copy only when false or unsupported)
exclude_apps = ["com.bitwarden.desktop", "com.yubico.yubioath"]  # mac bundle IDs, Windows exe names, Linux app IDs

[sync]
url = ""                      # e.g. "http://100.x.y.z:8890"; empty = off
token_file = ""               # file holding the bearer token (sops path under Nix)
```

Today `hotkey`, `suggestions`, `open_searches_in_browser`, `show_in_menu_bar`, `[apps] extra_dirs` and `[script_commands] dirs` take effect. `pop_to_root_seconds`, `[[quicklinks]]`, `[clipboard]` and `[sync]` are read and checked but do nothing yet. A key of the wrong type fails the file; an unknown key is logged and ignored. The parser (`src/toml.zig`) is TOML 1.0 without datetimes, and reads what Nix's `pkgs.formats.toml` writes.

When the file sets `hotkey`, the welcome skips its key and login steps.

## Install

From the [latest release](https://github.com/jeiang/nanolight/releases/latest):

- **Mac**: `nanolight-macos-arm64.dmg`. Open it and drag Nanolight to Applications. macOS 14 or later, Apple silicon.
- **Windows**: `nanolight-windows-x86_64.zip`. Unzip it anywhere you can write and run `nanolight.exe`. Windows 10 or later.
- **Linux**: `nanolight-linux-x86_64.tar.gz` (or `aarch64`). Unpack it and run `nanolight`. It needs GTK 3 (or 4) and an X11 session for its key; on Wayland, bind `nanolight --toggle` to a key in your desktop's keyboard settings.

On first run a short welcome picks the key that opens it and says who else holds it. On the Mac that's ⌘Space, ⌥Space, ⌃Space or ⌥⌘Space (any other, such as ⌥X, can be recorded later in Settings; Spotlight gives up ⌘Space in System Settings → Keyboard → Keyboard Shortcuts → Spotlight); on a PC, Alt Space, Ctrl Alt Space, Ctrl Space or Ctrl Shift Space. Releases update themselves from this repository's releases, restarting into the new version while the panel is away. (A build made with `-Dnix=true` never does.)

## Build

You need Zig 0.17.0 and Xcode or the Command Line Tools.

```sh
zig build test      # search, math, suggestions and the panel, through nanoui's Tester
zig build run       # build and open it
zig build app       # zig-out/Nanolight.app, for /Applications
VERSION=0.1.0 sh macos/package.sh   # the Mac release: signed app, disk image, update zip, manifest.json
VERSION=0.1.0 sh pc/package.sh      # Windows' zip and Linux's tarballs, added to manifest.json
zig build -Dtarget=x86_64-windows-gnu   # any target from any machine
zig build -Dnix=true                    # a Nix-managed build: no updater, no Open at Login (the Nix modules own startup)
```

`macos/package.sh` signs with `$CODESIGN_IDENTITY` and notarizes when notary credentials are set (see the script); otherwise it signs ad hoc. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds, signs and attaches the release.

## How it's made

| File | What |
| --- | --- |
| `src/main.zig` | The app: the window, the hot key, the menu bar icon, updates |
| `src/view.zig` | The panel: query, rows, footer, keys |
| `src/results.zig` | What a query lists, in order |
| `src/search.zig` | Fuzzy matching and ranking, allocation-free |
| `src/calc.zig` | The calculator |
| `src/suggest.zig` | Google's completions: the privacy guard, decoding, the cache (after [browse](https://github.com/justrach/browse)) |
| `src/preview.zig` | The results page in the panel (WKWebView, the Mac) |
| `src/panel_mac.zig`, `src/panel_pc.zig` | The panel's window on the Mac, and on Windows and Linux |
| `src/hotkey*.zig`, `src/apps_*.zig`, `src/single*.zig`, `src/login.zig`, `src/keychain*.zig` | Each platform's key, apps, single copy, login item and secret |
| `src/raycast_model.zig`, `src/raycast_view.zig` | The panel's command screen (a script's output, arguments) |
| `src/script_commands.zig`, `src/script_run.zig` | Raycast script commands, run in Zig |
| `src/toml.zig`, `src/config.zig` | `config.toml`: the TOML subset parser, the typed schema and loader, and how the file seeds settings |
| `src/onboard.zig`, `src/shortcut.zig`, `src/recorder.zig` | The welcome, which key is free, recording one's own |
| `src/film.zig`, `src/stage.zig`, `tools/film.sh` | The walkthrough, rendered offscreen |
| `src/promo.zig`, `src/promo_scene.zig`, `src/promo_camera.zig`, `tools/promo.sh`, `tools/promo/` | The promo: nanoui's shots, Blender's laptops, the Windows and Linux recordings ([docs/promo.md](docs/promo.md)) |

The icon is drawn by `tools/icon.py`. `src/backdrop.jpg` (the film's cover art) was made with OpenAI's image model.

## License

MIT

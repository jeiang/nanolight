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

Off until `[sync]` in `config.toml` names a server you run (`nanolight-server`, below). Every computer that uses the same account's token shares:

- the key that opens Nanolight,
- whether Google suggestions are on,
- the quicklinks from the config (carried in the record; nothing lists them yet),
- how often you open each app, so an empty panel suggests the same apps everywhere.

Two computers merge rather than overwrite: the key, the suggestions setting and the quicklinks follow whichever computer changed them last, and each app keeps its higher count. A computer's first sync with a server keeps what the server already holds. Nothing else is sent: no queries, no history, no files. Settings and the menu bar icon's menu show `Sync: <host>, last synced <time>`, `Sync: error <reason>` or `Sync: off (set [sync] in config.toml)`. Nanolight syncs at launch, when the panel opens and the last sync is over five minutes old, and two seconds after a change.

The server keeps one JSON file per account and sees the settings record in the clear: run it on a network you trust (a VPN or a loopback behind your own TLS proxy). The client sends the token as `Authorization: Bearer`, so use `https://` when the path to the server is not private.

### The server

```sh
zig build server                                  # zig-out/bin/nanolight-server
nanolight-server hash-token 'a-long-random-token' # ACCOUNT:<sha256>; replace ACCOUNT with the account's name
nanolight-server serve --listen 127.0.0.1:8890 --state /var/lib/nanolight --tokens /etc/nanolight/tokens
```

The tokens file has one `account:sha256hex(token)` per line, `#` starts a comment, and an account name matches `[a-z0-9_-]{1,64}` (a bad name stops the server at start). Only hashes are stored on the server. Records live at `<state>/<account>.json`, written to a temp file, fsynced and renamed. The server handles one request at a time and drops a client that has not sent its request within 10 seconds. Bodies over 256 KiB get 413.

| Request | Answer |
| --- | --- |
| `GET /healthz` | 200 `ok`, no token |
| `GET /v1/sync` | 200 with the stored record, 404 before the first PUT |
| `PUT /v1/sync` | the record merged into the stored one (`X-Nanolight-First: 1`: the stored one wins), 200 with the result; 400 for a bad body |
| any, wrong or missing token | 401 |

On each computer, put the token in a file only you can read and point the config at it:

```toml
[sync]
url = "http://100.64.0.3:8890"
token_file = "/home/me/.config/nanolight/token"
```

The token is read only from that file; there is no in-app token entry and nothing goes to a keychain.

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

Today `hotkey`, `suggestions`, `open_searches_in_browser`, `show_in_menu_bar`, `[apps] extra_dirs`, `[script_commands] dirs` and `[sync]` take effect. `pop_to_root_seconds`, `[[quicklinks]]` and `[clipboard]` are read and checked but do nothing yet (the quicklinks only travel in the sync record). A key of the wrong type fails the file; an unknown key is logged and ignored. The parser (`src/toml.zig`) is TOML 1.0 without datetimes, and reads what Nix's `pkgs.formats.toml` writes.

When the file sets `hotkey`, the welcome skips its key and login steps.

## Install

From the [latest release](https://github.com/jeiang/nanolight/releases/latest):

- **Mac**: `nanolight-macos-arm64.dmg`. Open it and drag Nanolight to Applications. macOS 14 or later, Apple silicon.
- **Windows**: `nanolight-windows-x86_64.zip`. Unzip it anywhere you can write and run `nanolight.exe`. Windows 10 or later.
- **Linux**: `nanolight-linux-x86_64.tar.gz` (or `aarch64`). Unpack it and run `nanolight`. It needs GTK 3 (or 4) and an X11 session for its key; on Wayland, bind `nanolight --toggle` to a key in your desktop's keyboard settings.

On first run a short welcome picks the key that opens it and says who else holds it. On the Mac that's ⌘Space, ⌥Space, ⌃Space or ⌥⌘Space (any other, such as ⌥X, can be recorded later in Settings; Spotlight gives up ⌘Space in System Settings → Keyboard → Keyboard Shortcuts → Spotlight); on a PC, Alt Space, Ctrl Alt Space, Ctrl Space or Ctrl Shift Space. Releases update themselves from this repository's releases, restarting into the new version while the panel is away. (A build made with `-Dnix=true` never does.)

## Nix

`flake.nix` offers the app, the sync server and modules that install the app, write `config.toml` from Nix, and start it at login (the Nix build has no updater and no login-item UI: the modules own startup). Add the input, and let `nixpkgs` follow yours:

```nix
inputs.nanolight = {
  url = "github:jeiang/nanolight";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Every client module takes the same options: `programs.nanolight.enable`, `.package` and `.settings`, which is `config.toml` as Nix (see [Configuration](#configuration)).

**nix-darwin** (`darwinModules.default`):

```nix
{
  imports = [inputs.nanolight.darwinModules.default];
  programs.nanolight = {
    enable = true;
    settings.sync = {
      url = "http://100.64.0.3:8890";
      token_file = config.sops.secrets.nanolight-token.path;
    };
    # codesignIdentity = "Apple Development: Jane Doe (ABCDE12345)";  # see below
  };
}
```

It installs the app, writes `/etc/nanolight/config.toml`, and runs a launch agent (`RunAtLoad`, restarted when it crashes but not after Quit). `disableSpotlightShortcut` (on by default) turns off Spotlight's ⌘Space; it needs `system.primaryUser`.

Pasting into another app needs the Accessibility grant (System Settings → Privacy & Security → Accessibility). macOS ties the grant to the app's code signature, and a Nix build is signed ad hoc with a new signature each time it changes, so the grant is lost on every rebuild. Set `codesignIdentity` to an identity in your login keychain (Keychain Access → Certificate Assistant → Create a Certificate, type Code Signing, is enough) and the module copies the app to `/Applications/Nanolight.app`, signs it there as `system.primaryUser`, and runs that copy; the grant then survives rebuilds.

**NixOS** (`nixosModules.default`, the client; it starts as a systemd user service with the graphical session):

```nix
{
  imports = [inputs.nanolight.nixosModules.default];
  programs.nanolight = {
    enable = true;
    settings.hotkey = "alt_space";
  };
}
```

**home-manager** (`homeManagerModules.default`): the same options, with `~/.config/nanolight/config.toml` and a systemd user service (Linux) or launch agent (macOS).

```nix
{
  imports = [inputs.nanolight.homeManagerModules.default];
  programs.nanolight.enable = true;
}
```

**Server** (`nixosModules.server`, `packages.<system>.nanolight-server`): a hardened systemd service with its own user and `/var/lib/nanolight`. It speaks plain HTTP, so keep it on a private address (a VPN or mesh) or behind a TLS proxy.

```nix
{
  imports = [inputs.nanolight.nixosModules.server];
  services.nanolight-server = {
    enable = true;
    listenAddress = "100.64.0.3";
    tokensFile = config.sops.secrets.nanolight-tokens.path;  # root-only is fine
    openFirewall = true;
  };
}
```

Tokens: make a random token per account, hash it, and give each computer its own copy of the token.

```sh
token=$(openssl rand -hex 32)
nix run github:jeiang/nanolight#nanolight-server -- hash-token "$token"   # prints ACCOUNT:<sha256>
```

Put `me:<sha256>` (replace `ACCOUNT`; `[a-z0-9_-]`, up to 64) on a line of the file `tokensFile` names, a sops-nix secret for instance, and the bare token in the file that each client's `sync.token_file` names. Only the hash is on the server.

The flake commits no `flake.lock`: run `nix flake lock` once (CI needs the committed lock, and fails without it). Hosts need `nix-command flakes`. `nix flake check` builds the app (running `zig build test`), the server and a NixOS VM test of the server, and evaluates a NixOS configuration with both modules; the nix-darwin and home-manager modules are evaluated against stand-ins for the options they set.

## Build

You need Zig 0.17.0 and Xcode or the Command Line Tools.

```sh
zig build test      # search, math, suggestions and the panel, through nanoui's Tester
zig build run       # build and open it
zig build app       # zig-out/Nanolight.app, for /Applications
zig build server    # zig-out/bin/nanolight-server, the sync server
VERSION=0.1.0 sh macos/package.sh   # the Mac release: signed app, disk image, update zip, manifest.json
VERSION=0.1.0 sh pc/package.sh      # Windows' zip and Linux's tarballs, added to manifest.json
zig build -Dtarget=x86_64-windows-gnu   # any target from any machine
nix build .#nanolight .#nanolight-server  # the Nix packages (see Nix)
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
| `src/hotkey*.zig`, `src/apps_*.zig`, `src/single*.zig`, `src/login.zig` | Each platform's key, apps, single copy and login item |
| `src/account.zig`, `src/account_menu.zig` | The sync client: `[sync]`, the PUT and merge, the status line |
| `src/server.zig`, `src/settings.zig` | `nanolight-server`: the protocol as a pure function, tokens, atomic records; and the record both sides merge |
| `src/raycast_model.zig`, `src/raycast_view.zig` | The panel's command screen (a script's output, arguments) |
| `src/script_commands.zig`, `src/script_run.zig` | Raycast script commands, run in Zig |
| `src/toml.zig`, `src/config.zig` | `config.toml`: the TOML subset parser, the typed schema and loader, and how the file seeds settings |
| `src/onboard.zig`, `src/shortcut.zig`, `src/recorder.zig` | The welcome, which key is free, recording one's own |
| `flake.nix`, `nix/` | The packages, the NixOS, nix-darwin and home-manager modules, the server module, and the flake's checks |
| `src/film.zig`, `src/stage.zig`, `tools/film.sh` | The walkthrough, rendered offscreen |
| `src/promo.zig`, `src/promo_scene.zig`, `src/promo_camera.zig`, `tools/promo.sh`, `tools/promo/` | The promo: nanoui's shots, Blender's laptops, the Windows and Linux recordings ([docs/promo.md](docs/promo.md)) |

The icon is drawn by `tools/icon.py`. `src/backdrop.jpg` (the film's cover art) was made with OpenAI's image model.

## License

MIT

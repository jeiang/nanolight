<p align="center"><img src="src/icon-256.png" alt="Nanolight's icon" width="96" height="96"></p>

<h1 align="center">Nanolight</h1>
<p align="center"><b>A launcher for the Mac, Windows and Linux, drawn by <a href="https://github.com/justrach/nanoui">nanoui</a>.</b><br>
Apps, math, quicklinks (Google, Claude, Grok, X...) and Raycast script commands: one keystroke away. Native Zig, no Electron, about 2 MB.</p>

<p align="center"><sub>Forked from <a href="https://github.com/justrach/nanolight">justrach/nanolight</a>, built on <a href="https://github.com/justrach/nanoui">nanoui</a>.</sub></p>

<p align="center"><img src="docs/images/nanolight.jpg" alt="Nanolight's panel has found Safari from &quot;saf&quot;" width="760"></p>

## What it does

- **Finds apps as you type**: whole names, starts of words, initials (`ss` is System Settings), letters in order, and typos (`chorme` is Chrome). What you open often climbs. Apps, files and folders (with File Search on), Nanolight's Settings and Clipboard History, System Settings panes and system commands share one **Results** list, ranked by match rather than category; each row still names its kind. Explicit `settings` and `clip` shortcuts stay first. An empty query keeps app **Suggestions**, and calculator/conversion cards stay above local results; quicklinks and Google completions follow them.
- **System Settings panes** (Mac): "login items", "wifi" or "dark mode" lists the pane among the local results, and Return opens System Settings right at it.
- **File search** (Mac, off until **File Search** is on in Settings): files and folders found by name through Spotlight, in your home folder (not `~/Library`, `node_modules`, `.git` or caches), or by path when what you type starts with `/` or `~` (`~/Doc` lists what starts so; Tab completes the selected one). Up to five join the local results and compete by match; a path typed out that exists leads. Return opens it.
- **System commands**: "sleep", "lock", "volume 50" or "dark mode" lists the command among the local results (up to three, leaving room for quicklinks); Return runs it, and a failure's message goes in the footer. They are fixed argument lists run without a shell, and a command whose program is not on the `PATH` is not listed.
  - Mac: Toggle Dark Mode, Set Volume to 0/25/50/75/100%, Mute, Unmute, Sleep (`pmset sleepnow`), Sleep Display (`pmset displaysleepnow`; it does not lock unless System Settings requires the password immediately), Empty Trash. They use `osascript` and `pmset`; the first use of Dark Mode or Empty Trash asks for permission to control System Events or Finder.
  - Linux: volume and mute through `wpctl`, or `pactl` when there is no `wpctl`; Sleep (`systemctl suspend`); Lock Screen (`loginctl lock-session`); Dark Mode and Light Mode (`gsettings`, GNOME's `color-scheme`).
  - Windows: Sleep (`rundll32 powrprof.dll,SetSuspendState 0,1,0`, which hibernates instead when hibernation is on) and Lock Screen (`rundll32 user32.dll,LockWorkStation`). There is no volume: Windows has no built-in command for it without a third-party tool.
- **Completes inline**: the rest of the top app's name, or of Google's top suggestion, is drawn faintly after the caret. Tab or → takes it; Return never does.
- **Does math**: `2^10 * 3` answers 3,072 (and `0xC00`). Return copies it. An operator with nothing after it yet (`2 + 3 *`, `500 usd to eur *`) keeps the answer so far, so the card stays while you type.
- **Converts units and currencies**: `10 km to mi`, `10km in miles`, `32 f to c`, `1.5 GiB in MB`, `100 usd to ttd`, `$20 in eur`. Units are length, mass, temperature, volume, area, speed, data (`KB` is 1000 bytes, `KiB` 1024) and time, in any case and spelling (`miles`, `Miles`, `mi`); units of different kinds (`10 m to min`) are not a conversion. Currency codes and `$ € £ ¥` work: the row shows `100 USD = 678.50 TTD` with `1 USD = 6.785 TTD · 2026-11-03` under it, the day the rates are for. Math goes around a conversion: the amount can be any math, parentheses too (`35 * 7 ttd to usd`, `3 * 10 km to mi`, `$20 * 3 in eur`), and operators after the target work on the converted value (`12 ttd to usd * 12`, `10 km to mi / 2`). The row shows the amount worked out (`245 TTD`) and the final answer. Return copies the number. Rates come from [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api) (jsDelivr, then a pages.dev mirror), are fetched the first time a currency conversion is typed and at most once a day, and are cached in `rates.json` in the data folder; with no network the cached table is used even when old (a failed fetch is retried after ten minutes). Nothing else leaves the machine for a conversion, and conversion queries are not sent to Google.
- **Google suggestions**: up to four, under the apps, the words you add in bold. Nothing that reads as an address (a dot, a slash, an @) is sent.
- **Results in the panel**: Return on a search shows Google's page in the panel itself. Esc closes it and the panel, ⌘↩ opens it in your browser, ⌘[ goes back a page. Prefer the browser? Turn on **Open Searches in Browser** in Settings: Return opens your browser, and ⌘↩ shows the page in the panel.
- **Quicklinks**: web searches under the apps, from `[[quicklinks]]` in `config.toml` (`{argument}` is where what you typed goes, URL-escaped). The built-in ones are Google (the first row, a search for what you typed), DuckDuckGo (`ddg`), Claude, Grok and X; the first five are listed, and any others answer to their `keyword`. `ddg liquid glass` runs only DuckDuckGo. A URL without `{argument}` opens as it is; only `http` and `https` addresses are accepted. Google's suggestions stay with the quicklink whose address is Google's, and are not shown without one. Return, ⌘↩ and the in-panel page work for every quicklink.
- **Raycast script commands** ([raycast/script-commands](https://github.com/raycast/script-commands), MIT): any script with `@raycast.*` comments, dropped in the Script Commands folder, is a row. Nanolight runs it itself: its arguments as a form, its output as it prints (`fullOutput`), its last line (`compact`), or nothing (`silent`).
- **Clipboard history** (Mac, Windows, and Linux on X11 or a Wayland compositor with data-control): "clip" or "clipboard" lists **Clipboard History**. Everything you copy (text, images, files) is kept for a week, newest first, with its type, the app it came from and when. Type to search it (text, file names, apps); Return pastes the entry as plain text into the app you came from, ⌘↩ copies it only, ⌘⌫ deletes it, Esc closes it and the panel. See [Clipboard history](#clipboard-history).
- **Settings in the panel**: ⌘, (Ctrl+, on a PC), the gear in the footer, or type "settings". The swatches in its header tint the panel (System, Ocean, Forest, Rose, Amber, Violet); ←/→ step through them.
- **⌘1–⌘9** run a row at once; ↑ ↓, ⌃N ⌃P and ⌃J ⌃K move (also in Settings and script screens; on a PC a script's actions are on Ctrl+O, since Ctrl+K moves up). After the panel has been hidden longer than `pop_to_root_seconds` (default 90, `0` = never) it reopens at the root: empty query, first row, no Settings or script screen.
- **Config file**: `config.toml` seeds the settings (see [Configuration](#configuration)).
- On the Mac it lives in the menu bar: no Dock icon, and nothing drawn while it's idle. **Show in Menu Bar** in Settings hides the icon; Settings stays a ⌘, away in the panel.

## Clipboard history

On the Mac, Nanolight keeps what you copy: text, images (as PNG) and files (their paths). The screen opens from the **Clipboard History** row (type `clip`); it has a search field, the entries newest first with a type label, the source app and the time, and the selected entry's first lines, image size or file paths under the list. It keeps entries for `retention_days` (7) and at most `max_entries` (1000), pruned at launch and every hour (`0` turns a limit off); copying the same thing again makes it the newest entry and counts it. Whatever those say, the history never holds more than 256 MiB of content in all: past that the oldest entries go first, as a copy is added and at each prune. A single item over 10 MiB of text or 20 MiB of image is not kept (the log says so).

- **Return** writes the entry to the pasteboard (as plain text only, for text; an image as PNG; files as file URLs), hides the panel, brings back the app that was in front when the panel opened, and sends it ⌘V. **⌘↩** (Ctrl+Enter) only copies, **⌘⌫** (Ctrl+Backspace, or ⌘D / Ctrl+D, the only one Windows offers) deletes, **Esc** closes the screen and the panel. With `paste_plain_text = false` Return only copies.
- **Accessibility**: sending ⌘V needs Nanolight in System Settings → Privacy & Security → Accessibility. The first paste without it asks once (the system's prompt) and copies the entry instead, and the footer says so. macOS ties the grant to the app's code signature: the release app keeps it across updates, but a Nix build is signed ad hoc and loses it on each rebuild unless the nix-darwin module's `codesignIdentity` is set (see [Nix](#nix)).
- **Privacy**: history lives only on this computer, in `clipboard/` in the data folder (`index.json`, and `blobs/` for images and long texts). It is never synced, never sent anywhere, and not in the config sync. Nothing is read or kept from the apps in `exclude_apps` (macOS bundle IDs; the password managers Bitwarden and Yubico Authenticator by default), or from anything that marks what it copied as concealed, transient or auto-generated (`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`, which password managers set). Turn it off with **Record Copied Items** in Settings, or `enabled = false` under `[clipboard]`: nothing is stored and the pasteboard is not even watched. The file's `enabled` seeds the switch like the other settings: a file that leaves it out, or a line removed later, keeps whatever the switch says (on, until it is turned off). If the switch cannot be saved, turning it on does nothing and turning it off stops recording until Nanolight quits (the log says so); if it cannot be read, history is off. A history already kept stays until **Clear History** in Settings (or until it ages out); if something could not be deleted, the button says **Could Not Clear History** and the log says what. A damaged `index.json` is deleted and the history starts empty.
- The pasteboard is polled twice a second on the main run loop; what Nanolight writes itself is not recorded again.
- **Windows**: the same screen and keys, with Ctrl+V and Ctrl+Enter in place of ⌘. `GetClipboardSequenceNumber` is polled twice a second. Text (`CF_UNICODETEXT`), images (`CF_DIB` or `CF_DIBV5`, kept as PNG; 24 and 32 bits only) and files (`CF_HDROP`) are read. Nothing is kept when the app that copied it sets `ExcludeClipboardContentFromMonitorProcessing` or `CanIncludeInClipboardHistory` to 0 (password managers do), or when its exe name is in `exclude_apps` (for example `Bitwarden.exe`; the source is the clipboard owner's process, or the foreground window's when there is no owner). Return writes the entry (text as `CF_UNICODETEXT` only, an image as `CF_DIB` with transparency laid over white, files as `CF_HDROP`), hides the panel, brings back the window that was in front and sends it Ctrl+V with `SendInput`. Windows does not deliver that to a window running as administrator, so the entry is then only copied.
- **Linux**: the same screen and keys, with Ctrl+V and Ctrl+Enter. Which side runs is picked when history starts: Wayland if `WAYLAND_DISPLAY` is set and the compositor offers `ext-data-control-v1` (or `zwlr_data_control_manager_v1`), otherwise X11 if `DISPLAY` is set, otherwise the screen says history is unavailable.
  - **Wayland** (sway, Hyprland, niri, KDE Plasma, river and other wlroots-style compositors; **GNOME has no data-control protocol**, so history cannot watch it there). Text (`text/plain;charset=utf-8`), images (`image/png`) and files (`text/uri-list`, `file:` URIs only) are read through pipes, in the background. A copy that carries `x-kde-passwordManagerHint` = `secret` is dropped. Wayland says nothing about the app that copied, so the source is blank and **`exclude_apps` cannot apply on Wayland**. Return serves the entry as the selection, hides the panel, and sends Ctrl+V through a virtual keyboard (`zwp_virtual_keyboard_manager_v1`, which most wlroots compositors and Plasma offer); when it is missing, the entry is only copied and the footer says so. The selection is served by Nanolight, so it is gone when Nanolight quits.
  - **X11** (and XWayland): XFixes reports each change of the CLIPBOARD owner, and the copy is read from it (UTF-8 text, `image/png`, `text/uri-list`; INCR transfers too). The source is the owner window's `WM_CLASS` (for example `KeePassXC`), which is what `exclude_apps` matches, any case; an owner with no `WM_CLASS` (GTK3 and Qt apps) is named by its `WM_NAME` (Qt's "Qt Selection Owner for " prefix dropped), else its source is blank. Return makes Nanolight's hidden window the owner (answering requests as long as it is, large entries in INCR pieces) and sends Ctrl+V with XTest once the panel has gone. Needs libX11, libXfixes and libXtst (XTest missing: copy only). Where only XWayland is reachable (a Wayland session without data-control, with `DISPLAY` set), history sees X11 clients only: native Wayland apps' copies are not seen, and the pasted keys reach X11 windows only.
  - What Nanolight writes itself is not recorded again. The Linux watcher runs on GTK's main loop through the sockets and pipes; it never blocks the panel (a source that does not answer in 2 to 3 seconds is skipped).

## Sync across computers (optional)

Off until `[sync]` in `config.toml` names a server you run (`nanolight-server`, below). Every computer that uses the same account's token shares:

- the key that opens Nanolight,
- whether Google suggestions are on,
- the quicklinks (the panel shows what the config or sync last set; the later change wins),
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

On the Mac the app's Info.plist sets `NSAllowsArbitraryLoads`, because App Transport Security would otherwise refuse plain `http://` to a hostname (IP addresses are exempt) and `NSAllowsLocalNetworking` does not cover a mesh hostname. The trade-off: ATS no longer blocks any plain `http://` request the Mac app makes, not only sync's.

The token is read only from that file; there is no in-app token entry and nothing goes to a keychain.

## Configuration

Nanolight reads `config.toml` at launch, from the first of these that exists: `$NANOLIGHT_CONFIG`; Nanolight's data folder, next to `script-commands` (`~/Library/Application Support/Nanolight` on the Mac, `%APPDATA%\Nanolight` on Windows, `~/.local/share/Nanolight` on Linux); `$XDG_CONFIG_HOME/nanolight/config.toml` (else `~/.config/nanolight/config.toml`, on the Mac too; home-manager writes it); `/etc/nanolight/config.toml` (the NixOS and nix-darwin modules write it). A launch without `NANOLIGHT_CONFIG` (Spotlight, `nanolight --toggle`) therefore still finds a Nix-managed file. No file means the defaults. A file that fails to parse is logged to stderr with its line number and ignored; nothing else breaks. If a config file was applied before and none can be found now, Nanolight does not guess: it prunes nothing and records no clipboard history until a file is found again, and logs why.

The file seeds the settings and the app's own changes win. Nanolight remembers the last value it applied from each key, and applies a key only when the file's value differs from that: edit `hotkey` in the file and the new key takes over (and syncs, as a change made just now); leave it alone and a key chosen in Settings stays. A key you delete from the file leaves the app's value as it is. `hotkey` is a preset name (`cmd_space`, `opt_space`, `ctrl_space`, `opt_cmd_space`) or, on the Mac only, a recorded `key:<code>:<mods>:<char>`; anything else is logged and ignored. On a PC the presets are the keys named under first run below: `cmd_space` is Alt Space, `opt_space` Ctrl Alt Space, `ctrl_space` Ctrl Space, `opt_cmd_space` Ctrl Shift Space.

```toml
hotkey = "cmd_space"          # keys.Choice name or recorded "key:..."; default per OS as keys.zig has it (Alt Space off the Mac)
suggestions = true            # Google completions
open_searches_in_browser = false
show_in_menu_bar = true
pop_to_root_seconds = 90      # 0 = never

[apps]
extra_dirs = []               # scanned like /Applications (depth 1)

[script_commands]
dirs = []                     # in addition to <data dir>/script-commands; relative paths are relative to this file

[[quicklinks]]                # if any are given, they replace the defaults
name = "DuckDuckGo"
url = "https://duckduckgo.com/?q={argument}"
keyword = "ddg"               # optional

[clipboard]
enabled = true               # leave out to keep the app's own switch (on by default)
retention_days = 7
max_entries = 1000
paste_plain_text = true       # Return pastes as plain text (vs copy only when false or unsupported)
exclude_apps = ["com.bitwarden.desktop", "com.yubico.yubioath"]  # mac bundle IDs, Windows exe names, Linux app IDs

[sync]
url = ""                      # e.g. "http://100.x.y.z:8890"; empty = off
token_file = ""               # file holding the bearer token (sops path under Nix)
```

Today `hotkey`, `suggestions`, `open_searches_in_browser`, `show_in_menu_bar`, `[apps] extra_dirs`, `[script_commands] dirs` and `[sync]` take effect. `[[quicklinks]]` take effect too. `pop_to_root_seconds` takes effect too; `[clipboard]` takes effect on the Mac and Windows (see [Clipboard history](#clipboard-history)); on Linux it takes effect on X11 and on Wayland compositors with data-control. A key of the wrong type fails the file; an unknown key is logged and ignored. The parser (`src/toml.zig`) is TOML 1.0 without datetimes, and reads what Nix's `pkgs.formats.toml` writes.

When the file sets `hotkey`, the welcome skips its key and login steps.

## Install

From the [latest release](https://github.com/jeiang/nanolight/releases/latest):

- **Mac**: `nanolight-macos-arm64.dmg`. Open it and drag Nanolight to Applications. macOS 14 or later, Apple silicon.
- **Windows**: `nanolight-windows-x86_64.zip`. Unzip it anywhere you can write and run `nanolight.exe`. Windows 10 or later.
- **Linux**: `nanolight-linux-x86_64.tar.gz` (or `aarch64`). Unpack it and run `nanolight`. It needs GTK 3 (or 4) and an X11 session for its key; on Wayland, bind `nanolight --toggle` to a key in your desktop's keyboard settings.

On first run a short welcome picks the key that opens it and says who else holds it. On the Mac that's ⌘Space, ⌥Space, ⌃Space or ⌥⌘Space (any other, such as ⌥X, can be recorded later in Settings; Spotlight gives up ⌘Space in System Settings → Keyboard → Keyboard Shortcuts → Spotlight); on a PC, Alt Space, Ctrl Alt Space, Ctrl Space or Ctrl Shift Space. After the welcome, launching Nanolight leaves it in the background until that key or the menu bar icon opens the panel. Releases signed with a Developer ID update themselves from this repository's releases, restarting into the new version while the panel is away, and keep the Accessibility grant; an ad-hoc-signed release (published when the repository has no Apple signing secrets) is refused by the updater, so reinstall it by hand and grant Accessibility again. (A build made with `-Dnix=true` never does.)

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
      token_file = config.sops.secrets.nanolight-token.path;  # needs sops.secrets.nanolight-token.owner = config.system.primaryUser
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
    settings.hotkey = "opt_space";
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

The flake commits its `flake.lock`. Hosts need `nix-command flakes`. `nix flake check` builds the app (running `zig build test`), the server and a NixOS VM test of the server, and evaluates a NixOS configuration with both modules; the nix-darwin and home-manager modules are evaluated against stand-ins for the options they set.

## Build

You need the Zig that `build.zig.zon` names (`minimum_zig_version`) and Xcode or the Command Line Tools.

```sh
zig build test      # search, math, suggestions and the panel, through nanoui's Tester
zig build run       # build and open it
zig build app       # zig-out/Nanolight.app, for /Applications
zig build server    # zig-out/bin/nanolight-server, the sync server
zig build package -Dversion=0.1.0   # a release's files in zig-out/package (a tag, v0.1.0, works too): the Mac's signed app, disk image and update, Windows' zip, Linux's tarballs, each build's debug symbols, manifest.json
zig build -Dtarget=x86_64-windows-gnu   # any target from any machine
nix build .#nanolight .#nanolight-server  # the Nix packages (see Nix)
zig build -Dnix=true                    # a Nix-managed build: no updater, no Open at Login (the Nix modules own startup)
zig build test -Dmac-tools=false        # leaves out the Mac's release tools (verify-*, icon), which need its SDK; the Nix package does
```

`zig build package` signs the Mac's app with `$CODESIGN_IDENTITY` and notarizes it when notary credentials are set (`NOTARY_PROFILE`, or `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`; see `tools/package.zig`); otherwise it signs ad hoc. The Mac's part needs a Mac; Windows' and Linux' archives build anywhere. Every program ships stripped, and its debug symbols ride beside it (`nanolight-*-symbols.*`: a dSYM, a PDB, ELF debug files) so that a crash can be read. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds, signs and attaches the release as a prerelease, then checks it end to end before it becomes the latest: `zig build verify-release -- v0.2.7` checks a published release's files, its notarization and that it runs headless (safe on your Mac); `zig build verify-update -- v0.2.6 v0.2.7` launches it for real and updates the release before to it (CI only: it shows windows and presses keys, as does `zig build verify-typing`).

## How it's made

| File | What |
| --- | --- |
| `src/main.zig` | The app: the window, the hot key, the menu bar icon, updates |
| `src/view.zig` | The panel: query, rows, footer, keys |
| `src/results.zig` | What a query lists, in order |
| `src/search.zig` | Fuzzy matching and ranking, allocation-free |
| `src/calc.zig` | The calculator |
| `src/convert.zig` | Unit and currency conversion: the parser, unit table, rates table and when to refetch it |
| `src/suggest.zig` | Google's completions: the privacy guard, decoding, the cache (after [browse](https://github.com/justrach/browse)) |
| `src/preview.zig` | The results page in the panel (WKWebView, the Mac) |
| `src/platform.zig` | Each OS's parts, picked once, and what it can do; `src/pc_stubs.zig` stands in for the Mac's, checked against them |
| `src/panel_mac.zig`, `src/panel_pc.zig` | The panel's window on the Mac, and on Windows and Linux (with X11's focus) |
| `src/hotkey*.zig`, `src/apps_*.zig`, `src/single*.zig`, `src/login.zig` | Each platform's key, apps, single copy and login item |
| `src/account.zig`, `src/account_menu.zig` | The sync client: `[sync]`, the PUT and merge, the status line |
| `src/server.zig`, `src/settings.zig` | `nanolight-server`: the protocol as a pure function, tokens, atomic records; and the record both sides merge |
| `src/raycast_model.zig`, `src/raycast_view.zig` | The panel's command screen (a script's output, arguments) |
| `src/script_commands.zig`, `src/script_run.zig` | Raycast script commands, run in Zig |
| `src/clipboard.zig` | Clipboard history: the model, the store on disk, retention, search, and the per-OS `Watcher` seam |
| `src/clipboard_mac.zig`, `src/clipboard_win.zig`, `src/clipboard_linux.zig` | Each OS's watcher and paste: the Mac's NSPasteboard poll and ⌘V; Windows' clipboard sequence poll, DIB-to-PNG and Ctrl+V; Linux's X11 (XFixes, XTest) and Wayland (data-control, virtual keyboard) sides, with the shared read plan and served formats (`clipboard_x11.zig`, `clipboard_wl.zig`); `zig build clip-probe` runs them without the panel |
| `src/clipboard_view.zig`, `src/clipboard_live.zig` | The Clipboard History screen, and the app's side of it (the store, the watcher, Return and ⌘↩) |
| `src/commands.zig` | System commands: each OS's table, the `PATH` check, ranking, the runner |
| `src/toml.zig`, `src/config.zig` | `config.toml`: the TOML subset parser, the typed schema and loader, and how the file seeds settings |
| `src/keys.zig`, `src/shortcut.zig` | The key that opens the panel as a value (the four offered, kept names, Carbon and AppKit codes), and how it reads |
| `src/onboard.zig`, `src/shortcut_clash.zig`, `src/recorder.zig` | The welcome, which key is free, recording one's own |
| `flake.nix`, `nix/` | The packages, the NixOS, nix-darwin and home-manager modules, the server module, and the flake's checks |

The icon is drawn by `tools/icon.zig` (`zig build icon`, on a Mac). The release tools are Zig too, in `tools/`, run as `zig build` steps.

Zig code follows [TigerStyle](docs/TIGER_STYLE.md), as its first section applies it, and
`zig build lint` checks the rules a machine can.

## License

MIT

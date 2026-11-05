#!/bin/sh
# What macos/verify-release.sh can't check headless, on a CI runner: the
# release used as a person uses it, from a clean Mac (the welcome; the hotkey,
# a search, opening an app and a System Settings pane), the release before
# it updating itself to this one and coming back, and a feed that lies being
# refused.
#
#   sh macos/verify-update.sh v0.2.6 v0.2.7
#
# It presses keys, shows windows, resets the app's settings and replaces
# /Applications/Nanolight.app, so it runs only where CI is set. A launcher
# started with `open` gets the environment `open --env` gives it, so the new
# copy, restarted by the updater, reads the real feed: TO must be the newest
# release, or it would update again. SHOTS is where its screenshots go.
#
# Its hotkey is ⌃⌥⌘N, a key of its own: on a clean Mac Spotlight answers ⌘Space
# too, and takes the keys typed after it.
set -eu
here=$(cd "$(dirname "$0")" && pwd -P)
[ "${CI:-}" = true ] || {
    echo "verify-update.sh presses keys and replaces the installed app: CI runners only" >&2
    exit 2
}

from=${1:?usage: sh macos/verify-update.sh vOLD vNEW}
to=${2:?usage: sh macos/verify-update.sh vOLD vNEW}
from_version=${from#v}
to_version=${to#v}
releases=https://github.com/jeiang/nanolight/releases/download
asset=nanolight-macos-arm64.zip
app=/Applications/Nanolight.app
bin="$app/Contents/MacOS/nanolight"
cache="$HOME/Library/Caches/Nanolight"
domain=dev.nanoui.nanolight
team=WWP9DLJ27P
port=8765
chord=key:45:6400:110
shots=${SHOTS:-/tmp/nanolight-shots}
mkdir -p "$shots"

work=$(mktemp -d /tmp/nanolight-update.XXXXXX)
work=$(cd "$work" && pwd -P)
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; pkill -f "^$bin" 2>/dev/null; rm -rf "$work"' EXIT
cd /

die() {
    {
        echo "FAIL  $*"
        if [ -s "$work/app.log" ]; then
            echo "--- the app's log"
            tail -20 "$work/app.log"
        fi
        crashes=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/*anolight* 2>/dev/null | head -1 || true)
        if [ -n "$crashes" ]; then
            echo "--- $crashes"
            head -60 "$crashes"
        fi
    } >&2
    shot failed
    exit 1
}
ok() { echo "ok    $*"; }
shot() { screencapture -x "$shots/$(sw_vers -productVersion)-$1.png" 2>/dev/null || true; }

running() { pgrep -f "^$bin" 2>/dev/null | head -1 || true; }
installed() { plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"; }

stop() {
    pkill -f "^$bin" 2>/dev/null || true
    n=0
    while [ -n "$(running)" ] && [ "$n" -lt 20 ]; do
        sleep 0.5
        n=$((n + 1))
    done
    [ -z "$(running)" ] || die "the app won't stop"
}

zip_of() { # tag: its update, fetched once
    z="$work/$1.zip"
    [ -f "$z" ] || curl -fsSL --retry 3 -o "$z" "$releases/$1/$asset"
    echo "$z"
}

install() { # tag, as a person drags it to Applications, on a clean Mac
    stop
    rm -rf "$app" "$cache"
    defaults delete "$domain" 2>/dev/null || true
    defaults write "$domain" nanolight.hotkey -string "$chord"
    t=$(mktemp -d "$work/unpack.XXXXXX")
    ditto -x -k "$(zip_of "$1")" "$t"
    ditto "$t/Nanolight.app" "$app"
    rm -rf "$t"
    [ "$(installed)" = "${1#v}" ] || die "installed $(installed), not $1"
}

# Someone past the welcome, as nearly everyone an update reaches is.
returning() { defaults write "$domain" nanolight.onboarded -string 1; }

launch() { # the feed it reads
    open --stderr "$work/app.log" --env "NANOUI_UPDATE_FEED=$1" "$app"
    n=0
    while [ -z "$(running)" ]; do
        n=$((n + 1))
        [ "$n" -le 60 ] || die "it never started"
        sleep 0.5
    done
    running
}

trusted() { # the app's copy in Applications, as the system sees it
    codesign --verify --deep --strict "$app" || die "signature broken"
    codesign -dv --verbose=2 "$app" 2>&1 | grep -q "TeamIdentifier=$team" || die "not signed by $team"
    a=$(spctl -a -vvv -t exec "$app" 2>&1) || die "Gatekeeper: $a"
    echo "$a" | grep -q 'source=Notarized Developer ID' || die "Gatekeeper: $a"
    try=1
    until xcrun stapler validate "$app" >/dev/null 2>&1; do
        [ "$try" -lt 5 ] || die "no ticket stapled"
        sleep $((try * 10))
        try=$((try + 1))
    done
}

# The panel's windows on screen: not the menu bar icon's, which is short.
panels="$work/panels"
cat >"$work/panels.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(all.filter {
    ($0["kCGWindowOwnerName"] as? String)?.lowercased() == "nanolight"
        && ((($0["kCGWindowBounds"] as? [String: Any])?["Height"] as? NSNumber)?.doubleValue ?? 0) > 60
}.count)
SWIFT
swiftc -o "$panels" "$work/panels.swift"

see_panels() { # how many, what that means
    n=0
    until [ "$("$panels")" = "$1" ]; do
        n=$((n + 1))
        [ "$n" -le 40 ] || die "$2: $("$panels") on screen, not $1"
        sleep 0.25
    done
    ok "$2"
}

keys() { osascript -e "tell application \"System Events\" to $1" >/dev/null || die "couldn't press keys: $1"; }
hotkey() { keys 'key code 45 using {control down, option down, command down}'; }
ret() { keys 'key code 36'; }
frontmost() { osascript -e 'tell application "System Events" to name of first process whose frontmost is true'; }
pane_title() { osascript -e 'tell application "System Events" to name of window 1 of process "System Settings"' 2>/dev/null || true; }

opened() { # the app a search's Return should have opened
    n=0
    until pgrep -x "$1" >/dev/null; do
        n=$((n + 1))
        [ "$n" -le 40 ] || die "$1 never opened"
        sleep 0.25
    done
    ok "Return opened $1"
}

# ----- a clean Mac's first launch -----

echo "== $to, first launch"
install "$to"
pid=$(launch "$releases/$to")
see_panels 1 "the welcome is on screen"
# Past the first update check (20 s), which finds nothing newer.
sleep 25
shot first-launch
[ "$(running)" = "$pid" ] || die "$to died within 25 s of its first launch"
[ "$(installed)" = "$to_version" ] || die "$to replaced itself with $(installed)"
trusted
ok "$to launches from a clean install and stays up"

# The welcome's steps, as a new person goes through them.
ret
sleep 1.5
shot welcome-try-it
hotkey
see_panels 0 "the welcome's hotkey step: it closes"
hotkey
see_panels 1 "the welcome's hotkey step: it opens again"
sleep 2
shot welcome-done
ret
n=0
until [ "$(defaults read "$domain" nanolight.onboarded 2>/dev/null || true)" = 1 ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || die "Return didn't finish the welcome"
    sleep 0.25
done
sleep 1
shot welcome-finished
ok "the welcome finishes"

# ----- used as a person uses it -----

echo "== $to, used"
install "$to"
returning
pid=$(launch "$releases/$to")
see_panels 1 "launching shows the panel"
hotkey
see_panels 0 "the hotkey hides it"
hotkey
see_panels 1 "the hotkey shows it"
sleep 0.5
SHOTS="$shots" EXPECT="${TYPING_EXPECT:-clean}" sh "$here/verify-typing.sh" || die "typing (#24)"
keys 'keystroke "calculator"'
sleep 1
shot used-search
sleep 3
shot used-search-later
ret
opened Calculator
see_panels 0 "the panel goes as the app opens"
pkill -x Calculator || true
hotkey
see_panels 1 "the hotkey shows it again"
sleep 0.5
keys 'keystroke "login items"'
sleep 1
shot used-pane-search
ret
opened "System Settings"
n=0
until case "$(pane_title)" in *Login*) true ;; *) false ;; esac do
    n=$((n + 1))
    [ "$n" -le 40 ] || die "System Settings opened at \"$(pane_title)\", not Login Items"
    sleep 0.5
done
shot used-pane
ok "System Settings opened at \"$(pane_title)\""
pkill -x "System Settings" || true
[ "$(running)" = "$pid" ] || die "$to died while being used"
ok "$to is still up"

# ----- a feed that lies -----

# Writes a feed's manifest: dir, the version it claims, its sha256 (or "right").
feed_of() {
    sum=$3
    [ "$sum" != right ] || sum=$(shasum -a 256 "$1/$asset" | cut -d' ' -f1)
    printf '{"version":"%s","files":{"%s":{"sha256":"%s"}}}\n' "$2" "$asset" "$sum" >"$1/manifest.json"
}

serve() { # dir
    python3 -I -u -c '
import http.server, socketserver, sys
class Server(http.server.HTTPServer):
    # HTTPServer looks its own name up, and on macOS 26 that has the system
    # ask whether Python may use the local network, over the app under test.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
class Files(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=sys.argv[2], **k)
Server(("127.0.0.1", int(sys.argv[1])), Files).serve_forever()
' "$port" "$1" >"$work/server.log" 2>&1 &
    server=$!
    sleep 1
}

offer() { # dir: the older copy reads that feed, and fetches what it offers
    install "$from"
    serve "$1"
    pid=$(launch "http://127.0.0.1:$port")
    n=0
    until grep -q "GET /$asset" "$work/server.log"; do
        n=$((n + 1))
        [ "$n" -le 120 ] || {
            cat "$work/server.log"
            die "$from never asked for the update"
        }
        sleep 1
    done
    # Time to verify it, and for a restart (10 s away) if it took it.
    sleep 25
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    server=
}

refused() { # what's wrong, dir. A release newer than anything: the only thing
    # that could change this copy is this feed.
    echo "== $from refuses: $1"
    offer "$2"
    [ "$(installed)" = "$from_version" ] || die "took a bad update ($1): installed $(installed)"
    [ "$(running)" = "$pid" ] || die "$from restarted or died on a bad update ($1)"
    # What it refuses it deletes; what it takes waits here, even in sight.
    [ ! -e "$cache/updates/99.0.0" ] || die "kept a bad update ($1) in its cache"
    ok "$from refused it, and kept nothing"
}

# The control: the same road, told the truth. Without it, a feed that nothing
# could get through would pass every refusal above.
echo "== $from takes the same feed, told the truth"
truth="$work/feed-truth"
mkdir "$truth"
cp "$(zip_of "$to")" "$truth/$asset"
feed_of "$truth" "$to_version" right
offer "$truth"
[ -e "$cache/updates/$to_version/unpacked/Nanolight.app" ] || [ "$(installed)" = "$to_version" ] ||
    die "it took nothing from a good feed: refusals here prove nothing"
ok "$from took it"

sums="$work/feed-sum"
mkdir "$sums"
cp "$(zip_of "$to")" "$sums/$asset"
feed_of "$sums" 99.0.0 0000000000000000000000000000000000000000000000000000000000000000
refused "a checksum that doesn't match" "$sums"

names="$work/feed-name"
mkdir "$names"
cp "$(zip_of "$to")" "$names/$asset"
feed_of "$names" 99.0.0 right
refused "a real build that isn't the version named" "$names"

other="$work/feed-other"
mkdir "$other"
t=$(mktemp -d "$work/unpack.XXXXXX")
ditto -x -k "$(zip_of "$to")" "$t"
plutil -replace CFBundleShortVersionString -string 99.0.0 "$t/Nanolight.app/Contents/Info.plist"
codesign --force --deep --sign - "$t/Nanolight.app"
ditto -c -k --keepParent "$t/Nanolight.app" "$other/$asset"
rm -rf "$t"
feed_of "$other" 99.0.0 right
refused "a build not signed by the team" "$other"

# ----- the update -----

swapped() { # the copy updating, how long it may take
    start=$(date +%s)
    until [ "$(installed 2>/dev/null || true)" = "$to_version" ]; do
        [ $(($(date +%s) - start)) -le "$2" ] || die "still $(installed) after $2 s"
        [ -n "$(running)" ] || die "$from died before updating"
        sleep 2
    done
    ok "swapped in $to after $(($(date +%s) - start)) s"
    n=0
    until new=$(running) && [ -n "$new" ] && [ "$new" != "$1" ]; do
        n=$((n + 1))
        [ "$n" -le 60 ] || die "$to didn't come back after the update"
        sleep 1
    done
    ok "came back on its own, as $to"
}

settled() { # what must be true of an update that's done
    # Past its own first update check: it must not update, or restart, again.
    sleep 30
    [ "$(running)" = "$new" ] || die "$to died or restarted after updating"
    [ "$(installed)" = "$to_version" ] || die "went on to $(installed) after updating"
    [ "$("$bin" --version)" = "nanolight $to_version" ] || die "the program says $("$bin" --version)"
    trusted
    [ -z "$(xattr -r "$app" 2>/dev/null | grep com.apple.quarantine)" ] || die "the update came quarantined: macOS would ask on its next launch"
    [ -z "$(ls -A /Applications | grep '^\.Nanolight')" ] || die "left copies in Applications: $(ls -A /Applications | grep '^\.Nanolight')"
    [ ! -e "$cache/updates/$to_version" ] || die "left the update in its cache"
    ok "the update is notarized, unquarantined, and left nothing behind"
}

# The update nearly everyone gets: the panel put away, another app in front.
# Out of sight 10 s after it's fetched (20 s after launch), it restarts then,
# and nobody sees it.
echo "== $from updates itself to $to, panel put away"
install "$from"
returning
old=$(launch "$releases/$to")
see_panels 1 "launching shows the panel"
hotkey
see_panels 0 "the hotkey hides it"
echo "      with the panel hidden, in front: $(frontmost)"
# With nothing else taking the front yet: does it go by itself?
n=0
while [ "$n" -lt 25 ] && [ "$(installed 2>/dev/null || true)" != "$to_version" ]; do
    n=$((n + 1))
    sleep 2
done
if [ "$(installed 2>/dev/null || true)" != "$to_version" ]; then
    echo "      not updated after 50 s with the panel hidden; now another app comes in front"
    osascript -e 'tell application "Finder" to activate' >/dev/null
    sleep 1
    echo "      in front: $(frontmost)"
fi
swapped "$old" 90
settled
see_panels 0 "it came back out of sight"
front=$(frontmost)
case $front in
[Nn]anolight) die "it came back in front" ;;
esac
hotkey
see_panels 1 "the updated copy's hotkey shows the panel"
sleep 1
shot updated
ok "$to answers its hotkey"

# Left open, on the welcome: in sight, it waits for nobody to be at the Mac (5
# minutes with no input), and comes back as it was.
echo "== $from updates itself to $to, left open"
install "$from"
old=$(launch "$releases/$to")
see_panels 1 "the welcome is on screen"
swapped "$old" 480
settled
see_panels 1 "it came back where it was"
shot updated-left-open
echo
echo "$from -> $to: all checks passed"

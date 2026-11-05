#!/bin/sh
# Checks a published release as someone who downloads it gets it: fetches
# the files from the release, and checks the update feed agrees with them,
# that Apple's ticket is stapled to each, that Gatekeeper takes them with the
# quarantine a browser leaves, and that the signed app runs and draws.
#
#   sh macos/verify-release.sh v0.2.7
#
# BASE overrides where the files come from (file:///..., to prove a bad
# release fails). Safe on a developer's Mac: files stay in a temporary
# directory, the app runs only headless (--nanoui-snapshot, never a window;
# it reads this Mac's settings, and writes none), and what's quarantined is
# assessed, never run.
# macos/verify-update.sh does what this can't: launches and updates for real.
set -eu

tag=${1:?usage: sh macos/verify-release.sh vX.Y.Z}
version=${tag#v}
# The team every release is signed by; the updater refuses any other.
team=WWP9DLJ27P
base=${BASE:-https://github.com/jeiang/nanolight/releases/download/$tag}
macos_zip=nanolight-macos-arm64.zip
dmg=nanolight-macos-arm64.dmg
pc="nanolight-windows-x86_64.zip nanolight-linux-x86_64.tar.gz nanolight-linux-aarch64.tar.gz"

work=$(mktemp -d /tmp/nanolight-verify.XXXXXX)
work=$(cd "$work" && pwd -P)
dl="$work/dl"
mnt="$work/mnt"
mkdir "$dl" "$mnt" "$work/home" "$work/zip" "$work/installed"
trap 'hdiutil detach "$mnt" -quiet -force 2>/dev/null; rm -rf "$work"' EXIT
cd /

fails=0
check() {
    name=$1
    shift
    if out=$("$@" 2>&1); then
        echo "ok    $name"
    else
        echo "FAIL  $name"
        printf '%s\n' "$out" | sed 's/^/      /'
        fails=$((fails + 1))
    fi
}

# ----- what each check asks -----

sum_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

manifest() { # version | the sha256 of a file
    python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["version"] if sys.argv[2] == "version" else m["files"][sys.argv[2]]["sha256"])
' "$dl/manifest.json" "$1"
}

feed_version() { [ "$(manifest version)" = "$version" ] || { echo "manifest says $(manifest version)"; return 1; }; }

feed_sum() {
    want=$(manifest "$1") && got=$(sum_of "$dl/$1") && [ "$want" = "$got" ] || { echo "manifest $want, file $got"; return 1; }
}

side_sum() { # the .sha256 published beside a file
    want=$(cut -d' ' -f1 "$dl/$1.sha256") && got=$(sum_of "$dl/$1") && [ "$want" = "$got" ] || { echo ".sha256 $want, file $got"; return 1; }
}

# Asking for the ticket goes through Apple's CloudKit, which drops the
# connection now and then (error 68): a few tries, as package.sh.
stapled() {
    try=1
    until xcrun stapler validate "$1"; do
        [ "$try" -lt "${STAPLE_TRIES:-5}" ] || return 1
        sleep $((try * 10))
        try=$((try + 1))
    done
}

# "accepted" alone would pass on a Mac with Gatekeeper turned off.
notarized() { # spctl's arguments
    out=$(spctl -a -vvv "$@" 2>&1) || { echo "$out"; return 1; }
    echo "$out" | grep -q 'source=Notarized Developer ID' && echo "$out" | grep -q "($team)" || { echo "$out"; return 1; }
}

signed() { # strict signature, this team, hardened, timestamped
    codesign --verify --deep --strict "$1" || return 1
    info=$(codesign -dv --verbose=2 "$1" 2>&1)
    for want in "TeamIdentifier=$team" "flags=.*runtime" "Timestamp="; do
        echo "$info" | grep -q "$want" || { echo "no $want in:"; echo "$info"; return 1; }
    done
}

says_version() {
    got=$(plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist")
    [ "$got" = "$version" ] || { echo "Info.plist says $got"; return 1; }
}

same_build() { # the disk image's app and the update's are one signed build
    a=$(codesign -dvvv "$1" 2>&1 | grep '^CDHash=') && b=$(codesign -dvvv "$2" 2>&1 | grep '^CDHash=')
    [ -n "$a" ] && [ "$a" = "$b" ] || { echo "$a / $b"; return 1; }
}

for_macos_14() {
    [ "$(lipo -archs "$1")" = arm64 ] || { lipo -archs "$1"; return 1; }
    vtool -show-build "$1" | grep -q 'minos 14.0$' || { vtool -show-build "$1"; return 1; }
}

prints_version() {
    got=$("$1" --version)
    [ "$got" = "nanolight $version" ] || { echo "$got"; return 1; }
}

# Headless, with an alarm: a release that hangs fails instead of waiting.
draws() { # program, PNG
    env HOME="$work/home" CFFIXED_USER_HOME="$work/home" \
        perl -e 'alarm shift; exec @ARGV or die' 60 "$1" "--nanoui-snapshot=$2" || return 1
    w=$(sips -g pixelWidth "$2" | awk '/pixelWidth/ {print $2}')
    [ "${w:-0}" -gt 100 ] && [ "$(wc -c <"$2")" -gt 4096 ] || { echo "$w wide, $(wc -c <"$2") bytes"; return 1; }
}

holds() { # the program the portable updater looks for in its archive
    case $1 in
    *.zip) unzip -l "$dl/$1" | grep -q "nanolight-$version-windows-x86_64/nanolight.exe$" ;;
    *x86_64*) tar -tzf "$dl/$1" | grep -q "^nanolight-$version-linux-x86_64/nanolight$" ;;
    *) tar -tzf "$dl/$1" | grep -q "^nanolight-$version-linux-aarch64/nanolight$" ;;
    esac
}

quarantine() {
    xattr -r -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$1"
}

# ----- the checks -----

echo "== $tag from $base"
for f in manifest.json "$dmg" "$dmg.sha256" "$macos_zip" $pc; do
    curl -fsSL --retry 3 -o "$dl/$f" "$base/$f"
done
for f in $pc; do curl -fsSL --retry 3 -o "$dl/$f.sha256" "$base/$f.sha256"; done

check "manifest names $version" feed_version
for f in "$macos_zip" $pc; do check "manifest's sha256 of $f" feed_sum "$f"; done
for f in "$dmg" $pc; do check ".sha256 of $f" side_sum "$f"; done
for f in $pc; do check "$f holds the program" holds "$f"; done

quarantine "$dl/$dmg"
check "disk image is whole" hdiutil verify -quiet "$dl/$dmg"
check "disk image: signature holds" codesign --verify --strict "$dl/$dmg"
check "disk image: ticket stapled" stapled "$dl/$dmg"
check "disk image: Gatekeeper, quarantined" notarized -t open --context context:primary-signature "$dl/$dmg"

hdiutil attach "$dl/$dmg" -nobrowse -readonly -noautoopen -quiet -mountpoint "$mnt"
mounted="$mnt/Nanolight.app"
check "disk image offers Applications" test "$(readlink "$mnt/Applications")" = /Applications
check "disk image's app: signed, hardened" signed "$mounted"
check "disk image's app: ticket stapled" stapled "$mounted"
check "disk image's app: Gatekeeper" notarized -t exec "$mounted"
check "disk image's app: says $version" says_version "$mounted"

# Dragged to Applications, as a browser's download comes: assessed only. Run,
# macOS could ask about it on this screen.
installed="$work/installed/Nanolight.app"
ditto "$mounted" "$installed"
quarantine "$installed"
check "installed copy: Gatekeeper, quarantined" notarized -t exec "$installed"
check "installed copy: syspolicy_check" syspolicy_check distribution "$installed"
xattr -r -d com.apple.quarantine "$installed"
bin="$installed/Contents/MacOS/nanolight"
check "installed copy: arm64, for macOS 14" for_macos_14 "$bin"
check "installed copy: runs, says $version" prints_version "$bin"
check "installed copy: runs hardened, draws" draws "$bin" "$work/panel.png"
[ -z "${KEEP_SNAPSHOT:-}" ] || cp "$work/panel.png" "$KEEP_SNAPSHOT" 2>/dev/null || true

ditto -x -k "$dl/$macos_zip" "$work/zip"
update="$work/zip/Nanolight.app"
check "update: signed, hardened" signed "$update"
check "update: ticket stapled" stapled "$update"
check "update: Gatekeeper" notarized -t exec "$update"
check "update: says $version" says_version "$update"
check "update is the disk image's build" same_build "$update" "$mounted"

echo
if [ "$fails" -gt 0 ]; then
    echo "$tag: $fails check(s) FAILED"
    exit 1
fi
echo "$tag: all checks passed"

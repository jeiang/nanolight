#!/bin/sh
# The panel's query never goes back to what it showed before a key (#24, a
# drawable from a slowed display link covering the newer one). Types a word,
# waits as a person pauses, deletes it, and watches the query's pixels: from
# the word to the placeholder and no further. The word coming back counts.
#
#   sh macos/verify-typing.sh [cycles]
#
# Needs /Applications/Nanolight.app, running with its panel in front. Presses
# keys, so CI only. If most cycles see the word's pixels never change, it fails
# in any mode: the keys went elsewhere, and "never went back" would mean
# nothing. An odd such cycle doesn't: builds with the bug have them (5 of 60 on
# v0.2.7, none of 24 on the fix).
# EXPECT=rollback inverts the verdict (a known-bad build must fail); EXPECT=any
# only reports (a pull request can't change the published build it runs on).
# SHOTS keeps what it saw of a rollback.
set -eu
[ "${CI:-}" = true ] || {
    echo "verify-typing.sh presses keys: CI runners only" >&2
    exit 2
}
cycles=${1:-12}
expect=${EXPECT:-clean}
shots=${SHOTS:-/tmp/nanolight-shots}
mkdir -p "$shots"
work=$(mktemp -d /tmp/nanolight-typing.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat >"$work/frame.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all where (w["kCGWindowOwnerName"] as? String)?.lowercased() == "nanolight" {
    guard let b = w["kCGWindowBounds"] as? [String: Any],
        let x = (b["X"] as? NSNumber)?.intValue, let y = (b["Y"] as? NSNumber)?.intValue,
        let width = (b["Width"] as? NSNumber)?.intValue, let h = (b["Height"] as? NSNumber)?.intValue, h > 60
    else { continue }
    print(x, y, width)
    break
}
SWIFT
swiftc -o "$work/frame" "$work/frame.swift"
keys() { osascript -e "tell application \"System Events\" to $1" >/dev/null; }

set -- $("$work/frame")
[ "$#" = 3 ] || {
    echo "FAIL  no panel on screen"
    exit 1
}
# The panel is 680 wide, its window a shadow's margin bigger all round. The
# patch is inside the word and clear of the caret at either end of it.
margin=$((($3 - 680) / 2))
rect="$(($1 + margin + 56)),$(($2 + margin + 14)),60,32"
echo "      watching $rect"

back=0
blind=0
frames=0
i=0
while [ "$i" -lt "$cycles" ]; do
    i=$((i + 1))
    keys 'keystroke "calendar"'
    # A pause, at a different point of the caret's half-second blink each time.
    sleep "1.$((i % 5))"
    dir="$work/c$i"
    mkdir "$dir"
    n=0
    screencapture -x -R "$rect" "$dir/before.png"
    keys 'key code 51 using option down'
    end=$(($(date +%s) + 2))
    while [ "$(date +%s)" -le "$end" ]; do
        n=$((n + 1))
        screencapture -x -R "$rect" "$dir/$(printf %03d "$n").png"
    done
    frames=$((frames + n))
    # The states seen, in order, each run of a same one counted once.
    states=$(cd "$dir" && for f in before.png [0-9]*.png; do shasum "$f" | cut -c1-8; done | uniq)
    distinct=$(echo "$states" | sort -u | wc -l | tr -d ' ')
    runs=$(echo "$states" | wc -l | tr -d ' ')
    [ "$distinct" -ge 2 ] || blind=$((blind + 1))
    if [ "$runs" -gt "$distinct" ]; then
        back=$((back + 1))
        echo "      cycle $i went back: $(echo "$states" | tr '\n' ' ')"
        mkdir -p "$shots/rollback-$(sw_vers -productVersion)-$i"
        cp "$dir"/*.png "$shots/rollback-$(sw_vers -productVersion)-$i/"
    fi
    rm -rf "$dir"
done
echo "      $frames captures, about $((frames / cycles)) per 2 s; $back of $cycles went back; $blind saw no change"
[ $((blind * 2)) -lt "$cycles" ] || {
    echo "FAIL  the word's pixels never changed in $blind of $cycles cycles: this check saw nothing"
    exit 1
}
if [ "$expect" = any ]; then
    echo "ok    typing checked, not judged: $back of $cycles went back"
elif [ "$expect" = rollback ]; then
    [ "$back" -gt 0 ] || {
        echo "FAIL  a build with the bug never went back: this check can't see it here"
        exit 1
    }
    echo "ok    the check sees the bug in a build that has it"
else
    [ "$back" = 0 ] || {
        echo "FAIL  the query went back to what it showed before a key"
        exit 1
    }
    echo "ok    typing never went back"
fi

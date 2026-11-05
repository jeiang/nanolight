#!/bin/sh
# Builds Nanolight for Windows and Linux (cross-compiled: any machine with
# Zig will do) into zig-out/package, and adds their archives to the update
# feed macos/package.sh wrote there (manifest.json), or starts one:
#
#   VERSION=0.2.0 sh pc/package.sh
#
#   nanolight-windows-x86_64.zip      nanolight.exe
#   nanolight-linux-x86_64.tar.gz     nanolight, nanolight.desktop, nanolight.png
#   nanolight-linux-aarch64.tar.gz    the same, for 64-bit Arm
#
# Each archive holds one folder, nanolight-<version>-<os>-<arch>. The app's
# updater (nanoui's update_portable.zig) finds the program in it, checks it
# says its version (`--version`), and puts it where the running one is.
set -eu
cd "$(dirname "$0")/.."
version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
out=zig-out/package
mkdir -p "$out"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for t in x86_64-windows-gnu x86_64-linux-gnu aarch64-linux-gnu; do
    arch="${t%%-*}"
    os=$(echo "$t" | cut -d- -f2)
    zig build install -Doptimize=ReleaseSafe -Dtarget="$t" -Dversion="$version" --prefix "$stage/build-$t" ${ZIG_FLAGS:-}
    name="nanolight-$version-$os-$arch"
    dir="$stage/$name"
    mkdir -p "$dir"
    if [ "$os" = windows ]; then
        cp "$stage/build-$t/bin/nanolight.exe" "$dir/"
        archive="nanolight-windows-$arch.zip"
        rm -f "$out/$archive"
        (cd "$stage" && zip -qr "$OLDPWD/$out/$archive" "$name")
    else
        cp "$stage/build-$t/bin/nanolight" "$dir/"
        cp src/icon-256.png "$dir/nanolight.png"
        cat > "$dir/nanolight.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Nanolight
Comment=A launcher: apps, math, Google and script commands
Exec=nanolight
Icon=nanolight
Categories=Utility;
EOF
        archive="nanolight-linux-$arch.tar.gz"
        tar -C "$stage" -czf "$out/$archive" "$name"
    fi
    (cd "$out" && shasum -a 256 "$archive" | tee "$archive.sha256")
done

# The feed: these archives' sums beside the Mac's, under this version.
python3 -I - "$out/manifest.json" "$version" "$out" <<'EOF'
import hashlib, json, os, sys
path, version, out = sys.argv[1:]
m = {"version": version, "files": {}}
if os.path.exists(path):
    old = json.load(open(path))
    if old.get("version") == version:
        m = old
for name in ("nanolight-windows-x86_64.zip", "nanolight-linux-x86_64.tar.gz", "nanolight-linux-aarch64.tar.gz"):
    with open(os.path.join(out, name), "rb") as f:
        m["files"][name] = {"sha256": hashlib.sha256(f.read()).hexdigest()}
json.dump(m, open(path, "w"), separators=(",", ":"))
print(json.dumps(m))
EOF

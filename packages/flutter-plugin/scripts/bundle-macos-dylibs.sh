#!/usr/bin/env bash
# bundle-macos-dylibs.sh — make the macOS .app self-contained.
#
# The bitHuman macOS engines link heavy C++ deps (ffmpeg / onnxruntime / openvino
# / llama / hdf5 / webp / …) as DYNAMIC libraries from Homebrew (/opt/homebrew).
# As built, the .app loads them from /opt/homebrew at runtime, so it only runs on
# a machine that has Homebrew + those exact libs. This script copies the whole
# transitive dylib closure into Contents/Frameworks, rewrites every load command
# to @loader_path/@rpath, strips the /opt/homebrew rpaths, and re-signs — so the
# app runs on a clean Mac. Run it on a release build BEFORE notarize-macos.sh.
#
# Usage:  scripts/bundle-macos-dylibs.sh <path-to .app> [--sign-identity "<id>"]
# Default signing is ad-hoc ("-") for local testing; notarize-macos.sh re-signs
# with your Developer ID afterwards.
set -euo pipefail

APP="${1:?usage: bundle-macos-dylibs.sh <path-to .app> [--sign-identity <id>]}"
IDENTITY="-"
if [[ "${2:-}" == "--sign-identity" ]]; then IDENTITY="${3:?identity}"; fi
[[ -d "$APP" ]] || { echo "✗ not a bundle: $APP"; exit 1; }

EXE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
BIN="$APP/Contents/MacOS/$EXE"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

echo "▸ bundling Homebrew dylibs into $FW …"
python3 - "$BIN" "$FW" <<'PY'
import os, re, shutil, subprocess, sys, glob

BIN, FW = sys.argv[1], sys.argv[2]
HB = ('/opt/homebrew', '/usr/local')
is_hb = lambda p: p.startswith(HB)

def run(*a): return subprocess.check_output(a, text=True, errors='replace')
def otool_L(p):
    out = run('otool','-L',p).splitlines()[1:]
    return [m.group(1) for l in out if (m:=re.match(r'\s+(\S+)\s+\(', l))]
def install_id(p):
    out = run('otool','-D',p).splitlines()
    return out[1].strip() if len(out) > 1 and not out[1].startswith('Archive') else None
def rpaths(p):
    out = run('otool','-l',p).splitlines(); rs=[]
    for i,l in enumerate(out):
        if 'cmd LC_RPATH' in l:
            for j in range(i,min(i+4,len(out))):
                if (m:=re.search(r'path (\S+) \(offset', out[j])): rs.append(m.group(1)); break
    return rs

# Index every Homebrew dylib by basename so @rpath/@loader_path deps resolve.
index = {}
for root in ('/opt/homebrew/opt','/opt/homebrew/Cellar','/opt/homebrew/lib'):
    for dp,_,fs in os.walk(root):
        for f in fs:
            if f.endswith('.dylib'): index.setdefault(f, os.path.join(dp,f))

def resolve(dep, referrer):
    """A load-command path -> a real source file we should bundle, or None."""
    base = os.path.basename(dep)
    if dep.startswith('/'):
        return dep if (is_hb(dep) and os.path.exists(dep)) else None  # skip /usr/lib,/System
    if dep.startswith(('@loader_path','@executable_path')):
        cand = os.path.normpath(os.path.join(os.path.dirname(referrer), dep.split('/',1)[1]))
        if os.path.exists(cand) and is_hb(os.path.realpath(cand)): return cand
    return index.get(base)        # @rpath/<x> or bare name -> Homebrew by basename

# Force-include runtime-dlopen'd sets a static walk can miss.
seeds = list(otool_L(BIN))
seeds += glob.glob('/opt/homebrew/opt/openvino/lib/libopenvino_*frontend*.dylib')
seeds += glob.glob('/opt/homebrew/opt/llama.cpp/lib/libggml*.dylib')

# BFS the closure, keyed by the basename used in load commands.
to_bundle, queue, done = {}, [], set()
for d in seeds:
    b = os.path.basename(d)
    if b in to_bundle: continue
    src = resolve(d, BIN)
    if src:
        to_bundle[b] = src
        queue.append(b)
while queue:
    base = queue.pop()
    if base in done: continue
    done.add(base)
    for d in otool_L(to_bundle[base]):
        b = os.path.basename(d)
        if b == base or b in to_bundle: continue            # self id / already have it
        r = resolve(d, to_bundle[base])
        if r:
            to_bundle[b] = r
            queue.append(b)

print(f"  closure: {len(to_bundle)} dylibs")

# 1) copy
for base, src in to_bundle.items():
    dst = os.path.join(FW, base)
    if not os.path.exists(dst):
        shutil.copy(src, dst); os.chmod(dst, 0o755)

# 2) rewrite each bundled dylib: id -> @rpath/base ; deps -> @loader_path/base
for base in to_bundle:
    p = os.path.join(FW, base)
    subprocess.run(['install_name_tool','-id',f'@rpath/{base}',p], check=True,
                   stderr=subprocess.DEVNULL)
    for d in otool_L(p):
        db = os.path.basename(d)
        if db == base: continue
        if db in to_bundle and not d.startswith('@loader_path'):
            subprocess.run(['install_name_tool','-change',d,f'@loader_path/{db}',p],
                           check=True, stderr=subprocess.DEVNULL)
    for rp in rpaths(p):                                     # drop dead /opt/homebrew rpaths
        if is_hb(rp):
            subprocess.run(['install_name_tool','-delete_rpath',rp,p],
                           check=False, stderr=subprocess.DEVNULL)

# 3) rewrite the main binary: deps -> @rpath/base ; drop the /opt/homebrew rpaths
for d in otool_L(BIN):
    db = os.path.basename(d)
    if db in to_bundle:
        subprocess.run(['install_name_tool','-change',d,f'@rpath/{db}',BIN],
                       check=True, stderr=subprocess.DEVNULL)
for rp in rpaths(BIN):
    if is_hb(rp):
        subprocess.run(['install_name_tool','-delete_rpath',rp,BIN],
                       check=True, stderr=subprocess.DEVNULL)
print("  load commands rewritten; /opt/homebrew rpaths removed")
PY

echo "▸ re-signing bundled dylibs + app (identity: $IDENTITY) …"
# Sign the new dylibs (no entitlements), then re-seal the app bundle PRESERVING
# its entitlements — the main executable was modified (install_name_tool), and a
# plain re-sign would otherwise drop the App Sandbox. No --deep: the untouched
# nested frameworks keep their signatures and the bundle seal covers them.
find "$FW" -name '*.dylib' -print0 | xargs -0 -I{} codesign -f -s "$IDENTITY" --timestamp=none "{}" 2>/dev/null
codesign -f -s "$IDENTITY" --timestamp=none \
  --preserve-metadata=entitlements,flags,runtime "$APP" 2>/dev/null

echo "▸ verifying no /opt/homebrew references remain anywhere in the bundle …"
LEFT=$({ otool -L "$BIN"; for f in "$FW"/*.dylib; do otool -L "$f"; done; } 2>/dev/null | grep -cE '/opt/homebrew|/usr/local' || true)
if [[ "$LEFT" == "0" ]]; then
  echo "✅ self-contained: 0 Homebrew references; $(ls "$FW"/*.dylib | wc -l | tr -d ' ') dylibs bundled"
else
  echo "❌ $LEFT Homebrew references still present:"
  for f in "$BIN" "$FW"/*.dylib; do otool -L "$f" 2>/dev/null | grep -E '/opt/homebrew|/usr/local' | sed "s#^#  $(basename "$f"): #"; done | head
  exit 1
fi

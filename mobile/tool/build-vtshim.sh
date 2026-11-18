#!/usr/bin/env bash
# Build libvtshim (native/vtshim.c over libghostty-vt at the pinned GHOSTTY_REV) for the phone and the host.
#
#   android/app/src/main/jniLibs/{arm64-v8a,x86_64}/libvtshim.so   loaded by the app
#   build/vtshim/libvtshim.dylib                                    loaded by the Dart unit tests
#
# libghostty-vt builds unpatched (macos/scripts/ghostty-patches/ are for the Mac app). The build is skipped
# while the stamp (rev + shim digest) matches and every output exists. --check prints the outputs and
# verifies each one exports every vts_ function.
set -euo pipefail
cd "$(dirname "$0")/.."

SETUP="../macos/scripts/setup.sh"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_REV="$(sed -n 's/^GHOSTTY_REV="\([0-9a-f]\{40\}\)".*/\1/p' "$SETUP")"
ZIG_FORMULA="$(sed -n 's/^GHOSTTY_ZIG_FORMULA="\(.*\)"$/\1/p' "$SETUP")"
[[ -n "$GHOSTTY_REV" && -n "$ZIG_FORMULA" ]] || { echo "error: no GHOSTTY_REV/GHOSTTY_ZIG_FORMULA in $SETUP" >&2; exit 1; }

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
API=35  # minSdk
SHIM="native/vtshim.c"
OUT_DIR="build/vtshim"
GHOSTTY_DIR="$OUT_DIR/ghostty"
STAMP_FILE=".vtshim-build-stamp"
# the script's own digest: an ABI, API or flag edit rebuilds
STAMP="$GHOSTTY_REV $(shasum -a 256 "$SHIM" | cut -c1-16) $(shasum -a 256 tool/build-vtshim.sh | cut -c1-16)"
ABIS=(arm64-v8a x86_64)
OUTPUTS=(android/app/src/main/jniLibs/arm64-v8a/libvtshim.so android/app/src/main/jniLibs/x86_64/libvtshim.so
  "$OUT_DIR/libvtshim.dylib")
FUNCS=(vts_new vts_free vts_write vts_resize vts_reset vts_mode vts_scroll_to vts_snapshot
  vts_encode_key vts_encode_paste vts_encode_wheel vts_encode_focus vts_take_replies)

check() {
  local f fn syms ok=0
  for f in "${OUTPUTS[@]}"; do
    if [[ ! -f "$f" ]]; then echo "missing: $f"; ok=1; continue; fi
    # the .so is stripped, so read its dynamic table; Mach-O keeps its exports in the symbol table
    if [[ "$f" == *.so ]]; then syms="$("$NDK_BIN/llvm-nm" -D --defined-only "$f")"
    else syms="$("$NDK_BIN/llvm-nm" -g --defined-only "$f")"; fi
    for fn in "${FUNCS[@]}"; do
      grep -qE " _?$fn\$" <<<"$syms" || { echo "$f: no $fn"; ok=1; }
    done
    # Android 15 devices use 16 KB pages: every LOAD segment must align to at least 0x4000
    if [[ "$f" == *.so ]]; then
      local aligns align
      aligns="$("$NDK_BIN/llvm-readelf" -lW "$f" | awk '$1 == "LOAD" { print $NF }')"
      [[ -n "$aligns" ]] || { echo "$f: no LOAD segments"; ok=1; }
      for align in $aligns; do
        (( align >= 0x4000 )) || { echo "$f: a LOAD segment aligns to $align, below 16 KB"; ok=1; }
      done
    fi
    echo "$f ($(wc -c <"$f" | tr -d ' ') bytes)"
  done
  return $ok
}

if [[ "${1:-}" == "--check" ]]; then check; exit; fi

all_present() { local f; for f in "${OUTPUTS[@]}"; do [[ -f "$f" ]] || return 1; done; }
if [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]] && all_present; then
  echo "libvtshim is current ($STAMP)"
  exit 0
fi

ZIG="$(brew --prefix "$ZIG_FORMULA")/bin/zig"
[[ -x "$ZIG" ]] || { echo "error: $ZIG missing; run brew install $ZIG_FORMULA" >&2; exit 1; }
# as in setup.sh: a versioned alias can still resolve to a stale rolling keg
zig_ver="$("$ZIG" version)"
[[ "$zig_ver" == "${ZIG_FORMULA#zig@}".* ]] || {
  echo "error: $ZIG is zig $zig_ver, need ${ZIG_FORMULA#zig@}; run brew upgrade $ZIG_FORMULA" >&2; exit 1; }
[[ -x "$NDK_BIN/clang" ]] || { echo "error: no NDK at $NDK; install NDK 28.2.13676358 or set ANDROID_NDK_HOME" >&2; exit 1; }

# the checkout under build/ is reused across runs while it sits at the pinned rev
if [[ "$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null)" != "$GHOSTTY_REV" ]]; then
  echo "fetching ghostty $GHOSTTY_REV..."
  rm -rf "$GHOSTTY_DIR"
  git init -q "$GHOSTTY_DIR"
  git -C "$GHOSTTY_DIR" remote add origin "$GHOSTTY_REPO"
  git -C "$GHOSTTY_DIR" fetch -q --depth 1 origin "$GHOSTTY_REV"
  git -C "$GHOSTTY_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
GHOSTTY="$PWD/$GHOSTTY_DIR"

# zig build <prefix> [target]; output lands in $GHOSTTY/out-<prefix>/lib/libghostty-vt.a
lib_vt() {
  echo "building libghostty-vt ${2:-native}..."
  ( cd "$GHOSTTY" && ANDROID_NDK_HOME="$NDK" "$ZIG" build -Demit-lib-vt -Doptimize=ReleaseFast \
      ${2:+-Dtarget="$2"} --prefix "out-$1" )
}

rm -f "$STAMP_FILE" "${OUTPUTS[@]}"
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a) triple=aarch64-linux-android ;;
    x86_64) triple=x86_64-linux-android ;;
  esac
  lib_vt "$abi" "$triple"
  mkdir -p "android/app/src/main/jniLibs/$abi"
  # static .a: the shared lib's SONAME is libghostty-vt.so.0, which jniLibs does not package.
  # 16 KB pages: Android 15 devices need them.
  "$NDK_BIN/$triple$API-clang" -O2 -fPIC -shared -I"$GHOSTTY/include" "$SHIM" \
    -Wl,--whole-archive "$GHOSTTY/out-$abi/lib/libghostty-vt.a" -Wl,--no-whole-archive \
    -Wl,-z,max-page-size=16384 -Wl,--gc-sections -s -lm -o "android/app/src/main/jniLibs/$abi/libvtshim.so"
done

lib_vt host
mkdir -p "$OUT_DIR"
cc -O2 -fPIC -shared -I"$GHOSTTY/include" "$SHIM" -Wl,-force_load,"$GHOSTTY/out-host/lib/libghostty-vt.a" \
  -o "$OUT_DIR/libvtshim.dylib"

check
printf '%s\n' "$STAMP" > "$STAMP_FILE"
echo "libvtshim built ($STAMP)"

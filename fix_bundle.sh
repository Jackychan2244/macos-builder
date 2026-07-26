#!/usr/bin/env bash
# Repair a macOS .app bundle: rewrite absolute/build-machine dylib paths to
# @loader_path-relative ones, and copy any missing dependencies into Frameworks.
#
# Usage: bash fix_bundle.sh "/path/to/Some.app" [extra-lib-search-dir ...]
#
# Why this is needed: cmake links against absolute paths on the build machine
# (e.g. /Users/runner/work/.../ssl-out/lib/libcrypto.3.dylib). macdeployqt only
# rewrites Qt frameworks, so non-Qt deps keep the build path and dyld fails at
# launch with no crash report — the app just silently disappears.
set -uo pipefail

APP="${1:?usage: fix_bundle.sh /path/to/App.app [search-dir ...]}"
shift || true
SEARCH_DIRS=("$@")

FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

log() { echo "[fix_bundle] $*"; }

# Collect every Mach-O we should inspect: executables in MacOS/, plus all
# dylibs and plugin bundles anywhere under Contents/.
collect_binaries() {
  find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0
  find "$APP/Contents/MacOS" -type f -perm +111 -print0 2>/dev/null
}

is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

# Locate a library by basename in Frameworks, then in the extra search dirs.
# Falls back to the unversioned stem: a binary may link libcrypto.3.dylib while
# only libcrypto.dylib was copied in.
find_lib() {
  local base="$1"
  if [ -e "$FW/$base" ]; then printf '%s' "$FW/$base"; return 0; fi

  local stem="${base%%.*}"
  if [ "$stem.dylib" != "$base" ] && [ -e "$FW/$stem.dylib" ]; then
    printf '%s' "$FW/$stem.dylib"; return 0
  fi

  local d hit
  for d in ${SEARCH_DIRS[@]+"${SEARCH_DIRS[@]}"}; do
    [ -n "$d" ] || continue
    hit=$(find "$d" -name "$base" -type f 2>/dev/null | head -1)
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    hit=$(find "$d" -name "$stem.dylib" -type f 2>/dev/null | head -1)
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
  done
  return 1
}

# ── Pass 1: normalise Frameworks contents ────────────────────────────────────
# Give every bundled dylib a self-consistent @rpath id and make sure versioned
# aliases exist (binaries often link libfoo.3.dylib while only libfoo.dylib
# was copied).
log "Normalising dylib IDs in Frameworks"
for lib in "$FW"/*.dylib; do
  [ -e "$lib" ] || continue
  base=$(basename "$lib")
  install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null || true
done

# ── Pass 2: resolve dependencies, iterating until nothing new appears ────────
# Copying a missing dep can introduce further missing deps, so loop.
for round in 1 2 3 4 5; do
  added=0
  while IFS= read -r -d '' bin; do
    is_macho "$bin" || continue

    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      base=$(basename "$dep")

      case "$dep" in
        # System libraries — always present, leave alone.
        /usr/lib/*|/System/*) continue ;;

        # Already relative. Just make sure the target exists in Frameworks.
        @rpath/*|@loader_path/*|@executable_path/*)
          rel="${dep#@rpath/}"; rel="${rel#@loader_path/../Frameworks/}"
          rel="${rel#@executable_path/../Frameworks/}"
          # Framework-style paths (Foo.framework/Versions/5/Foo) are handled by
          # macdeployqt; only chase plain dylibs here.
          case "$rel" in */*) continue ;; esac
          [ -e "$FW/$rel" ] && continue
          if src=$(find_lib "$rel"); then
            cp -L "$src" "$FW/$rel"
            install_name_tool -id "@rpath/$rel" "$FW/$rel" 2>/dev/null || true
            log "  copied missing $rel  (for $(basename "$bin"))"
            added=1
          else
            log "  WARN unresolved $rel  (for $(basename "$bin"))"
          fi
          ;;

        # Absolute path pointing outside the bundle — the fatal case.
        /*)
          if [ ! -e "$FW/$base" ]; then
            if [ -e "$dep" ]; then
              # Build machine path that happens to exist locally.
              cp -L "$dep" "$FW/$base"
            elif src=$(find_lib "$base"); then
              # Resolved from Frameworks or a search dir (possibly via stem).
              cp -L "$src" "$FW/$base"
            else
              log "  WARN cannot resolve $dep"
              continue
            fi
            install_name_tool -id "@rpath/$base" "$FW/$base" 2>/dev/null || true
            log "  copied external $base  (for $(basename "$bin"))"
            added=1
          fi
          install_name_tool -change "$dep" "@rpath/$base" "$bin" 2>/dev/null || true
          log "  rewrote $base in $(basename "$bin")"
          ;;
      esac
    done < <(otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}')
  done < <(collect_binaries)

  [ "$added" -eq 0 ] && { log "dependency graph closed after round $round"; break; }
done

# ── Pass 3: ensure every binary can actually find Frameworks ─────────────────
log "Ensuring rpaths"
while IFS= read -r -d '' bin; do
  is_macho "$bin" || continue
  have=$(otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')
  case "$bin" in
    "$APP/Contents/MacOS/"*)
      echo "$have" | grep -qx "@loader_path/../Frameworks" || \
        install_name_tool -add_rpath "@loader_path/../Frameworks" "$bin" 2>/dev/null || true
      ;;
    *)
      # Plugins live deeper; @executable_path reaches Frameworks from anywhere.
      echo "$have" | grep -qx "@executable_path/../Frameworks" || \
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
      ;;
  esac
done < <(collect_binaries)

# ── Pass 4: create versioned aliases (libfoo.dylib -> libfoo.3.dylib etc) ────
# Some binaries link the versioned soname while only the bare name was copied.
log "Creating versioned aliases where referenced"
while IFS= read -r -d '' bin; do
  is_macho "$bin" || continue
  otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    base=$(basename "$dep")
    case "$dep" in @rpath/*|@loader_path/*|@executable_path/*) ;; *) continue ;; esac
    case "$base" in */*) continue ;; esac
    [ -e "$FW/$base" ] && continue
    # libcrypto.3.dylib -> try libcrypto.dylib
    stem="${base%%.*}"
    if [ -e "$FW/$stem.dylib" ]; then
      cp -L "$FW/$stem.dylib" "$FW/$base"
      install_name_tool -id "@rpath/$base" "$FW/$base" 2>/dev/null || true
      log "  aliased $stem.dylib -> $base"
    fi
  done
done < <(collect_binaries)

# ── Re-sign: rewriting load commands invalidates existing signatures ─────────
log "Re-signing bundle (ad-hoc)"
find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null | \
  xargs -0 -I{} codesign --force --sign - --timestamp=none {} 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || true

# ── Report ───────────────────────────────────────────────────────────────────
echo ""
log "=== Remaining problems ==="
problems=0
while IFS= read -r -d '' bin; do
  is_macho "$bin" || continue
  otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      /*) echo "  ABSOLUTE  $(basename "$bin") -> $dep" ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        rel="${dep#@rpath/}"; rel="${rel#@loader_path/../Frameworks/}"
        rel="${rel#@executable_path/../Frameworks/}"
        case "$rel" in */*) continue ;; esac
        [ -e "$FW/$rel" ] || echo "  MISSING   $(basename "$bin") -> $rel"
        ;;
    esac
  done
done < <(collect_binaries) | sort -u | tee /tmp/fix_bundle_problems.txt
[ -s /tmp/fix_bundle_problems.txt ] || log "  none — bundle is self-contained"
log "done"

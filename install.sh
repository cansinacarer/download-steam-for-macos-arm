#!/bin/bash

main() {
  set -euo pipefail

  readonly CDN="https://client-update.steamstatic.com"
  readonly VALVE_TEAM_ID="MXGJJ98X76"
  readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' NC=$'\033[0m'

  info() { printf '%s\n' "${YELLOW}$*${NC}"; }
  ok()   { printf '%s\n' "${GREEN}$*${NC}"; }
  die()  { printf '%b\n' "${RED}Error: $*${NC}" >&2; exit 1; }

  # --- Preconditions ---------------------------------------------------------
  [ "$(uname -m)" = "arm64" ] || die "Apple Silicon only (detected $(uname -m))."
  if pgrep -x "steam_osx" >/dev/null 2>&1 || pgrep -x "Steam" >/dev/null 2>&1; then
    die "Steam is running. Quit it fully and re-run."
  fi
  command -v shasum >/dev/null || die "shasum not found."

  # --- Temp workspace, cleaned up no matter how we exit ----------------------
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  # --- 1. Fetch manifest -----------------------------------------------------
  info "1/7  Fetching package manifest from Valve's CDN..."
  local manifest
  # NOTE: split declaration from assignment. `local x="$(cmd)"` masks cmd's exit
  # status (local always succeeds), so `... || die` would never fire. This works.
  manifest="$(curl -fsSL "$CDN/steam_client_osx" | tr -d '\000')" \
    || die "Could not reach Valve's CDN."
  [ -n "$manifest" ] || die "Empty manifest."

  # --- 2. Parse filename + expected checksum ---------------------------------
  info "2/7  Reading bootstrapper entry..."
  # The appdmg_osx block contains a nested "steamchina" sub-block FIRST, with its
  # own file/size/sha2. A naive `grep -v steamchina` does NOT remove that block's
  # size/sha2 lines (they don't contain the word), so "first sha2" would grab the
  # China hash and every install would fail the checksum. Instead we walk the block
  # and skip the steamchina sub-block by brace depth, then take the canonical pair.
  local parsed file expected_sha sha_algo
  parsed="$(printf '%s\n' "$manifest" | awk '
    /"appdmg_osx"/ {inblk=1}
    inblk {
      if ($0 ~ /"steamchina"/) skip=1
      if (skip) {
        depth += gsub(/{/,"{") - gsub(/}/,"}")
        if (depth<=0 && $0 ~ /}/) skip=0
        next
      }
      if ($0 ~ /"file"/ && f=="") { split($0,a,"\""); f=a[4] }
      if ($0 ~ /"sha2"/ && s=="") { split($0,a,"\""); s=a[4] }
      if ($0 ~ /^[[:space:]]*}[[:space:]]*$/ && started) { print f"\t"s; exit }
      started=1
    }
  ')"
  file="$(printf '%s' "$parsed" | cut -f1)"
  expected_sha="$(printf '%s' "$parsed" | cut -f2)"
  [ -n "$file" ] || die "Could not find package filename in manifest (schema changed?)."

  # Prefer the manifest's SHA-256 (sha2); fall back to a SHA-1 embedded in the name.
  if [ -n "$expected_sha" ]; then
    sha_algo=256
  else
    expected_sha="$(printf '%s' "$file" | grep -oE '[0-9a-f]{40}' | head -n1)"
    sha_algo=1
  fi
  [ -n "$expected_sha" ] || die "No checksum available — refusing to install unverified."
  expected_sha="$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')"
  printf '     file:    %s\n' "$file"
  printf '     sha%s:  %s\n' "$sha_algo" "$expected_sha"

  # --- 3. Download -----------------------------------------------------------
  info "3/7  Downloading bootstrapper..."
  curl -fsSL "$CDN/$file" -o "$tmp/pkg.zip" || die "Download failed."

  # --- 4. Verify checksum (download integrity) -------------------------------
  info "4/7  Verifying SHA-$sha_algo..."
  local actual_sha
  actual_sha="$(shasum -a "$sha_algo" "$tmp/pkg.zip" | awk '{print $1}')"
  [ "$actual_sha" = "$expected_sha" ] \
    || die "Checksum mismatch!\n  expected: $expected_sha\n  actual:   $actual_sha"
  ok "     Checksum OK."

  # --- 5. Extract ------------------------------------------------------------
  info "5/7  Extracting..."
  unzip -q "$tmp/pkg.zip" -d "$tmp" || die "Unzip failed."
  tar xzf "$tmp/SteamMacBootstrapper.tar.gz" -C "$tmp" || die "Tar extract failed."
  [ -d "$tmp/Steam.app" ] || die "Steam.app not found after extraction."

  # --- 6. Verify architecture + signature (authenticity) ---------------------
  info "6/7  Verifying arm64 slice and Valve signature..."
  file "$tmp/Steam.app/Contents/MacOS/steam_osx" | grep -q arm64 \
    || die "Binary has no arm64 slice. Aborting."
  codesign --verify --deep --strict "$tmp/Steam.app" \
    || die "Code signature verification failed. Aborting."
  local team
  team="$(codesign -dv "$tmp/Steam.app" 2>&1 | awk -F= '/TeamIdentifier/{print $2}')"
  [ "$team" = "$VALVE_TEAM_ID" ] \
    || die "Unexpected signer Team ID: '$team' (expected $VALVE_TEAM_ID). Aborting."
  ok "     arm64 present, signed by Valve ($team)."

  # --- 7. Install — first and only step that touches /Applications -----------
  info "7/7  Installing to /Applications..."
  rm -rf "/Applications/Steam.app"
  ditto "$tmp/Steam.app" "/Applications/Steam.app"      # ditto is the macOS-correct way to copy an .app
  xattr -dr com.apple.quarantine "/Applications/Steam.app" 2>/dev/null || true

  local pkgdir="$HOME/Library/Application Support/Steam/package"
  mkdir -p "$pkgdir"
  echo "publicbeta" > "$pkgdir/beta"

  echo
  ok "Done. Steam is installed as a native ARM64 (universal) binary."
  echo
  echo "Next:"
  echo "  1. Launch Steam from /Applications."
  echo "  2. It self-updates to the full native ARM64 client (no Rosetta prompt)."
  echo "  3. Verify anytime:  file /Applications/Steam.app/Contents/MacOS/steam_osx"
  echo
}

main "$@"
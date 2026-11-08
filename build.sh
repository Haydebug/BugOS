#!/bin/bash
# Build BugOS.
#   ./build.sh                 build "BugOS.app" (in ~/Library/Caches/BugOS/build.noindex)
#   ./build.sh dmg             build, then dist/BugOS.dmg (drag BugOS into Applications, open it)
#   ./build.sh install         build, then replace /Applications/BugOS.app on this Mac and open it
#   ./build.sh update <part>   rebuild and swap one part into the installed BugOS, restarting only it
#                              (<part> = dock | explorer | squiggle | bugos)
#   ./build.sh release <x.y.z> publish a new version on GitHub (notes from release-notes/<x.y.z>.md):
#                              sets the version, builds the DMG, runs the privacy check on the source AND
#                              the built app (stops if anything personal is in it), commits, tags, pushes,
#                              and creates the GitHub release with BugOS.dmg. BugOS's updater picks it up.
#
# Everything is signed with the "BugDock Local Signing" certificate in the login keychain (override with
# SIGN_ID=<identity>). Its identity stays the same across builds, so macOS keeps BugOS's permissions.
# Bundles are assembled outside the Desktop: it's synced, and the tags it adds break codesign.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$HOME/Library/Caches/BugOS/build.noindex"   # .noindex: Spotlight doesn't list a second BugOS
APP="$BUILD/BugOS.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -p codesigning | awk '/"BugDock Local Signing"/ {print $2; exit}')
  [[ -z "$SIGN_ID" ]] && { echo "warning: signing certificate not found, signing ad-hoc (permissions reset each build)"; SIGN_ID=-; }
fi

compile() {
  # -file-prefix-map: no paths from this Mac end up inside the binaries.
  swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." >&2
}

# part bundle: <app dir> <executable> <Info.plist> [icon]
make_bundle() {
  local dir="$1" exe="$2" plist="$3" icon="${4:-}"
  rm -rf "$dir"
  mkdir -p "$dir/Contents/MacOS" "$dir/Contents/Resources"
  cp ".build/release/$exe" "$dir/Contents/MacOS/$exe"
  cp "Resources/$plist" "$dir/Contents/Info.plist"
  if [[ -n "$icon" ]]; then cp "Resources/$icon" "$dir/Contents/Resources/AppIcon.icns"; fi
}

sign() {  # <bundle> <identifier>
  xattr -cr "$1"
  codesign --force --sign "$SIGN_ID" --identifier "$2" "$1"
}

part_info() {  # <part> -> "bundle-name|executable|plist|icon|identifier"
  case "$1" in
    dock)     echo "BugDock.app|BugDock|BugDock-Info.plist||com.bugos.dock" ;;
    explorer) echo "File Explorer.app|BugExplorer|FileExplorer-Info.plist|FileExplorer.icns|com.bugos.explorer" ;;
    squiggle) echo "Squiggle.app|Squiggle|Squiggle-Info.plist||com.bugos.squiggle" ;;
    *) echo "unknown part: $1 (dock | explorer | squiggle | bugos)" >&2; exit 2 ;;
  esac
}

build_part() {  # <part> <into BugOS.app>
  local name exe plist icon id
  IFS='|' read -r name exe plist icon id <<< "$(part_info "$1")"
  make_bundle "$2/Contents/Applications/$name" "$exe" "$plist" "$icon"
  # File Explorer's dark icon (used while it's in dark mode).
  [[ "$1" == explorer ]] && cp Resources/FileExplorerDark.icns "$2/Contents/Applications/$name/Contents/Resources/AppIconDark.icns"
  sign "$2/Contents/Applications/$name" "$id"
}

build_launcher() {  # <into BugOS.app>
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp .build/release/BugOS "$1/Contents/MacOS/BugOS"
  cp Resources/BugOS-Info.plist "$1/Contents/Info.plist"
  cp Resources/BugOS.icns "$1/Contents/Resources/AppIcon.icns"
}

sign_app() {
  xattr -cr "$1"
  codesign --force --sign "$SIGN_ID" --identifier com.bugos.os "$1"
  codesign --verify --deep --strict "$1"
}

build_all() {
  compile
  rm -rf "$APP"
  mkdir -p "$APP/Contents/Applications"
  build_launcher "$APP"
  for p in dock explorer squiggle; do build_part "$p" "$APP"; done
  sign_app "$APP"
  echo "Built $APP"
}

make_dmg() {
  local stage="$BUILD/dmg" out="$ROOT/dist/BugOS.dmg"
  rm -rf "$stage"; mkdir -p "$stage" "$ROOT/dist"
  ditto "$APP" "$stage/BugOS.app"
  ln -s /Applications "$stage/Applications"
  cp "$ROOT/Resources/Read Me.txt" "$stage/Read Me.txt"
  rm -f "$out"
  hdiutil create -quiet -volname "BugOS" -srcfolder "$stage" -fs HFS+ -format UDZO "$out"
  rm -rf "$stage"
  echo "Made $out"
}

installed() {
  for p in "/Applications/BugOS.app" "$HOME/Applications/BugOS.app" "/Applications/Bug OS.app" "$HOME/Applications/Bug OS.app"; do [[ -d "$p" ]] && { echo "$p"; return 0; }; done
  return 0
}

install_here() {
  local dest; dest=$(installed); dest=${dest:-"/Applications/BugOS.app"}
  if [[ -x "$dest/Contents/MacOS/BugOS" ]]; then "$dest/Contents/MacOS/BugOS" --quit || true; sleep 1; fi
  rm -rf "$dest"
  # Before 1.1 the app was called "Bug OS.app": install as BugOS.app next to where it was.
  if [[ "$(basename "$dest")" == "Bug OS.app" ]]; then
    "$LSREGISTER" -u "$dest" 2>/dev/null || true
    dest="$(dirname "$dest")/BugOS.app"
  fi
  ditto "$APP" "$dest"
  "$LSREGISTER" -f -R "$dest"
  open "$dest"
  echo "Installed $dest"
}

update_part() {
  local dest; dest=$(installed)
  [[ -z "$dest" ]] && { echo "BugOS isn't installed; run ./build.sh install"; exit 1; }
  compile
  local bugos="$dest/Contents/MacOS/BugOS"
  if [[ "$1" == bugos ]]; then
    "$bugos" --quit || true; sleep 1
    build_launcher "$dest"
  else
    build_part "$1" "$dest"
  fi
  sign_app "$dest"
  "$LSREGISTER" -f -R "$dest"
  if [[ "$1" == bugos ]]; then open "$dest" --args --login
  elif pgrep -xq BugOS; then "$bugos" --restart "$1"
  else open "$dest" --args --login
  fi
  echo "Updated $1 in $dest"
}

set_version() {  # <x.y.z>
  local v="$1" build
  build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/BugOS-Info.plist)
  build=$((build + 1))
  for pl in Resources/BugOS-Info.plist Resources/BugDock-Info.plist Resources/FileExplorer-Info.plist Resources/Squiggle-Info.plist; do
    plutil -replace CFBundleShortVersionString -string "$v" "$pl"
    plutil -replace CFBundleVersion -string "$build" "$pl"
  done
  # Read Me title and its underline.
  local title="BugOS $v"
  { echo "$title"; printf '%*s\n' "${#title}" '' | tr ' ' '='; tail -n +3 "Resources/Read Me.txt"; } > "$BUILD/readme.tmp"
  mv "$BUILD/readme.tmp" "Resources/Read Me.txt"
}

release() {  # <x.y.z>
  local v="${1:?version, e.g. 1.2.0}" notes="release-notes/$1.md"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.0"; exit 2; }
  [[ -f "$notes" ]] || { echo "write the release notes first: $notes"; exit 2; }
  git symbolic-ref --short HEAD | grep -qx main || { echo "release from the main branch"; exit 2; }
  git tag | grep -qx "v$v" && { echo "v$v already exists"; exit 2; }
  git config core.hooksPath .githooks
  mkdir -p "$BUILD"
  set_version "$v"
  build_all
  make_dmg
  echo "== privacy check: source =="
  git add -A
  python3 tools/privacy-check.py --staged
  echo "== privacy check: built app and DMG =="
  python3 tools/privacy-check.py --binary "$APP" "$ROOT/dist/BugOS.dmg"
  git commit -q -m "BugOS $v" && git tag -a "v$v" -m "BugOS $v"
  git push -q origin main "v$v"
  gh release create "v$v" "$ROOT/dist/BugOS.dmg" --title "BugOS $v" --notes-file "$notes"
  echo "Released BugOS $v"
}

case "${1:-}" in
  "")      build_all ;;
  dmg)     build_all; make_dmg ;;
  install) build_all; install_here ;;
  update)  update_part "${2:?part: dock | explorer | squiggle | bugos}" ;;
  release) release "${2:-}" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac

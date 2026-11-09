#!/bin/bash
# Compile the app's core files with tools/checks/main.swift and run the checks.
#   tools/run-checks.sh [--progress]   (--progress also tests the copy progress window on a temporary disk image)
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${TMPDIR%/}/bugexplorer-checks"
mkdir -p "$WORK/shots"
# File Explorer's files use BugOS's shared module (BugOSKit): build it first. A compile error stops here,
# so an old test binary is never run by mistake.
rm -f "$WORK/checks"
swiftc -O -parse-as-library -module-name BugOSKit -emit-module -emit-module-path "$WORK/BugOSKit.swiftmodule" \
  -emit-library -static -o "$WORK/libBugOSKit.a" Sources/BugOSKit/BugOSKit.swift
swiftc -O -I "$WORK" -L "$WORK" -lBugOSKit -o "$WORK/checks" Sources/BugExplorer/Util.swift Sources/BugExplorer/Model.swift \
  Sources/BugExplorer/FileOps.swift tools/checks/main.swift
VOL=""
if [[ "${1:-}" == "--progress" ]]; then
  hdiutil create -size 1200m -fs APFS -volname BETest -ov "$WORK/betest.dmg" >/dev/null
  VOL=$(hdiutil attach -nobrowse "$WORK/betest.dmg" | awk -F'\t' '/BETest/ {print $NF}')
fi
set +e
"$WORK/checks" "$WORK/scratch" "$WORK/shots" ${VOL:+"$VOL"}
status=$?
set -e
if [[ -n "$VOL" ]]; then hdiutil detach "$VOL" >/dev/null; rm -f "$WORK/betest.dmg"; fi
echo "screenshots: $WORK/shots"
exit $status

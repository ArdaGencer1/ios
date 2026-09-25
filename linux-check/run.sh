#!/usr/bin/env bash
# Copies the app sources next to the framework stubs and type-checks/tests them.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$here/Sources/BeautyRadio"
mkdir -p "$here/Sources/BeautyRadio"
# The SwiftUI/WebKit shell has no Linux stand-in; everything else is checked.
for f in "$here"/../ios/BeautyRadio/Sources/*.swift; do
    case "$(basename "$f")" in
        BeautyRadioApp.swift|RadioView.swift) continue ;;
    esac
    cp "$f" "$here/Sources/BeautyRadio/"
done
cat > "$here/Sources/BeautyRadio/LinuxShim.swift" <<'EOF'
// Linux only: URLSession lives in FoundationNetworking there.
@_exported import FoundationNetworking
EOF
cd "$here"
swift test "$@"

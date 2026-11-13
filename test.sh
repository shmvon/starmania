#!/bin/bash
# Runs the test suite on any Mac with Xcode or the Command Line Tools.
# With only the Command Line Tools, Swift Testing's macro plugin must be passed explicitly.
set -e
cd "$(dirname "$0")"

ARGS=(--disable-sandbox --build-path /private/tmp/Starmania_build)
PLUGIN_DIR="$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing"
[ -d "$PLUGIN_DIR" ] || PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGIN_DIR" ]; then
    ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

# Same SDK fallback as build.sh: the SDK that worked last time, the default SDK, then the others, newest first
SDKS=()
[ -n "$SDKROOT" ] && SDKS+=("$SDKROOT")
REMEMBERED=/private/tmp/Starmania_build/.working-sdk
[ -f "$REMEMBERED" ] && SDKS+=("$(cat "$REMEMBERED")")
DEFAULT_SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
[ -n "$DEFAULT_SDK" ] && SDKS+=("$DEFAULT_SDK")
for dir in "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs" "/Library/Developer/CommandLineTools/SDKs"; do
    [ -d "$dir" ] || continue
    while IFS= read -r sdk; do SDKS+=("$dir/$sdk"); done < <(ls "$dir" | grep -E '^MacOSX[0-9.]+\.sdk$' | sort -t X -k 2 -V -r)
done

# SDKs whose SwiftUI needs the SwiftUIMacros plugin (Xcode only) go last, as in build.sh
SWIFTC_DIR=$(dirname "$(xcrun -f swiftc 2>/dev/null || command -v swiftc)")
needs_missing_plugin() {
    grep -qs 'type: "StateMacro"' "$1"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface || return 1
    local d
    for d in "$SWIFTC_DIR/../lib/swift/host/plugins" "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" "$1/usr/lib/swift/host/plugins"; do
        ls "$d"/*SwiftUIMacros* >/dev/null 2>&1 && return 1
    done
    return 0
}

TRIED=""
FIRST=()
LAST=()
for sdk in "${SDKS[@]}"; do
    real=$(cd "$sdk" 2>/dev/null && pwd -P) || continue
    case " $TRIED " in *" $real "*) continue ;; esac
    TRIED="$TRIED $real"
    if needs_missing_plugin "$real"; then LAST+=("$real"); else FIRST+=("$real"); fi
done

for sdk in ${FIRST[@]+"${FIRST[@]}"} ${LAST[@]+"${LAST[@]}"}; do
    echo "Using SDK: $sdk"
    if SDKROOT="$sdk" swift build --build-tests "${ARGS[@]}"; then
        echo "$sdk" > "$REMEMBERED"
        SDKROOT="$sdk" swift test "${ARGS[@]}" "$@"
        exit $?
    fi
    echo "Build with this SDK failed; trying the next one..."
done
echo "Error: the tests could not be built with any installed SDK."
exit 1

#!/bin/bash
# Builds Starmania.app from source. Works on any Mac with Xcode or the Command Line Tools
# (xcode-select --install) and Swift 6.
#
#   ./build.sh                 Ask for a name suffix and install location (dialog)
#   ./build.sh --no-dialog     No dialog: build Starmania.app in this folder
#   ./build.sh --install       With --no-dialog: install into /Applications
#   ./build.sh --suffix NAME   With --no-dialog: build Starmania_NAME.app
#   ./build.sh --zip           Also make dist/Starmania-<version>.zip (for a GitHub release)
#   ./build.sh --clean         Flush the build cache first
set -e

BASE_APP_NAME="Starmania"
WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
# Double-clicking (or running it from elsewhere) starts in another folder; SwiftPM needs the package folder
cd "$WORKSPACE_DIR"
VERSION=$(tr -d '[:space:]' < "$WORKSPACE_DIR/VERSION")
BUILD_NUMBER=$(git -C "$WORKSPACE_DIR" rev-list --count HEAD 2>/dev/null || echo 1)

USE_DIALOG=true
INSTALL_TO_APPS=false
CUSTOM_SUFFIX=""
MAKE_ZIP=false
CLEAN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --no-dialog) USE_DIALOG=false ;;
        --install) INSTALL_TO_APPS=true ;;
        --suffix) CUSTOM_SUFFIX="$2"; shift ;;
        --zip) MAKE_ZIP=true ;;
        --clean) CLEAN=true ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
    shift
done

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode or run: xcode-select --install"
    exit 1
fi

echo "Starmania $VERSION (build $BUILD_NUMBER)"

if [ "$USE_DIALOG" = true ]; then
    # Suffix selection & installation destination dialog box
    echo "Prompting for build options..."
    COMPUTER_NAME=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "Mac")
    read -r -d '' DIALOG_SCRIPT <<'APPLESCRIPT' || true
use framework "AppKit"
use framework "Foundation"
use scripting additions

property radioComputer : missing value
property radioCustom : missing value
property radioNoSuffix : missing value
property customField : missing value

on run argv
    set appName to item 1 of argv
    set computerName to item 2 of argv

    set mainAlert to current application's NSAlert's alloc()'s init()
    mainAlert's setMessageText:("Build " & appName)
    mainAlert's setInformativeText:"As the app will only work on the system on which it was built and can't be shared without the source files, adding a suffix to each build is recommended."
    mainAlert's addButtonWithTitle:"Build"
    mainAlert's addButtonWithTitle:"Cancel"

    set containerView to current application's NSView's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 400, 140))

    set radioComputer to my makeRadio("Computer name (" & computerName & ")", 110, 390, 1)
    containerView's addSubview:radioComputer

    set radioCustom to my makeRadio("Custom name:", 80, 115, 0)
    containerView's addSubview:radioCustom

    set customField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(120, 80, 260, 22))
    customField's setPlaceholderString:"Enter custom suffix"
    customField's setDelegate:me
    containerView's addSubview:customField

    set radioNoSuffix to my makeRadio("No suffix", 50, 390, 0)
    containerView's addSubview:radioNoSuffix

    set checkbox to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 10, 390, 22))
    checkbox's setButtonType:(current application's NSSwitchButton)
    checkbox's setTitle:"Install into Applications folder (/Applications)"
    checkbox's setState:0
    containerView's addSubview:checkbox

    mainAlert's setAccessoryView:containerView
    mainAlert's layout()
    -- Typing goes straight into the name field (and picks "Custom name")
    mainAlert's |window|()'s setInitialFirstResponder:customField

    -- osascript runs in the background: macOS refuses AppKit's own activation request
    -- (so keystrokes kept going to Terminal), but honours the AppleScript activate command
    current application's NSApplication's sharedApplication()'s setActivationPolicy:(current application's NSApplicationActivationPolicyAccessory)
    activate
    set response to mainAlert's runModal()

    if response is 1000 then
        if (radioCustom's state() as integer is 1) then
            set choice to "Custom Name"
        else if (radioNoSuffix's state() as integer is 1) then
            set choice to "No Suffix"
        else
            set choice to "Computer Name"
        end if
    else
        set choice to "Cancel"
    end if
    set customVal to ""
    if choice is "Custom Name" then set customVal to (customField's stringValue() as text)
    set installToApps to (checkbox's state() as integer is 1)
    return (choice & "|" & (installToApps as text) & "|" & customVal)
end run

on makeRadio(title, y, w, isOn)
    set b to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, y, w, 22))
    b's setButtonType:(current application's NSRadioButton)
    b's setTitle:title
    b's setState:isOn
    b's setTarget:me
    b's setAction:"radioClicked:"
    return b
end makeRadio

on selectRadio(chosen)
    repeat with b in {radioComputer, radioCustom, radioNoSuffix}
        if (b's isEqual:chosen) as boolean then
            (b's setState:1)
        else
            (b's setState:0)
        end if
    end repeat
end selectRadio

on radioClicked:sender
    my selectRadio(sender)
    if (sender's isEqual:radioCustom) as boolean then customField's |window|()'s makeFirstResponder:customField
end radioClicked:

on controlTextDidChange:aNotification
    my selectRadio(radioCustom)
end controlTextDidChange:
APPLESCRIPT
    DIALOG_RESULT=$(osascript -e "$DIALOG_SCRIPT" "$BASE_APP_NAME" "$COMPUTER_NAME" 2>/dev/null || echo "Cancel|false|")

    # Check if user cancelled
    CHOICE=$(echo "$DIALOG_RESULT" | cut -d'|' -f1)
    INSTALL_TO_APPS=$(echo "$DIALOG_RESULT" | cut -d'|' -f2)
    CUSTOM_VAL=$(echo "$DIALOG_RESULT" | cut -d'|' -f3)
    
    if [ -z "$CHOICE" ] || [ "$CHOICE" = "Cancel" ]; then
        echo "Build cancelled by user."
        exit 0
    fi
else
    if [ -n "$CUSTOM_SUFFIX" ]; then
        CHOICE="Custom Name"
        CUSTOM_VAL="$CUSTOM_SUFFIX"
    else
        CHOICE="No Suffix"
    fi
fi

SUFFIX=""
if [ "$CHOICE" = "Computer Name" ]; then
    COMPUTER_NAME=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "Mac")
    COMPUTER_NAME_CLEAN=$(echo "$COMPUTER_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
    SUFFIX="_$COMPUTER_NAME_CLEAN"
elif [ "$CHOICE" = "Custom Name" ]; then
    CUSTOM_VAL_CLEAN=$(echo "$CUSTOM_VAL" | sed 's/[^a-zA-Z0-9_-]/_/g')
    if [ -z "$CUSTOM_VAL_CLEAN" ]; then
        echo "Error: Custom suffix is empty or invalid."
        exit 1
    fi
    SUFFIX="_$CUSTOM_VAL_CLEAN"
fi

APP_NAME="${BASE_APP_NAME}${SUFFIX}"
echo "=== Building ${APP_NAME}.app ==="

DEPLOYMENT_TARGET="14.0"
BUILD_PATH="/private/tmp/${BASE_APP_NAME}_build"

if [ "$INSTALL_TO_APPS" = "true" ]; then
    FINAL_APP_BUNDLE="/Applications/${APP_NAME}.app"
else
    FINAL_APP_BUNDLE="$WORKSPACE_DIR/${APP_NAME}.app"
fi

# Clean previous app bundle output
echo "Cleaning previous app bundle..."
rm -rf "$WORKSPACE_DIR/${APP_NAME}.app"
rm -rf "$WORKSPACE_DIR/${BASE_APP_NAME}.app"
rm -rf "$FINAL_APP_BUNDLE"

# Flush build cache only if --clean flag is explicitly passed
if [ "$CLEAN" = true ]; then
    echo "Flushing build cache (--clean specified)..."
    rm -rf "$WORKSPACE_DIR/.build"
    rm -rf "$BUILD_PATH"
fi

# Create a clean temporary staging bundle directory
STAGING_DIR=$(mktemp -d /private/tmp/${BASE_APP_NAME}_staging.XXXXXX)
APP_BUNDLE="$STAGING_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating bundle directories..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# Pick an SDK that builds. Newer SDKs make SwiftUI's @State a macro, whose plugin (SwiftUIMacros)
# ships with Xcode but not with the Command Line Tools, so such SDKs can't build on a Mac without Xcode.
# Order: SDKROOT if set, the one that worked last time, the default, then newest first;
# SDKs that need a missing plugin go last (still tried, in case the check is wrong).
DEVELOPER_DIR_PATH=$(xcode-select -p 2>/dev/null || true)
SWIFTC_DIR=$(dirname "$(xcrun -f swiftc 2>/dev/null || command -v swiftc)")
has_swiftui_macros() {  # $1 = SDK path
    local d
    for d in "$SWIFTC_DIR/../lib/swift/host/plugins" \
             "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
             "$1/usr/lib/swift/host/plugins"; do
        ls "$d"/*SwiftUIMacros* >/dev/null 2>&1 && return 0
    done
    return 1
}
needs_missing_plugin() {  # $1 = SDK path
    grep -qs 'type: "StateMacro"' "$1"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface \
        && ! has_swiftui_macros "$1"
}

SDK_CANDIDATES=()
[ -n "$SDKROOT" ] && SDK_CANDIDATES+=("$SDKROOT")
REMEMBERED_SDK="$BUILD_PATH/.working-sdk"
[ -f "$REMEMBERED_SDK" ] && SDK_CANDIDATES+=("$(cat "$REMEMBERED_SDK")")
DEFAULT_SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
[ -n "$DEFAULT_SDK" ] && SDK_CANDIDATES+=("$DEFAULT_SDK")
for dir in "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/SDKs" \
           "/Library/Developer/CommandLineTools/SDKs"; do
    [ -d "$dir" ] || continue
    while IFS= read -r sdk; do
        SDK_CANDIDATES+=("$dir/$sdk")
    done < <(ls "$dir" | grep -E '^MacOSX[0-9.]+\.sdk$' | sort -t X -k 2 -V -r)
done

# Drop duplicates (MacOSX.sdk and MacOSX27.sdk are often links to the same SDK), then sort
USABLE_SDKS=()
LAST_RESORT_SDKS=()
SEEN=""
for sdk in "${SDK_CANDIDATES[@]}"; do
    real=$(cd "$sdk" 2>/dev/null && pwd -P) || continue
    case " $SEEN " in *" $real "*) continue ;; esac
    SEEN="$SEEN $real"
    if needs_missing_plugin "$real"; then
        echo "Skipping $(basename "$real") for now: its SwiftUI needs the SwiftUIMacros plugin, which only Xcode has."
        LAST_RESORT_SDKS+=("$real")
    else
        USABLE_SDKS+=("$real")
    fi
done

echo "Compiling release build via Swift PM (deployment target macOS $DEPLOYMENT_TARGET)..."
BUILT=false
FAILURES=""
mkdir -p "$BUILD_PATH"
for sdk in ${USABLE_SDKS[@]+"${USABLE_SDKS[@]}"} ${LAST_RESORT_SDKS[@]+"${LAST_RESORT_SDKS[@]}"}; do
    echo "Using SDK: $sdk"
    LOG="$BUILD_PATH/build-$(basename "$sdk" .sdk).log"
    if SDKROOT="$sdk" swift build -c release --disable-sandbox --package-path "$WORKSPACE_DIR" --build-path "$BUILD_PATH" 2>&1 | tee "$LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        echo "$sdk" > "$REMEMBERED_SDK"
        BUILT=true
        break
    fi
    FIRST_ERROR=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -m1 -E 'error:' | sed 's/^.*error: //')
    FAILURES="$FAILURES\n  $(basename "$sdk"): ${FIRST_ERROR:-see $LOG}"
    echo "Build with this SDK failed; trying the next one..."
done
if [ "$BUILT" != true ]; then
    if [ -z "$FAILURES" ]; then
        echo "Error: no macOS SDK found. Install Xcode or run: xcode-select --install"
    else
        echo "Error: the build failed with every installed SDK. First error per SDK:"
        echo -e "$FAILURES"
        echo "Full logs: $BUILD_PATH/build-*.log"
        echo "If every SDK needs SwiftUIMacros, install Xcode, or an older Command Line Tools SDK."
    fi
    rm -rf "$STAGING_DIR"
    exit 1
fi

INFO_PLIST_SRC="$WORKSPACE_DIR/Resources/Info.plist"
BUNDLE_EXEC=$(plutil -extract CFBundleExecutable raw "$INFO_PLIST_SRC" 2>/dev/null || echo "Starmania")

# Output layout differs between SwiftPM versions; only ever pick a release binary
BINARY_SRC=""
for candidate in \
    "$BUILD_PATH/out/Products/Release/$BUNDLE_EXEC" \
    "$BUILD_PATH/arm64-apple-macosx/release/$BUNDLE_EXEC" \
    "$BUILD_PATH/release/$BUNDLE_EXEC"; do
    if [ -f "$candidate" ]; then
        BINARY_SRC="$candidate"
        break
    fi
done
if [ -z "$BINARY_SRC" ]; then
    BINARY_SRC=$(find "$BUILD_PATH" -type f -name "$BUNDLE_EXEC" -perm +111 -ipath "*release*" | head -n 1)
fi

if [ ! -f "$BINARY_SRC" ]; then
    echo "Error: Built binary $BUNDLE_EXEC not found at $BUILD_PATH."
    rm -rf "$STAGING_DIR"
    exit 1
fi

echo "Copying compiled binary to bundle..."
cp "$BINARY_SRC" "$MACOS_DIR/$BUNDLE_EXEC"
chmod 755 "$MACOS_DIR/$BUNDLE_EXEC"

# Copy Info.plist
echo "Copying Info.plist..."
cp "$INFO_PLIST_SRC" "$CONTENTS_DIR/Info.plist"
chmod 644 "$CONTENTS_DIR/Info.plist"
# The version comes from the VERSION file, the build number from the commit count
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

# Copy App Icon if present
if [ -f "$WORKSPACE_DIR/Resources/AppIcon.icns" ]; then
    echo "Copying AppIcon.icns to Resources..."
    cp "$WORKSPACE_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    chmod 644 "$RESOURCES_DIR/AppIcon.icns"
fi

xattr -cr "$APP_BUNDLE" 2>/dev/null || true
chmod -R u+w,a+rX "$APP_BUNDLE"

# Sign ad-hoc
echo "Signing application..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

# Install to final destination
echo "Installing ${APP_NAME}.app to $FINAL_APP_BUNDLE..."
rm -rf "$FINAL_APP_BUNDLE"
mv "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
rm -rf "$STAGING_DIR"
touch "$FINAL_APP_BUNDLE"

# Force register with LaunchServices to refresh Finder info & icon cache
echo "Registering application with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -r "$FINAL_APP_BUNDLE" || \
    echo "Warning: Launch Services registration failed; the app bundle was still built successfully."

if [ "$MAKE_ZIP" = true ]; then
    mkdir -p "$WORKSPACE_DIR/dist"
    ZIP_PATH="$WORKSPACE_DIR/dist/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$FINAL_APP_BUNDLE" "$ZIP_PATH"
    echo "Release zip: $ZIP_PATH"
fi

echo "=== Build Completed Successfully ==="
echo "You can find the app bundle at: $FINAL_APP_BUNDLE"
echo "To run it, double-click the app in Finder or run in terminal:"
echo "open '$FINAL_APP_BUNDLE'"

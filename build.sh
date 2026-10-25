#!/bin/bash
set -e

BASE_APP_NAME="Starmania"

# Suffix selection & installation destination dialog box
echo "Prompting for build options..."
DIALOG_RESULT=$(osascript -e "
use framework \"AppKit\"
use framework \"Foundation\"
use scripting additions

on run
    set computerName to do shell script \"scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo Mac\"
    
    set mainAlert to current application's NSAlert's alloc()'s init()
    mainAlert's setMessageText:\"Build $BASE_APP_NAME\"
    mainAlert's setInformativeText:\"As the app will only work on the system on which it was built and can't be shared without the source files, adding a suffix to each build is recommended.\"
    
    mainAlert's addButtonWithTitle:\"Build\"
    mainAlert's addButtonWithTitle:\"Cancel\"
    
    set containerView to current application's NSView's alloc()'s initWithFrame:(current application's NSMakeRect(0, 0, 400, 140))
    
    -- 1. Computer Name
    set radioComputer to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 110, 390, 22))
    radioComputer's setButtonType:(current application's NSRadioButton)
    radioComputer's setTitle:(\"Computer name (\" & computerName & \")\")
    radioComputer's setState:1
    radioComputer's setTarget:me
    radioComputer's setAction:\"radioClicked:\"
    containerView's addSubview:radioComputer
    
    -- 2. Custom Name + Text Field
    set radioCustom to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 80, 115, 22))
    radioCustom's setButtonType:(current application's NSRadioButton)
    radioCustom's setTitle:\"Custom name:\"
    radioCustom's setState:0
    radioCustom's setTarget:me
    radioCustom's setAction:\"radioClicked:\"
    containerView's addSubview:radioCustom
    
    set customField to current application's NSTextField's alloc()'s initWithFrame:(current application's NSMakeRect(120, 80, 260, 22))
    customField's setPlaceholderString:\"Enter custom suffix\"
    containerView's addSubview:customField
    
    -- 3. No Suffix
    set radioNoSuffix to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 50, 390, 22))
    radioNoSuffix's setButtonType:(current application's NSRadioButton)
    radioNoSuffix's setTitle:\"No suffix\"
    radioNoSuffix's setState:0
    radioNoSuffix's setTarget:me
    radioNoSuffix's setAction:\"radioClicked:\"
    containerView's addSubview:radioNoSuffix
    
    -- 4. Checkbox: Install into Applications folder
    set checkbox to current application's NSButton's alloc()'s initWithFrame:(current application's NSMakeRect(0, 10, 390, 22))
    checkbox's setButtonType:(current application's NSSwitchButton)
    checkbox's setTitle:\"Install into Applications folder (/Applications)\"
    checkbox's setState:0
    containerView's addSubview:checkbox
    
    mainAlert's setAccessoryView:containerView
    
    current application's NSApp's activateIgnoringOtherApps:true
    set response to mainAlert's runModal()
    
    if response is 1000 then
        if (radioComputer's state() as integer is 1) then
            set choice to \"Computer Name\"
            set customVal to \"\"
        else if (radioCustom's state() as integer is 1) then
            set choice to \"Custom Name\"
            set customVal to (customField's stringValue() as string)
        else
            set choice to \"No Suffix\"
            set customVal to \"\"
        end if
    else
        set choice to \"Cancel\"
        set customVal to \"\"
    end if
    
    set installToApps to (checkbox's state() as integer is 1)
    
    return (choice & \"|\" & (installToApps as string) & \"|\" & customVal)
end run

on radioClicked:sender
end radioClicked:
" 2>/dev/null || echo "Cancel|false|")

# Check if user cancelled
CHOICE=$(echo "$DIALOG_RESULT" | cut -d'|' -f1)
INSTALL_TO_APPS=$(echo "$DIALOG_RESULT" | cut -d'|' -f2)
CUSTOM_VAL=$(echo "$DIALOG_RESULT" | cut -d'|' -f3)

if [ -z "$CHOICE" ] || [ "$CHOICE" = "Cancel" ]; then
    echo "Build cancelled by user."
    exit 0
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

# Define directories
WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENT_TARGET="14.0"
SWIFT_TARGET="arm64-apple-macos$DEPLOYMENT_TARGET"
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
if [ "$1" = "--clean" ] || [ "$2" = "--clean" ]; then
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

# Get macOS SDK path
PREFERRED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [ ! -d "$PREFERRED_SDK" ]; then
    PREFERRED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
fi
if [ -d "$PREFERRED_SDK" ]; then
    SDK_PATH="$PREFERRED_SDK"
else
    SDK_PATH=$(xcrun --show-sdk-path)
fi
export SDKROOT="$SDK_PATH"
echo "Using SDK: $SDK_PATH"
echo "Using deployment target: macOS $DEPLOYMENT_TARGET ($SWIFT_TARGET)"

# Build release target using Swift Package Manager
echo "Compiling Starmania release build via Swift PM..."
swift build -c release --disable-sandbox --build-path "$BUILD_PATH"

INFO_PLIST_SRC="$WORKSPACE_DIR/Info.plist"
BUNDLE_EXEC=$(plutil -extract CFBundleExecutable raw "$INFO_PLIST_SRC" 2>/dev/null || echo "Starmania")

BINARY_SRC="$BUILD_PATH/arm64-apple-macosx/release/$BUNDLE_EXEC"
if [ ! -f "$BINARY_SRC" ]; then
    BINARY_SRC="$BUILD_PATH/release/$BUNDLE_EXEC"
fi
if [ ! -f "$BINARY_SRC" ]; then
    BINARY_SRC=$(find "$BUILD_PATH" -type f -name "$BUNDLE_EXEC" -perm +111 | head -n 1)
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

echo "=== Build Completed Successfully ==="
echo "You can find the app bundle at: $FINAL_APP_BUNDLE"
echo "To run it, double-click the app in Finder or run in terminal:"
echo "open '$FINAL_APP_BUNDLE'"

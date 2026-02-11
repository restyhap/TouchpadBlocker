#!/bin/bash

APP_NAME="TouchpadBlocker"
VERSION=${1:-"1.0"}
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME}.app..."

# 1. Clean previous build
rm -rf "${APP_DIR}"

# 2. Create Directory Structure
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 3. Compile Swift Code
echo "Compiling Swift code..."
swiftc TouchpadBlockerApp.swift -o "${MACOS_DIR}/${APP_NAME}"
if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

# 4. Create Info.plist
echo "Creating Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.resty.touchpadblocker</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 5. Set Permissions
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "Build complete: ${APP_DIR}"
echo "You can move this app to /Applications folder."

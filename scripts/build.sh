#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache build/轻转.app/Contents/MacOS build/轻转.app/Contents/Resources
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path build/module-cache Source/*.swift -o build/轻转.app/Contents/MacOS/QingZhuan -framework AppKit -framework ImageIO -framework PDFKit -framework CoreText
cp Resources/Info.plist build/轻转.app/Contents/Info.plist
cp Resources/AppIcon.icns build/轻转.app/Contents/Resources/AppIcon.icns
codesign --force --sign - build/轻转.app
codesign --verify --deep --strict build/轻转.app
ditto -c -k --norsrc --keepParent build/轻转.app build/QingZhuan-v0.3.4-arm64.zip
shasum -a 256 build/QingZhuan-v0.3.4-arm64.zip > build/SHA256SUMS.txt
printf 'Built: build/轻转.app\n'

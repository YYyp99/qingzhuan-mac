#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -O -module-cache-path build/module-cache Source/ConversionEngine.swift Tests/EngineTests.swift -o build/EngineTests -framework AppKit -framework ImageIO -framework PDFKit -framework CoreText
fixture_dir="$(mktemp -d "$PWD/build/test-fixtures.XXXXXX")"
build/EngineTests "$fixture_dir"

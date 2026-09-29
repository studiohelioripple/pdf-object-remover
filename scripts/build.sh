#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_FILE="$SCRIPT_DIR/pdf_healer.swift"
BIN_FILE="$SCRIPT_DIR/pdf_healer"

echo "🔨 Compiling native Apple Silicon PDF Healer engine..."
swiftc -O -framework CoreImage -framework Vision -framework AppKit -framework CoreGraphics -framework PDFKit \
    "$SWIFT_FILE" -o "$BIN_FILE"

chmod +x "$BIN_FILE"
echo "✅ Compilation successful: $BIN_FILE"

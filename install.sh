#!/usr/bin/env bash
# ==============================================================================
# PDF-Object-Remover: Installation & Engine Build Script
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"

# Default install target directory
if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  INSTALL_DIR="${HOME}/.local/bin"
elif [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
  INSTALL_DIR="${HOME}/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
fi

echo "🚀 Installing pdf-object-remover..."
mkdir -p "${INSTALL_DIR}"

# 1. Ensure scripts are executable
chmod +x "${SCRIPTS_DIR}/build.sh"
chmod +x "${SCRIPTS_DIR}/pdf_object_remover.py"
chmod +x "${SCRIPTS_DIR}/exemplar_healer.py"

# 2. Build native Apple Silicon Swift binary
echo "🔨 Compiling native Apple Silicon PDF healer engine..."
"${SCRIPTS_DIR}/build.sh"

# 3. Create CLI symlinks
echo "🔗 Linking executables to ${INSTALL_DIR}..."
ln -sfn "${SCRIPTS_DIR}/pdf_object_remover.py" "${INSTALL_DIR}/pdf-object-remover"
ln -sfn "${SCRIPTS_DIR}/pdf_object_remover.py" "${INSTALL_DIR}/pdf-remover"
ln -sfn "${SCRIPTS_DIR}/pdf_healer" "${INSTALL_DIR}/pdf-healer"

echo ""
echo "✅ Installation completed successfully!"
echo "Installed CLI tools in ${INSTALL_DIR}:"
echo "  • pdf-object-remover  (Master CLI)"
echo "  • pdf-remover         (Shortcut alias)"
echo "  • pdf-healer          (Native compiled Swift engine)"
echo ""
echo "Verify installation:"
echo "  pdf-object-remover --help"

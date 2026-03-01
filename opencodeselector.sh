#!/usr/bin/env bash
#
# chooseopencode.sh — Switch between OpenCode binaries (Linux & macOS)
#
# Profiles:
#   default  → anomalyco/opencode (vanilla)
#   omo      → code-yeongyu/oh-my-opencode (Sisyphus layer)
#
# How it works:
#   1. Binary symlink:  ~/.local/bin/opencode → chosen binary
#   2. Global config:   ~/.config/opencode    → ~/.config/opencode-{profile}/
#   3. Project config:  .opencode             → .opencode-{profile}/  (if it exists)
#
#   Each profile has its own permanent config directory. No files are
#   moved, edited, or stashed — just a symlink swap.
#
# Environment:
#   OPENCODE_HOME  — workspace directory containing package.json,
#                    node_modules/, and .opencode-omo/
#                    Defaults to current working directory ($PWD).
#
# Platform support:
#   - Linux x86_64   (apt for prerequisites)
#   - macOS arm64    (brew for prerequisites)
#   - macOS x86_64   (brew for prerequisites)
#
# Prerequisites (auto-installed if missing):
#   - curl
#   - node / npm
#   - coreutils (macOS only — for GNU sort -V, greadlink -f)
#   - bash >= 4 (macOS ships bash 3; brew bash is checked)
#
# Usage:
#   chooseopencode              # interactive menu (with update check)
#   chooseopencode omo          # switch directly
#   chooseopencode default      # switch directly
#   chooseopencode --status     # show current state
#   chooseopencode --update     # check & update current profile
#   chooseopencode --update all # check & update all profiles
#   chooseopencode --check      # only run prerequisite check
#

set -euo pipefail

# =============================================================================
# OS / Architecture detection
# =============================================================================

OS_NAME="$(uname -s)"   # Darwin or Linux
ARCH_NAME="$(uname -m)" # x86_64, arm64, aarch64

case "$OS_NAME" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux"  ;;
  *)
    echo "  ERROR: Unsupported OS: $OS_NAME"
    exit 1
    ;;
esac

case "$ARCH_NAME" in
  x86_64)       ARCH="x64"   ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)
    echo "  ERROR: Unsupported architecture: $ARCH_NAME"
    exit 1
    ;;
esac

# Platform identifier used for npm package names (e.g. linux-x64, darwin-arm64)
PLATFORM="${OS}-${ARCH}"

# =============================================================================
# Portable tool wrappers (GNU coreutils on macOS, native on Linux)
# =============================================================================

# These are set after prerequisites are confirmed; provide safe defaults first.
SORT_CMD="sort"
READLINK_CMD="readlink"

_init_tool_paths() {
  if [[ "$OS" == "darwin" ]]; then
    # Prefer GNU coreutils prefixed binaries installed by brew
    if command -v gsort &>/dev/null; then
      SORT_CMD="gsort"
    fi
    if command -v greadlink &>/dev/null; then
      READLINK_CMD="greadlink"
    fi
  fi
}

# Portable "sort -V" (version sort)
sort_version() {
  "$SORT_CMD" -V "$@"
}

# Portable "readlink -f" (canonicalize)
readlink_f() {
  "$READLINK_CMD" -f "$@"
}

# =============================================================================
# Prerequisites
# =============================================================================

_has() { command -v "$1" &>/dev/null; }

# Detect the system package installer
_pkg_install() {
  if [[ "$OS" == "darwin" ]]; then
    if ! _has brew; then
      echo ""
      echo "  Homebrew is not installed. It is required on macOS to install prerequisites."
      echo "  Install command: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      echo ""
      read -rp "  Install Homebrew now? [Y/n]: " yn
      if [[ "$yn" =~ ^[Nn] ]]; then
        echo "  Cannot continue without Homebrew on macOS."
        exit 1
      fi
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Source brew shellenv for the current session
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
    brew install "$@"
  else
    # Linux — try apt, then dnf, then yum
    if _has apt-get; then
      sudo apt-get update -qq && sudo apt-get install -y "$@"
    elif _has dnf; then
      sudo dnf install -y "$@"
    elif _has yum; then
      sudo yum install -y "$@"
    elif _has pacman; then
      sudo pacman -S --noconfirm "$@"
    else
      echo "  ERROR: No supported package manager found (apt, dnf, yum, pacman)."
      echo "  Please install manually: $*"
      return 1
    fi
  fi
}

# Map of prerequisite → check command, package name (linux), package name (macOS)
check_prerequisites() {
  local missing_linux=()
  local missing_mac=()
  local all_ok=true

  echo ""
  echo "  Checking prerequisites..."
  echo "  -------------------------"

  # 1. bash >= 4 (needed for associative arrays)
  local bash_ver
  bash_ver="${BASH_VERSINFO[0]}"
  if (( bash_ver < 4 )); then
    echo "    bash >= 4 ............. MISSING (current: bash $bash_ver)"
    all_ok=false
    if [[ "$OS" == "darwin" ]]; then
      missing_mac+=(bash)
    else
      missing_linux+=(bash)
    fi
  else
    echo "    bash >= 4 ............. OK (bash $bash_ver)"
  fi

  # 2. curl
  if _has curl; then
    echo "    curl .................. OK"
  else
    echo "    curl .................. MISSING"
    all_ok=false
    missing_linux+=(curl)
    missing_mac+=(curl)
  fi

  # 3. node
  if _has node; then
    echo "    node .................. OK ($(node --version 2>/dev/null))"
  else
    echo "    node .................. MISSING"
    all_ok=false
    if [[ "$OS" == "darwin" ]]; then
      missing_mac+=(node)
    else
      missing_linux+=(nodejs)
    fi
  fi

  # 4. npm
  if _has npm; then
    echo "    npm ................... OK ($(npm --version 2>/dev/null))"
  else
    echo "    npm ................... MISSING"
    all_ok=false
    if [[ "$OS" == "darwin" ]]; then
      # node formula includes npm on brew
      if ! printf '%s\n' "${missing_mac[@]}" | grep -qx node 2>/dev/null; then
        missing_mac+=(node)
      fi
    else
      missing_linux+=(npm)
    fi
  fi

  # 5. GNU coreutils (macOS only — needed for sort -V and readlink -f)
  if [[ "$OS" == "darwin" ]]; then
    if _has gsort && _has greadlink; then
      echo "    coreutils (gnu) ....... OK"
    else
      echo "    coreutils (gnu) ....... MISSING (needed for sort -V, readlink -f)"
      all_ok=false
      missing_mac+=(coreutils)
    fi
  else
    # Linux: sort -V and readlink -f are standard
    if sort --version &>/dev/null && readlink --version &>/dev/null; then
      echo "    coreutils ............. OK"
    else
      echo "    coreutils ............. MISSING"
      all_ok=false
      missing_linux+=(coreutils)
    fi
  fi

  # 6. mkdir / ln / rm (always present, but check anyway)
  local basic_ok=true
  for cmd in mkdir ln rm mv; do
    if ! _has "$cmd"; then
      echo "    $cmd .................. MISSING"
      all_ok=false
      basic_ok=false
    fi
  done
  if [[ "$basic_ok" == true ]]; then
    echo "    basic tools ........... OK (mkdir, ln, rm, mv)"
  fi

  echo ""

  # --- Offer to install missing packages ---
  if [[ "$all_ok" == true ]]; then
    echo "  All prerequisites satisfied."
    echo ""
    return 0
  fi

  if [[ "$OS" == "darwin" ]]; then
    if (( ${#missing_mac[@]} > 0 )); then
      # De-duplicate
      local unique_mac
      unique_mac=($(printf '%s\n' "${missing_mac[@]}" | sort -u))
      echo "  Missing macOS packages: ${unique_mac[*]}"
      echo "  Install command: brew install ${unique_mac[*]}"
      echo ""
      read -rp "  Install now with Homebrew? [Y/n]: " yn
      if [[ ! "$yn" =~ ^[Nn] ]]; then
        _pkg_install "${unique_mac[@]}"
        echo ""
        echo "  Packages installed. Re-checking..."
        _init_tool_paths
        # If we installed a newer bash, warn that user may need to re-run
        if (( bash_ver < 4 )) && _has bash; then
          local new_bash
          new_bash="$(brew --prefix)/bin/bash"
          if [[ -x "$new_bash" ]]; then
            echo ""
            echo "  NOTE: A newer bash was installed at: $new_bash"
            echo "  macOS ships bash 3.x. Please re-run this script with:"
            echo "    $new_bash $0 $*"
            echo ""
            exit 0
          fi
        fi
      else
        echo "  WARNING: Some features may not work without prerequisites."
      fi
    fi
  else
    if (( ${#missing_linux[@]} > 0 )); then
      local unique_linux
      unique_linux=($(printf '%s\n' "${missing_linux[@]}" | sort -u))
      echo "  Missing Linux packages: ${unique_linux[*]}"
      echo ""
      read -rp "  Install now? [Y/n]: " yn
      if [[ ! "$yn" =~ ^[Nn] ]]; then
        _pkg_install "${unique_linux[@]}"
        echo ""
        echo "  Packages installed."
      else
        echo "  WARNING: Some features may not work without prerequisites."
      fi
    fi
  fi

  echo ""
}

# =============================================================================
# Paths & config (platform-aware)
# =============================================================================

# OPENCODE_HOME: workspace dir with package.json / node_modules / .opencode-omo
# Override via env var; defaults to $PWD so the script works from anywhere.
OPENCODE_HOME="${OPENCODE_HOME:-$PWD}"

# --- Symlink targets ---
SYMLINK_BIN="$HOME/.local/bin/opencode"
SYMLINK_GLOBAL_CFG="$HOME/.config/opencode"
SYMLINK_PROJECT_CFG="$OPENCODE_HOME/.opencode"

# --- Binary paths ---
BIN_DEFAULT="$HOME/.opencode/bin/opencode"

# OMO package name is platform-specific
OMO_PKG="oh-my-opencode-${PLATFORM}"
BIN_OMO="$OPENCODE_HOME/node_modules/${OMO_PKG}/bin/oh-my-opencode"

# --- Config directories (permanent, never moved) ---
GLOBAL_CFG_DEFAULT="$HOME/.config/opencode-default"
GLOBAL_CFG_OMO="$HOME/.config/opencode-omo"
PROJECT_CFG_OMO="$OPENCODE_HOME/.opencode-omo"

# --- Profile registry ---
declare -A PROFILES BINARIES GLOBAL_CFGS
PROFILES[default]="Vanilla OpenCode (anomalyco/opencode)"
PROFILES[omo]="OhMyOpenCode (code-yeongyu/oh-my-opencode)"
BINARIES[default]="$BIN_DEFAULT"
BINARIES[omo]="$BIN_OMO"
GLOBAL_CFGS[default]="$GLOBAL_CFG_DEFAULT"
GLOBAL_CFGS[omo]="$GLOBAL_CFG_OMO"

# --- Version cache (populated lazily) ---
declare -A LOCAL_VERSIONS LATEST_VERSIONS
LOCAL_VERSIONS=()
LATEST_VERSIONS=()

# =============================================================================
# Version helpers
# =============================================================================

get_local_version() {
  local profile="$1"
  # Return cached value if available
  if [[ -n "${LOCAL_VERSIONS[$profile]+x}" ]]; then
    echo "${LOCAL_VERSIONS[$profile]}"; return
  fi

  local ver="not installed"
  local bin="${BINARIES[$profile]}"
  if [[ -x "$bin" ]]; then
    ver="$("$bin" --version 2>/dev/null || echo "unknown")"
    # Strip leading 'v' if present
    ver="${ver#v}"
    # Trim whitespace
    ver="$(echo "$ver" | xargs)"
  fi
  LOCAL_VERSIONS[$profile]="$ver"
  echo "$ver"
}

get_latest_version() {
  local profile="$1"
  # Return cached value if available
  if [[ -n "${LATEST_VERSIONS[$profile]+x}" ]]; then
    echo "${LATEST_VERSIONS[$profile]}"; return
  fi

  local ver="unknown"
  case "$profile" in
    default)
      # GitHub releases API for anomalyco/opencode
      ver="$(curl -fsSL --max-time 5 \
        "https://api.github.com/repos/anomalyco/opencode/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"v\{0,1\}\([^"]*\)".*/\1/p')" || true
      ;;
    omo)
      # npm registry for platform-specific oh-my-opencode package
      ver="$(curl -fsSL --max-time 5 \
        "https://registry.npmjs.org/${OMO_PKG}/latest" 2>/dev/null \
        | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')" || true
      ;;
  esac
  [[ -z "$ver" ]] && ver="unknown"
  LATEST_VERSIONS[$profile]="$ver"
  echo "$ver"
}

# Compare two semver strings. Returns 0 if $1 < $2 (update available).
version_lt() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  # Use sort -V for version comparison (GNU coreutils)
  local lowest
  lowest="$(printf '%s\n%s\n' "$a" "$b" | sort_version | head -n1)"
  [[ "$lowest" == "$a" ]]
}

# Returns a short version status string for display
version_status() {
  local profile="$1"
  local local_ver latest_ver

  local_ver="$(get_local_version "$profile")"
  latest_ver="$(get_latest_version "$profile")"

  if [[ "$local_ver" == "not installed" ]]; then
    echo "NOT INSTALLED (latest: $latest_ver)"
    return
  fi

  if [[ "$latest_ver" == "unknown" ]]; then
    echo "v$local_ver (could not check latest)"
    return
  fi

  if version_lt "$local_ver" "$latest_ver"; then
    echo "v$local_ver -> v$latest_ver UPDATE AVAILABLE"
  else
    echo "v$local_ver (up to date)"
  fi
}

has_update() {
  local profile="$1"
  local local_ver latest_ver

  local_ver="$(get_local_version "$profile")"
  latest_ver="$(get_latest_version "$profile")"

  [[ "$local_ver" != "not installed" ]] \
    && [[ "$latest_ver" != "unknown" ]] \
    && version_lt "$local_ver" "$latest_ver"
}

is_installed() {
  local profile="$1"
  [[ "$(get_local_version "$profile")" != "not installed" ]]
}

# =============================================================================
# Update helpers
# =============================================================================

update_default() {
  echo ""
  echo "  Updating vanilla OpenCode..."
  echo "  Running: curl -fsSL https://opencode.ai/install | bash"
  echo ""
  if curl -fsSL https://opencode.ai/install | bash; then
    # Clear cached version
    unset 'LOCAL_VERSIONS[default]'
    echo ""
    echo "  Updated to: $(get_local_version default)"
  else
    echo ""
    echo "  ERROR: Update failed."
    return 1
  fi
}

update_omo() {
  echo ""
  echo "  Updating OhMyOpenCode..."
  echo "  Running: npm update ${OMO_PKG} (in $OPENCODE_HOME)"
  echo ""
  if (cd "$OPENCODE_HOME" && npm update "${OMO_PKG}"); then
    # Clear cached version
    unset 'LOCAL_VERSIONS[omo]'
    echo ""
    echo "  Updated to: $(get_local_version omo)"
  else
    echo ""
    echo "  ERROR: Update failed."
    return 1
  fi
}

install_default() {
  echo ""
  echo "  Installing vanilla OpenCode..."
  echo "  Running: curl -fsSL https://opencode.ai/install | bash"
  echo ""
  if curl -fsSL https://opencode.ai/install | bash; then
    unset 'LOCAL_VERSIONS[default]'
    echo ""
    echo "  Installed: $(get_local_version default)"
  else
    echo ""
    echo "  ERROR: Installation failed."
    return 1
  fi
}

install_omo() {
  echo ""
  echo "  Installing OhMyOpenCode (${OMO_PKG})..."
  echo "  Running: npm install ${OMO_PKG}@latest (in $OPENCODE_HOME)"
  echo ""
  if (cd "$OPENCODE_HOME" && npm install "${OMO_PKG}@latest"); then
    unset 'LOCAL_VERSIONS[omo]'
    echo ""
    echo "  Installed: $(get_local_version omo)"
  else
    echo ""
    echo "  ERROR: Installation failed."
    return 1
  fi
}

do_update() {
  local profile="$1"

  if ! is_installed "$profile"; then
    echo ""
    echo "  $profile is not installed."
    read -rp "  Install it now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
      case "$profile" in
        default) install_default ;;
        omo)     install_omo ;;
      esac
    fi
    return
  fi

  if ! has_update "$profile"; then
    echo ""
    echo "  $profile is already up to date: $(get_local_version "$profile")"
    return
  fi

  local local_ver latest_ver
  local_ver="$(get_local_version "$profile")"
  latest_ver="$(get_latest_version "$profile")"
  echo ""
  echo "  $profile: v$local_ver -> v$latest_ver"
  read -rp "  Update now? [Y/n]: " yn
  if [[ ! "$yn" =~ ^[Nn] ]]; then
    case "$profile" in
      default) update_default ;;
      omo)     update_omo ;;
    esac
  fi
}

# =============================================================================
# OMO health check (get-local-version + doctor)
# =============================================================================

check_omo_health() {
  local bin="$BIN_OMO"

  # --- Pre-flight: is omo installed at all? ---
  if [[ ! -x "$bin" ]]; then
    echo ""
    echo "  OhMyOpenCode is not installed."
    echo "    Expected binary: $bin"
    echo "    Platform package: ${OMO_PKG}"
    echo ""
    read -rp "  Install oh-my-opencode now? [Y/n]: " yn
    if [[ ! "$yn" =~ ^[Nn] ]]; then
      install_omo || return 1
      bin="$BIN_OMO"
      # Verify install succeeded
      if [[ ! -x "$bin" ]]; then
        echo "  ERROR: Installation completed but binary not found."
        return 1
      fi
    else
      echo "  Skipping omo health check (not installed)."
      return 1
    fi
  fi

  echo ""
  echo "  OMO Health Check"
  echo "  ================"

  # --- Step 1: get-local-version ---
  echo ""
  echo "  Running: oh-my-opencode get-local-version"
  echo "  ------------------------------------------"
  local version_output version_rc
  version_output="$("$bin" get-local-version --directory "$OPENCODE_HOME" 2>&1)" && version_rc=0 || version_rc=$?
  if [[ -n "$version_output" ]]; then
    echo "$version_output" | sed 's/^/    /'
  fi
  if (( version_rc != 0 )); then
    echo "    (get-local-version exited with code $version_rc)"
  fi

  # --- Step 2: doctor ---
  echo ""
  echo "  Running: oh-my-opencode doctor --status"
  echo "  ----------------------------------------"
  local doctor_output doctor_rc
  doctor_output="$("$bin" doctor --status 2>&1)" && doctor_rc=0 || doctor_rc=$?
  if [[ -n "$doctor_output" ]]; then
    echo "$doctor_output" | sed 's/^/    /'
  fi

  # --- Step 3: If doctor found problems, offer remediation ---
  if (( doctor_rc != 0 )); then
    echo ""
    echo "  Doctor detected issues (exit code $doctor_rc)."
    echo ""

    # Show verbose diagnostics
    read -rp "  Show detailed diagnostics? [y/N]: " yn_verbose
    if [[ "$yn_verbose" =~ ^[Yy] ]]; then
      echo ""
      echo "  Running: oh-my-opencode doctor --verbose"
      echo "  -----------------------------------------"
      "$bin" doctor --verbose 2>&1 | sed 's/^/    /' || true
      echo ""
    fi

    # Offer to run install to fix issues
    read -rp "  Run 'oh-my-opencode install' to fix? [Y/n]: " yn_fix
    if [[ ! "$yn_fix" =~ ^[Nn] ]]; then
      echo ""
      echo "  Running: oh-my-opencode install"
      echo "  --------------------------------"
      "$bin" install || true
      echo ""
      # Re-run doctor to verify
      echo "  Re-checking health..."
      "$bin" doctor --status 2>&1 | sed 's/^/    /' || true
    fi
  else
    echo ""
    echo "  All checks passed."
  fi

  echo ""
}

# =============================================================================
# Profile switching
# =============================================================================

current_profile() {
  if [[ -L "$SYMLINK_GLOBAL_CFG" ]]; then
    local target
    target="$(readlink "$SYMLINK_GLOBAL_CFG")"
    case "$target" in
      *opencode-omo)     echo "omo"; return ;;
      *opencode-default) echo "default"; return ;;
    esac
  fi
  if [[ -L "$SYMLINK_BIN" ]]; then
    local target
    target="$(readlink_f "$SYMLINK_BIN")"
    if [[ "$target" == "$BIN_OMO" ]]; then
      echo "omo"; return
    fi
  fi
  echo "default"
}

check_binary() {
  local profile="$1"
  local bin="${BINARIES[$profile]}"
  if [[ ! -x "$bin" ]]; then
    echo "  ERROR: Binary for '$profile' not found or not executable:"
    echo "    $bin"
    echo ""
    read -rp "  Install $profile now? [Y/n]: " yn
    if [[ ! "$yn" =~ ^[Nn] ]]; then
      case "$profile" in
        default) install_default ;;
        omo)     install_omo ;;
      esac
      # Re-check after install
      [[ -x "$bin" ]] && return 0
    fi
    return 1
  fi
}

check_config_dir() {
  local profile="$1"
  local dir="${GLOBAL_CFGS[$profile]}"
  if [[ ! -d "$dir" ]]; then
    echo "  ERROR: Config directory for '$profile' not found:"
    echo "    $dir"
    echo ""
    echo "    Create it and populate with the appropriate opencode.json"
    return 1
  fi
}

set_symlink() {
  local link="$1"
  local target="$2"
  local label="$3"

  if [[ -L "$link" ]]; then
    rm -f "$link"
  elif [[ -e "$link" ]]; then
    echo "  WARNING: $link is a real ${label} (not a symlink)."
    echo "  Backing up to ${link}.bak.$(date +%s) before replacing."
    mv "$link" "${link}.bak.$(date +%s)"
  fi

  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
}

activate_profile() {
  local target="$1"
  local cur
  cur="$(current_profile)"

  if [[ "$target" == "$cur" ]]; then
    echo ""
    echo "  Already on: $target"
    echo "    ${PROFILES[$target]}"
    echo "    $(version_status "$target")"
    echo ""
    # Run OMO health check even when already on omo
    if [[ "$target" == "omo" ]]; then
      check_omo_health
    fi
    return 0
  fi

  check_binary "$target" || exit 1
  check_config_dir "$target" || exit 1

  # 1. Switch binary symlink
  set_symlink "$SYMLINK_BIN" "${BINARIES[$target]}" "file"

  # 2. Switch global config symlink
  set_symlink "$SYMLINK_GLOBAL_CFG" "${GLOBAL_CFGS[$target]}" "directory"

  # 3. Switch project-level config symlink
  if [[ "$target" == "omo" && -d "$PROJECT_CFG_OMO" ]]; then
    set_symlink "$SYMLINK_PROJECT_CFG" "$PROJECT_CFG_OMO" "directory"
  else
    [[ -L "$SYMLINK_PROJECT_CFG" ]] && rm -f "$SYMLINK_PROJECT_CFG"
  fi

  echo ""
  echo "  Switched to: $target"
  echo "    ${PROFILES[$target]}"
  echo ""
  echo "    Binary:  $SYMLINK_BIN -> ${BINARIES[$target]}"
  echo "    Config:  $SYMLINK_GLOBAL_CFG -> ${GLOBAL_CFGS[$target]}"
  if [[ "$target" == "omo" && -d "$PROJECT_CFG_OMO" ]]; then
    echo "    Project: $SYMLINK_PROJECT_CFG -> $PROJECT_CFG_OMO"
  fi
  echo "    Version: $(get_local_version "$target")"
  echo ""

  # --- Run OMO health check when switching to omo ---
  if [[ "$target" == "omo" ]]; then
    check_omo_health
  fi

  echo "  Restart your terminal or run: hash -r"
  echo ""
}

# =============================================================================
# Display
# =============================================================================

show_status() {
  local cur
  cur="$(current_profile)"

  echo ""
  echo "  Current profile: $cur"
  echo "  Platform: ${PLATFORM} (${OS_NAME} ${ARCH_NAME})"
  echo ""

  echo "  Binary symlink:"
  if [[ -L "$SYMLINK_BIN" ]]; then
    echo "    $SYMLINK_BIN -> $(readlink "$SYMLINK_BIN")"
  else
    echo "    $SYMLINK_BIN (not a symlink)"
  fi

  echo "  Global config:"
  if [[ -L "$SYMLINK_GLOBAL_CFG" ]]; then
    echo "    $SYMLINK_GLOBAL_CFG -> $(readlink "$SYMLINK_GLOBAL_CFG")"
  else
    echo "    $SYMLINK_GLOBAL_CFG (not a symlink!)"
  fi

  echo "  Project config:"
  if [[ -L "$SYMLINK_PROJECT_CFG" ]]; then
    echo "    $SYMLINK_PROJECT_CFG -> $(readlink "$SYMLINK_PROJECT_CFG")"
  elif [[ -d "$SYMLINK_PROJECT_CFG" ]]; then
    echo "    $SYMLINK_PROJECT_CFG (real directory, not a symlink)"
  else
    echo "    $SYMLINK_PROJECT_CFG (not present - ok for default)"
  fi

  echo ""
  echo "  OMO package: ${OMO_PKG}"
  echo ""
  echo "  Checking versions..."
  for key in $(echo "${!PROFILES[@]}" | tr ' ' '\n' | sort); do
    echo "    $key: $(version_status "$key")"
  done
  echo ""
}

show_menu() {
  local cur
  cur="$(current_profile)"

  echo ""
  echo "  OpenCode Profile Switcher"
  echo "  ========================="
  echo "  Platform: ${PLATFORM} (${OS_NAME} ${ARCH_NAME})"
  echo ""
  echo "  Checking for updates..."

  # -- Collect version info for all profiles --
  local updates_available=()
  local installs_needed=()
  local keys=()

  for key in $(echo "${!PROFILES[@]}" | tr ' ' '\n' | sort); do
    keys+=("$key")
    if ! is_installed "$key"; then
      installs_needed+=("$key")
    elif has_update "$key"; then
      updates_available+=("$key")
    fi
  done

  local has_actions=false
  if (( ${#updates_available[@]} > 0 || ${#installs_needed[@]} > 0 )); then
    has_actions=true
  fi

  # ==========================================================================
  # Section 1: Updates & Installs (only shown when there's something to do)
  # ==========================================================================

  local action_options=()

  if [[ "$has_actions" == true ]]; then
    echo ""
    echo "  Updates & Installs"
    echo "  ------------------"

    local ai=1  # action index, lettered as a/b/c/...

    for upd in "${updates_available[@]}"; do
      local local_ver latest_ver letter
      local_ver="$(get_local_version "$upd")"
      latest_ver="$(get_latest_version "$upd")"
      letter=$(printf "\\x$(printf '%02x' $((96 + ai)))")
      action_options+=("update:$upd")
      echo "    ${letter}) Update $upd  v$local_ver -> v$latest_ver"
      ((ai++))
    done

    for inst in "${installs_needed[@]}"; do
      local latest_ver letter
      latest_ver="$(get_latest_version "$inst")"
      letter=$(printf "\\x$(printf '%02x' $((96 + ai)))")
      action_options+=("install:$inst")
      echo "    ${letter}) Install $inst  (latest: v$latest_ver)"
      ((ai++))
    done

    if (( ${#updates_available[@]} > 1 )); then
      local letter
      letter=$(printf "\\x$(printf '%02x' $((96 + ai)))")
      action_options+=("update:all")
      echo "    ${letter}) Update ALL"
      ((ai++))
    fi
  fi

  # ==========================================================================
  # Section 2: Switch Profile
  # ==========================================================================

  echo ""
  echo "  Switch Profile"
  echo "  ------------------"

  local i=1
  for key in "${keys[@]}"; do
    local marker="  "
    [[ "$key" == "$cur" ]] && marker="> "

    local ver_info
    ver_info="$(version_status "$key")"

    echo "  ${marker}${i}) ${key}"
    echo "     ${PROFILES[$key]}"
    echo "     ${ver_info}"
    ((i++))
  done

  # ==========================================================================
  # Prompt
  # ==========================================================================

  echo ""
  echo "  Current: $cur ($(get_local_version "$cur"))"
  echo ""

  if [[ "$has_actions" == true ]]; then
    local max_letter
    max_letter=$(printf "\\x$(printf '%02x' $((96 + ${#action_options[@]})))")
    read -rp "  Choose [1-${#keys[@]}] to switch, [a-${max_letter}] to update, [q] to quit: " choice
  else
    read -rp "  Choose [1-${#keys[@]}] to switch, [q] to quit: " choice
  fi

  # Quit
  if [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]]; then
    return 0
  fi

  # Letter choice -> action (a=1, b=2, ...)
  if [[ "$choice" =~ ^[a-z]$ ]]; then
    local action_idx=$(( $(printf '%d' "'$choice") - 97 ))
    if (( action_idx < 0 || action_idx >= ${#action_options[@]} )); then
      echo "  Invalid choice."
      exit 1
    fi

    local action="${action_options[$action_idx]}"
    local cmd="${action%%:*}"
    local target="${action#*:}"

    case "$cmd" in
      update)
        if [[ "$target" == "all" ]]; then
          for upd in "${updates_available[@]}"; do
            do_update "$upd"
          done
        else
          do_update "$target"
        fi
        ;;
      install)
        case "$target" in
          default) install_default ;;
          omo)     install_omo ;;
        esac
        ;;
    esac
    return
  fi

  # Number choice -> switch profile
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
    activate_profile "${keys[$((choice-1))]}"
    return
  fi

  echo "  Invalid choice."
  exit 1
}

# =============================================================================
# Main
# =============================================================================

# Always check prerequisites and init tool paths first
check_prerequisites
_init_tool_paths

case "${1:-}" in
  --status|-s)
    show_status
    ;;
  --update|-u)
    target="${2:-}"
    if [[ "$target" == "all" ]]; then
      for key in $(echo "${!PROFILES[@]}" | tr ' ' '\n' | sort); do
        do_update "$key"
      done
    elif [[ -n "$target" ]]; then
      if [[ -z "${PROFILES[$target]+x}" ]]; then
        echo "  Unknown profile: $target"
        echo "  Available: ${!PROFILES[*]}"
        exit 1
      fi
      do_update "$target"
    else
      # Update current profile
      do_update "$(current_profile)"
    fi
    ;;
  --check|-c)
    # Prerequisites already checked above; just exit cleanly
    echo "  Prerequisite check complete."
    ;;
  "")
    show_menu
    ;;
  *)
    if [[ -z "${PROFILES[$1]+x}" ]]; then
      echo "  Unknown profile: $1"
      echo "  Available: ${!PROFILES[*]}"
      exit 1
    fi
    activate_profile "$1"
    ;;
esac

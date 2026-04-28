#!/bin/bash
# =============================================================================
#  ACC Connector - Linux Setup Script
# =============================================================================
#  Supports: Bazzite, Fedora, Arch, Debian/Ubuntu, openSUSE, and any other
#  distribution where Steam is installed (native, Flatpak, or snap).
#
#  What this script does:
#   1. Checks prerequisites (Steam, ACC, required tools)
#   2. Downloads the latest ACC Connector Windows release from GitHub
#   3. Extracts the binaries from the Inno Setup installer
#   4. Deploys the hook DLL into ACC's game directory
#   5. Creates launch scripts and desktop integration
#   6. Registers the acc-connect:// protocol handler
#
#  Why the GUI runs in ACC's Proton prefix:
#   ACC runs through Steam Proton (Wine). The hook DLL injected into ACC
#   communicates with the GUI via a Windows named pipe. Named pipes are
#   isolated per Wine prefix — both components must share ACC's compatdata
#   directory for IPC to work.
#
#  What you may need to do manually:
#   - If the build is not self-contained, install dotnet8 in the prefix
#     (instructions are printed at the end if needed)
# =============================================================================

set -euo pipefail

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FAIL]${NC}  $*"; }
step()    { echo -e "\n${BLUE}==>${NC} ${YELLOW}$*${NC}"; }

# -- Configuration --
REPO="lonemeow/acc-connector"
ACC_APPID=805550
ACC_CONNECTOR_HOME="${HOME}/.local/share/acc-connector"
DOTNET_NEEDED=false   # Updated by extract_installer based on DLL count

# =============================================================================
# find_steam_paths — locate Steam installation and ACC Proton prefix
# =============================================================================
find_steam_paths() {
    # Covers: native Steam, Flatpak Steam (two symlink layouts), snap Steam
    local steam_dirs=(
        "${HOME}/.local/share/Steam"
        "${HOME}/.steam/steam"
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam"
        "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam"
        "${HOME}/snap/steam/common/.steam/steam"
    )
    for d in "${steam_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            STEAM_DIR="$d"
            success "Found Steam at $STEAM_DIR"
            break
        fi
    done

    if [[ -z "${STEAM_DIR:-}" ]]; then
        error "Could not find a Steam installation. Searched:"
        for d in "${steam_dirs[@]}"; do
            error "  $d"
        done
        error ""
        error "Set STEAM_DIR manually at the top of this script if Steam is elsewhere."
        exit 1
    fi

    COMPATDATA="${STEAM_DIR}/steamapps/compatdata"
    ACC_COMPATDATA="${COMPATDATA}/${ACC_APPID}"
    ACC_PREFIX="${ACC_COMPATDATA}/pfx"

    if [[ ! -d "$ACC_PREFIX" ]]; then
        error "ACC Proton prefix not found at: $ACC_PREFIX"
        error "Make sure ACC (App ID ${ACC_APPID}) is installed via Steam"
        error "and has been launched at least once with Proton enabled."
        exit 1
    fi
    success "Found ACC Proton prefix at $ACC_PREFIX"

    # Find Proton — check all known locations across all Steam install types
    local proton_search=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/"*
        "${HOME}/.steam/root/compatibilitytools.d/"*
        "${HOME}/.local/share/Steam/compatibilitytools.d/"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Proton"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/"*
    )
    PROTON_BIN=""
    for pd in "${proton_search[@]}"; do
        for d in $pd; do
            [[ -d "$d" ]] || continue
            if [[ -f "$d/proton" ]]; then
                PROTON_BIN="$d/proton"
                break 2
            fi
        done
    done

    if [[ -z "$PROTON_BIN" ]]; then
        warn "Could not automatically find a Proton binary. Will retry at launch time."
    else
        local proton_ver
        proton_ver=$(basename "$(dirname "$PROTON_BIN")")
        success "Found Proton: ${proton_ver}"
    fi
}

# =============================================================================
# check_prerequisites — verify required tools are present
# =============================================================================
check_prerequisites() {
    step "Step 1: Checking prerequisites"

    local missing=()
    if ! command -v curl    &>/dev/null; then missing+=("curl");    fi
    if ! command -v jq      &>/dev/null; then missing+=("jq");      fi
    if ! command -v python3 &>/dev/null; then missing+=("python3"); fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required packages: ${missing[*]}"
        echo ""
        echo "Install with your package manager:"
        echo "  Fedora / Bazzite:  sudo dnf install ${missing[*]}"
        echo "  Arch / Manjaro:    sudo pacman -S ${missing[*]}"
        echo "  Debian / Ubuntu:   sudo apt-get install ${missing[*]}"
        echo "  openSUSE:          sudo zypper install ${missing[*]}"
        echo ""
        exit 1
    fi
    success "All prerequisites found"

    find_steam_paths

    # Verify ACC appmanifest (informational only)
    local acc_manifests=(
        "${STEAM_DIR}/steamapps/appmanifest_${ACC_APPID}.acf"
        "${STEAM_DIR}/steamapps/compatdata/${ACC_APPID}"
    )
    local found_manifest=false
    for m in "${acc_manifests[@]}"; do
        [[ -e "$m" ]] && found_manifest=true && break
    done
    if [[ "$found_manifest" == "false" ]]; then
        warn "ACC appmanifest not found — this is OK if ACC was launched via Proton at least once."
    fi
}

# =============================================================================
# download_release — fetch the latest Windows installer from GitHub
# =============================================================================
download_release() {
    step "Step 2: Downloading ACC Connector release"

    mkdir -p "$ACC_CONNECTOR_HOME"

    echo "Fetching latest release info from GitHub..."
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local release_json
    release_json=$(curl -sS "$api_url")

    local tag_name
    tag_name=$(echo "$release_json" | jq -r '.tag_name')
    if [[ -z "$tag_name" || "$tag_name" == "null" ]]; then
        error "Failed to get latest release tag from GitHub."
        error "Response: $(echo "$release_json" | jq -r '.message // "unknown error"')"
        echo ""
        echo "You can manually download from:"
        echo "  https://github.com/${REPO}/releases"
        echo "Place the installer at: ${ACC_CONNECTOR_HOME}/ACC-Connector-Setup.exe"
        echo "Then re-run this script."
        exit 1
    fi
    info "Latest version: $tag_name"

    local installer_url
    installer_url=$(echo "$release_json" | jq -r \
        '.assets[] | select(.name | test("Setup.*\\.exe$")) | .browser_download_url' | head -1)

    if [[ -z "$installer_url" || "$installer_url" == "null" ]]; then
        error "No installer EXE found in the release assets."
        echo "Available assets:"
        echo "$release_json" | jq -r '.assets[].name'
        exit 1
    fi

    local installer_file="${ACC_CONNECTOR_HOME}/ACC-Connector-Setup.exe"
    local version_file="${ACC_CONNECTOR_HOME}/.version"

    if [[ -f "$version_file" ]]; then
        local installed_ver
        installed_ver=$(cat "$version_file")
        if [[ "$installed_ver" == "$tag_name" ]]; then
            success "Already at latest version ($tag_name). Skipping download."
            ACC_CONNECTOR_VERSION="$tag_name"
            return
        fi
    fi

    info "Downloading $installer_url ..."
    curl -L --progress-bar -o "$installer_file" "$installer_url"

    if [[ ! -f "$installer_file" ]]; then
        error "Download failed — installer not found after download."
        exit 1
    fi

    success "Downloaded installer to $installer_file"
    ACC_CONNECTOR_VERSION="$tag_name"
    echo "$tag_name" > "$version_file"
}

# =============================================================================
# extract_installer — unpack the Inno Setup installer with innoextract
# =============================================================================
extract_installer() {
    step "Step 3: Extracting files from installer"

    local extract_dir="${ACC_CONNECTOR_HOME}/app"
    local installer_file="${ACC_CONNECTOR_HOME}/ACC-Connector-Setup.exe"

    mkdir -p "$extract_dir"

    # Skip if both required files are already present
    local gui_already hook_already
    gui_already=$(find "$extract_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
    hook_already=$(find "$extract_dir" -name "client-hooks.dll"  -type f 2>/dev/null | head -1)
    if [[ -n "$gui_already" && -n "$hook_already" ]]; then
        info "Files already extracted. Skipping."
        _check_dll_count "$extract_dir"
        return
    fi

    if [[ ! -f "$installer_file" ]]; then
        warn "Installer not found at $installer_file"
        warn "Run this script again without removing the downloaded installer,"
        warn "or download it manually from https://github.com/${REPO}/releases"
        return
    fi

    # Try to install innoextract automatically if missing
    if ! command -v innoextract &>/dev/null; then
        info "innoextract not found. Attempting to install it..."
        if   command -v dnf     &>/dev/null; then sudo dnf     install -y innoextract 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then sudo apt-get install -y innoextract 2>/dev/null || true
        elif command -v pacman  &>/dev/null; then sudo pacman  -S --noconfirm innoextract 2>/dev/null || true
        elif command -v zypper  &>/dev/null; then sudo zypper  install -y innoextract 2>/dev/null || true
        fi
    fi

    if command -v innoextract &>/dev/null; then
        info "Extracting via innoextract..."
        local temp_dir="${ACC_CONNECTOR_HOME}/_temp"
        mkdir -p "$temp_dir"

        if innoextract -q "$installer_file" -d "$temp_dir" 2>/dev/null; then
            info "Extraction successful. Copying files..."
            # innoextract places {app} content into an app/ subdirectory
            find "$temp_dir" -name "ACC Connector.exe"        -exec cp {} "$extract_dir/" \; 2>/dev/null || true
            find "$temp_dir" -name "*.dll"                    -exec cp {} "$extract_dir/" \; 2>/dev/null || true
            find "$temp_dir" -name "*.json"                   -exec cp {} "$extract_dir/" \; 2>/dev/null || true
            find "$temp_dir" -name "LICENSE.txt"              -exec cp {} "$extract_dir/" \; 2>/dev/null || true
            find "$temp_dir" -name "THIRD_PARTY_LICENSES.txt" -exec cp {} "$extract_dir/" \; 2>/dev/null || true
            rm -rf "$temp_dir"
        else
            warn "innoextract returned an error during extraction."
            rm -rf "$temp_dir"
        fi
    fi

    # Verify — both files are required
    local gui_check hook_check
    gui_check=$(find "$extract_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
    hook_check=$(find "$extract_dir" -name "client-hooks.dll"  -type f 2>/dev/null | head -1)

    if [[ -n "$gui_check" && -n "$hook_check" ]]; then
        success "Extracted: ACC Connector.exe"
        success "Extracted: client-hooks.dll"
        _check_dll_count "$extract_dir"
    else
        warn ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn "  Automatic extraction incomplete."
        [[ -z "$gui_check"  ]] && warn "  MISSING: ACC Connector.exe"
        [[ -z "$hook_check" ]] && warn "  MISSING: client-hooks.dll"
        warn ""
        warn "  MANUAL STEP REQUIRED — choose one option:"
        warn ""
        warn "  Option A — Install innoextract, then run:"
        warn "    Fedora:  sudo dnf install innoextract"
        warn "    Arch:    sudo pacman -S innoextract"
        warn "    Ubuntu:  sudo apt-get install innoextract"
        warn "    openSUSE:sudo zypper install innoextract"
        warn "    Then:    innoextract '${installer_file}' -d '${extract_dir}'"
        warn "    Files land in ${extract_dir}/app/ — move them:"
        warn "      mv '${extract_dir}/app/'* '${extract_dir}/'"
        warn ""
        warn "  Option B — Copy from a Windows machine:"
        warn "    Run the installer on Windows, then copy all .exe, .dll, .json"
        warn "    files from C:\\Program Files\\ACC Connector\\"
        warn "    to: ${extract_dir}/"
        warn ""
        warn "  After copying, re-run this script."
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn ""
    fi
}

# Helper: count DLLs to determine whether the build is self-contained
_check_dll_count() {
    local dir="$1"
    local dll_count
    dll_count=$(find "$dir" -name "*.dll" -type f 2>/dev/null | wc -l)
    if (( dll_count >= 10 )); then
        success "Found $dll_count DLLs — build is self-contained (.NET runtime included)."
        DOTNET_NEEDED=false
    else
        warn "Only $dll_count DLL(s) found — build may NOT be self-contained."
        warn ".NET 8 runtime will likely need to be installed in the Proton prefix."
        DOTNET_NEEDED=true
    fi
}

# =============================================================================
# deploy_hook — copy client-hooks.dll → ACC's game dir as hid.dll
# =============================================================================
deploy_hook() {
    step "Step 4: Deploying hook DLL"

    local app_dir="${ACC_CONNECTOR_HOME}/app"
    local hook_dll
    hook_dll=$(find "$app_dir" -name "client-hooks.dll" -type f 2>/dev/null | head -1)

    if [[ -z "$hook_dll" ]]; then
        error "client-hooks.dll not found in $app_dir"
        error "Make sure Step 3 (extraction) completed successfully."
        return 1
    fi
    success "Found hook DLL: $hook_dll"

    local acc_game_dir=""

    # 1. Parse libraryfolders.vdf to search every Steam library
    local vdf_path="${STEAM_DIR}/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf_path" ]]; then
        info "Searching Steam library folders for ACC..."
        local library_paths
        library_paths=$(python3 - <<PYEOF 2>/dev/null
import re, sys
try:
    content = open('${vdf_path}', encoding='utf-8').read()
    for p in re.findall(r'"path"\s+"([^"]+)"', content):
        print(p)
except Exception as e:
    sys.stderr.write(str(e) + '\n')
PYEOF
)
        if [[ -n "$library_paths" ]]; then
            while IFS= read -r lib; do
                local candidate="${lib}/steamapps/common"
                [[ -d "$candidate" ]] || continue
                for dir in "$candidate"/*/; do
                    [[ -d "$dir" ]] || continue
                    if [[ -f "${dir}AC2/Binaries/Win64/AC2-Win64-Shipping.exe" ]]; then
                        acc_game_dir="${dir%/}"
                        break 2
                    fi
                done
            done <<< "$library_paths"
        fi
    fi

    # 2. Well-known native Steam library paths as fallback
    if [[ -z "$acc_game_dir" ]]; then
        local fallbacks=(
            "${STEAM_DIR}/steamapps/common/Assetto Corsa Competizione"
            "${HOME}/.steam/steam/steamapps/common/Assetto Corsa Competizione"
            "${HOME}/.local/share/Steam/steamapps/common/Assetto Corsa Competizione"
        )
        for p in "${fallbacks[@]}"; do
            if [[ -f "$p/AC2/Binaries/Win64/AC2-Win64-Shipping.exe" ]]; then
                acc_game_dir="$p"
                break
            fi
        done
    fi

    # 3. Last resort: search inside the Proton prefix (slow but thorough)
    if [[ -z "$acc_game_dir" ]]; then
        warn "Searching inside the Proton prefix (this may take a moment)..."
        local found
        found=$(find "${ACC_PREFIX}/drive_c" \
            -name "AC2-Win64-Shipping.exe" -type f 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            acc_game_dir="$(dirname "$(dirname "$(dirname "$(dirname "$found")")")")"
            success "Found ACC inside Proton prefix: $acc_game_dir"
        fi
    fi

    if [[ -z "$acc_game_dir" ]]; then
        warn ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn "  Could not locate the ACC installation directory."
        warn ""
        warn "  MANUAL STEP REQUIRED:"
        warn "  Find your ACC game folder and copy the hook DLL there:"
        warn ""
        warn "    cp '${hook_dll}' '<ACC_DIR>/AC2/Binaries/Win64/hid.dll'"
        warn ""
        warn "  <ACC_DIR> typically contains a folder called 'AC2'."
        warn "  Common location:"
        warn "    ${STEAM_DIR}/steamapps/common/Assetto Corsa Competizione"
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "" > "${ACC_CONNECTOR_HOME}/.acc_path"
        return 1
    fi

    local hid_dll_path="${acc_game_dir}/AC2/Binaries/Win64/hid.dll"

    # Check if our version is already installed
    if [[ -f "$hid_dll_path" ]]; then
        local hash_ours hash_existing
        hash_ours=$(md5sum "$hook_dll" | cut -d' ' -f1)
        hash_existing=$(md5sum "$hid_dll_path" | cut -d' ' -f1)
        if [[ "$hash_ours" == "$hash_existing" ]]; then
            success "Hook DLL already installed and up-to-date: $hid_dll_path"
            ACC_GAME_DIR="$acc_game_dir"
            echo "$ACC_GAME_DIR" > "${ACC_CONNECTOR_HOME}/.acc_path"
            return
        fi
        info "Backing up existing hid.dll → hid.dll.bak"
        cp "$hid_dll_path" "${hid_dll_path}.bak"
    fi

    cp "$hook_dll" "$hid_dll_path"
    success "Hook DLL installed: $hid_dll_path"
    ACC_GAME_DIR="$acc_game_dir"
    echo "$ACC_GAME_DIR" > "${ACC_CONNECTOR_HOME}/.acc_path"
}

# =============================================================================
# find_proton — locate the Proton binary (used during setup for display)
# =============================================================================
find_proton() {
    if [[ -n "${PROTON_BIN:-}" ]] && [[ -f "$PROTON_BIN" ]]; then
        echo "$PROTON_BIN"
        return
    fi

    local proton_search=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/"*
        "${HOME}/.steam/root/compatibilitytools.d/"*
        "${HOME}/.local/share/Steam/compatibilitytools.d/"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Proton"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/"*
    )
    for pd in "${proton_search[@]}"; do
        for d in $pd; do
            [[ -d "$d" ]] || continue
            if [[ -f "$d/proton" ]]; then
                echo "$d/proton"
                return
            fi
        done
    done

    warn "Proton binary not found."
}

# =============================================================================
# create_launcher — write acc-connector.sh and test-env.sh
# =============================================================================
create_launcher() {
    step "Step 5: Creating launch scripts"

    local launch_script="${ACC_CONNECTOR_HOME}/acc-connector.sh"
    local app_dir="${ACC_CONNECTOR_HOME}/app"

    local gui_exe
    gui_exe=$(find "$app_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
    if [[ -z "$gui_exe" ]]; then
        warn "GUI executable not found in $app_dir"
        warn "The launch script will be created but will not work until files are extracted."
    fi

    # Single-quoted heredoc: variables inside are intentionally NOT expanded here.
    # Everything is resolved at runtime when the user runs acc-connector.sh.
    cat > "$launch_script" <<'LAUNCHSCRIPT'
#!/bin/bash
# ACC Connector launcher
#
# Runs the Windows GUI inside ACC's Proton prefix so that the named-pipe IPC
# between the GUI and the hook DLL (injected into the ACC process) shares the
# same Wine prefix. This is required — named pipes are isolated per prefix.

ACC_APPID=805550
ACC_CONNECTOR_DIR="${HOME}/.local/share/acc-connector"
APP_DIR="${ACC_CONNECTOR_DIR}/app"

# ---------------------------------------------------------------------------
# Locate Steam (native, Flatpak, snap)
# ---------------------------------------------------------------------------
STEAM_DIR=""
for candidate in \
        "${HOME}/.local/share/Steam" \
        "${HOME}/.steam/steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam" \
        "${HOME}/snap/steam/common/.steam/steam"; do
    if [[ -d "$candidate" ]]; then
        STEAM_DIR="$candidate"
        break
    fi
done

if [[ -z "$STEAM_DIR" ]]; then
    echo "ERROR: Could not find a Steam installation."
    echo "Searched:"
    echo "  ~/.local/share/Steam"
    echo "  ~/.steam/steam"
    echo "  ~/.var/app/com.valvesoftware.Steam/data/Steam"
    echo "  ~/snap/steam/common/.steam/steam"
    exit 1
fi

# ---------------------------------------------------------------------------
# Locate GUI executable
# ---------------------------------------------------------------------------
GUI_EXE=$(find "$APP_DIR" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
if [[ -z "$GUI_EXE" ]]; then
    echo "ERROR: ACC Connector.exe not found in $APP_DIR"
    echo "Re-run setup-linux.sh to extract the application files."
    exit 1
fi

# ---------------------------------------------------------------------------
# Handle --uninstall-hook
# ---------------------------------------------------------------------------
case "${1:-}" in
    --uninstall-hook)
        ACC_GAME_DIR=$(cat "${ACC_CONNECTOR_DIR}/.acc_path" 2>/dev/null || echo "")
        if [[ -n "$ACC_GAME_DIR" ]] && [[ -d "$ACC_GAME_DIR" ]]; then
            HID_PATH="${ACC_GAME_DIR}/AC2/Binaries/Win64/hid.dll"
            if [[ -f "$HID_PATH" ]]; then
                rm -f "$HID_PATH"
                echo "Hook removed: ${HID_PATH}"
            else
                echo "Hook DLL not found at ${HID_PATH} — already removed?"
            fi
            if [[ -f "${HID_PATH}.bak" ]]; then
                mv "${HID_PATH}.bak" "$HID_PATH"
                echo "Restored original hid.dll from backup."
            fi
        else
            echo "ACC install path not recorded. Cannot remove hook automatically."
            echo "Manually delete: <ACC_DIR>/AC2/Binaries/Win64/hid.dll"
        fi
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Locate Proton binary
# ---------------------------------------------------------------------------
find_proton() {
    local search=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/"*
        "${HOME}/.steam/root/compatibilitytools.d/"*
        "${HOME}/.local/share/Steam/compatibilitytools.d/"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Proton"*
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/"*
    )
    for pattern in "${search[@]}"; do
        for d in $pattern; do
            [[ -d "$d" ]] || continue
            if [[ -f "$d/proton" ]]; then
                echo "$d/proton"
                return 0
            fi
        done
    done
    return 1
}

PROTON=$(find_proton)
if [[ -z "$PROTON" ]]; then
    echo "ERROR: Could not find Proton."
    echo "In Steam: Settings → Compatibility → Enable Steam Play for all titles."
    echo "Install at least one Proton version, then re-run this launcher."
    exit 1
fi

COMPATDATA="${STEAM_DIR}/steamapps/compatdata/${ACC_APPID}"
if [[ ! -d "$COMPATDATA" ]]; then
    echo "ERROR: ACC Proton compatdata not found at: $COMPATDATA"
    echo "Launch ACC via Steam at least once with Proton enabled, then retry."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the Windows path for the EXE
# Wine maps Z: to the Linux filesystem root (/).
#   /home/user/.local/share/acc-connector/app/ACC Connector.exe
#   → Z:\home\user\.local\share\acc-connector\app\ACC Connector.exe
# ---------------------------------------------------------------------------
GUI_EXE_ABS=$(realpath "$GUI_EXE")
WIN_PATH="Z:${GUI_EXE_ABS//\//\\}"

echo "Steam:       $STEAM_DIR"
echo "Proton:      $(basename "$(dirname "$PROTON")")"
echo "Compat data: $COMPATDATA"
echo "EXE:         $GUI_EXE_ABS"
echo ""

# ---------------------------------------------------------------------------
# Launch — GUI runs inside ACC's Proton prefix for shared named-pipe IPC
# ---------------------------------------------------------------------------
export STEAM_COMPAT_DATA_PATH="$COMPATDATA"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR"
exec "$PROTON" run "$WIN_PATH" ${@+"$@"}
LAUNCHSCRIPT

    chmod +x "$launch_script"
    success "Launch script created: $launch_script"

    # -------------------------------------------------------------------------
    # test-env.sh — quick sanity-check for the user's setup
    # -------------------------------------------------------------------------
    cat > "${ACC_CONNECTOR_HOME}/test-env.sh" <<'TESTSCRIPT'
#!/bin/bash
echo "=== ACC Connector Environment Check ==="
echo ""

CONNECTOR_DIR="${HOME}/.local/share/acc-connector"

# Locate Steam
STEAM_DIR=""
for c in \
        "${HOME}/.local/share/Steam" \
        "${HOME}/.steam/steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam" \
        "${HOME}/snap/steam/common/.steam/steam"; do
    if [[ -d "$c" ]]; then STEAM_DIR="$c"; break; fi
done
echo "Steam:        ${STEAM_DIR:-NOT FOUND}"

# ACC Proton prefix
ACC_COMPAT="${STEAM_DIR:-~/.local/share/Steam}/steamapps/compatdata/805550"
if [[ -d "$ACC_COMPAT" ]]; then
    echo "ACC prefix:   $ACC_COMPAT  (OK)"
    echo "  system.reg: $([[ -f "$ACC_COMPAT/pfx/system.reg" ]] && echo YES || echo NO)"
    echo "  drive_c:    $([[ -d "$ACC_COMPAT/pfx/drive_c"   ]] && echo YES || echo NO)"
else
    echo "ACC prefix:   NOT FOUND at $ACC_COMPAT"
fi

# ACC game directory recorded by setup
ACC_GAME_DIR=$(cat "${CONNECTOR_DIR}/.acc_path" 2>/dev/null || echo "")
echo "ACC game dir: ${ACC_GAME_DIR:-NOT RECORDED (run setup-linux.sh again)}"
if [[ -n "$ACC_GAME_DIR" ]] && [[ -d "$ACC_GAME_DIR" ]]; then
    HID="${ACC_GAME_DIR}/AC2/Binaries/Win64/hid.dll"
    echo "  hid.dll:    $([[ -f "$HID" ]] && echo "INSTALLED (hook active)" || echo "NOT INSTALLED")"
fi

# Proton installations
echo ""
echo "Proton installations:"
found_any=false
for pattern in \
        "${STEAM_DIR:-~/.local/share/Steam}/steamapps/common/Proton"* \
        "${STEAM_DIR:-~/.local/share/Steam}/compatibilitytools.d/"* \
        "${HOME}/.steam/root/compatibilitytools.d/"* \
        "${HOME}/.local/share/Steam/compatibilitytools.d/"* \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Proton"* \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/"*; do
    for d in $pattern; do
        [[ -f "$d/proton" ]] || continue
        echo "  $(basename "$d")"
        found_any=true
    done
done
$found_any || echo "  NONE FOUND — install Proton via Steam"

# Application files
echo ""
echo "ACC Connector files in ${CONNECTOR_DIR}/app/:"
exe_ok=$([[ -f "${CONNECTOR_DIR}/app/ACC Connector.exe" ]] && echo "YES" || echo "NO")
hook_ok=$([[ -f "${CONNECTOR_DIR}/app/client-hooks.dll"  ]] && echo "YES" || echo "NO")
dll_count=$(find "${CONNECTOR_DIR}/app" -name "*.dll" -type f 2>/dev/null | wc -l)
echo "  ACC Connector.exe: $exe_ok"
echo "  client-hooks.dll:  $hook_ok"
if (( dll_count >= 10 )); then
    echo "  Total DLLs:        $dll_count  (self-contained — .NET runtime included)"
else
    echo "  Total DLLs:        $dll_count  (may need .NET 8 installed in Proton prefix)"
fi

echo ""
echo "=== Done ==="
TESTSCRIPT
    chmod +x "${ACC_CONNECTOR_HOME}/test-env.sh"
    success "Test script created: ${ACC_CONNECTOR_HOME}/test-env.sh"
}

# =============================================================================
# create_desktop_integration — .desktop files for launcher + protocol handler
# =============================================================================
create_desktop_integration() {
    step "Step 6: Creating desktop integration"

    local desktop_dir="${HOME}/.local/share/applications"
    mkdir -p "$desktop_dir"

    local icon_path="${ACC_CONNECTOR_HOME}/acc-connector.png"
    local launch_script="${ACC_CONNECTOR_HOME}/acc-connector.sh"

    # Application launcher
    cat > "${desktop_dir}/acc-connector.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=ACC Connector
Comment=Direct IP connection tool for Assetto Corsa Competizione
Exec=${launch_script}
Icon=${icon_path}
Categories=Game;Utility;
Terminal=false
X-GNOME-Autostart-enabled=false
DESKTOP

    # acc-connect:// protocol handler
    cat > "${desktop_dir}/acc-connector-protocol.desktop" <<PROTDESKTOP
[Desktop Entry]
Type=Application
Name=ACC Connector Protocol Handler
Exec=${launch_script} %u
MimeType=x-scheme-handler/acc-connect
NoDisplay=true
Terminal=false
PROTDESKTOP

    success "Desktop entries created in $desktop_dir"
}

# =============================================================================
# register_protocol_handler — xdg-mime acc-connect://
# =============================================================================
register_protocol_handler() {
    step "Step 7: Registering acc-connect:// protocol handler"

    if command -v xdg-mime &>/dev/null; then
        if xdg-mime default acc-connector-protocol.desktop \
                x-scheme-handler/acc-connect 2>/dev/null; then
            success "Protocol handler registered (acc-connect:// links will open ACC Connector)"
        else
            warn "xdg-mime registration failed — the .desktop file is still in place."
            warn "Many browsers detect it automatically; or register manually with:"
            warn "  xdg-mime default acc-connector-protocol.desktop x-scheme-handler/acc-connect"
        fi
    else
        warn "xdg-utils not found — skipping automatic protocol registration."
        warn "Install xdg-utils and run:"
        warn "  xdg-mime default acc-connector-protocol.desktop x-scheme-handler/acc-connect"
    fi
}

# =============================================================================
# print_instructions — summary and troubleshooting at the end
# =============================================================================
print_instructions() {
    step "Setup Complete!"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ACC Connector is installed!"
    echo ""
    echo "  How to use:"
    echo "   1. Make sure Steam is running"
    echo "   2. Launch ACC Connector:"
    echo "        ${ACC_CONNECTOR_HOME}/acc-connector.sh"
    echo "   3. Add servers manually, or click an acc-connect:// link in your browser"
    echo "   4. Start ACC via Steam, then open LAN SERVERS to find the listed servers"
    echo ""
    echo "  Verify your setup:"
    echo "      ${ACC_CONNECTOR_HOME}/test-env.sh"
    echo ""
    echo "  Uninstall the hook DLL (restore hid.dll):"
    echo "      ${ACC_CONNECTOR_HOME}/acc-connector.sh --uninstall-hook"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    warn "TROUBLESHOOTING"
    echo ""

    if [[ "$DOTNET_NEEDED" == "true" ]]; then
        cat <<DOTNET_WARN
  ⚠️  .NET 8 runtime may be required
     ──────────────────────────────────
     The extracted build has fewer than 10 DLLs and is probably not
     self-contained. The .NET 8 Windows runtime must be present in
     ACC's Proton prefix for the GUI to start.

     Option A — Install automatically via protontricks (if available):
       protontricks ${ACC_APPID} dotnet80

     Option B — Install manually:
       Download the .NET 8 Desktop Runtime (win-x64) from:
         https://dotnet.microsoft.com/en-us/download/dotnet/8.0
       Then run the installer through Proton:
         export STEAM_COMPAT_DATA_PATH="${ACC_COMPATDATA:-~/.local/share/Steam/steamapps/compatdata/${ACC_APPID}}"
         export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_DIR:-~/.local/share/Steam}"
         <proton_binary> run dotnet-desktop-runtime-8.0.x-win-x64.exe

DOTNET_WARN
    fi

    cat <<TROUBLE
  ⚠️  GUI does not start / named pipe error
     ─────────────────────────────────────────
     The hook DLL (inside ACC) and the GUI communicate via a Windows
     named pipe. Both MUST run in the same Proton prefix. The launch
     script handles this by setting STEAM_COMPAT_DATA_PATH to ACC's
     compatdata. Do NOT run the GUI through a separate Wine prefix.

  ⚠️  Proton version compatibility
     ─────────────────────────────────
     Proton 9+ is recommended for the best WinForms / .NET support.
     In Steam: right-click ACC → Properties → Compatibility →
     Force a specific Proton version (choose 9.x or newer).

  ⚠️  Steam must be running
     ──────────────────────────
     Proton requires the Steam client to be open in the background.

  ⚠️  Flatpak Steam users
     ──────────────────────
     The Proton binary bundled with Flatpak Steam runs inside the
     Flatpak sandbox. If the launcher fails to find or invoke Proton,
     try running acc-connector.sh from inside the Flatpak shell:
       flatpak run --command=bash com.valvesoftware.Steam
       ${ACC_CONNECTOR_HOME}/acc-connector.sh

TROUBLE

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           ACC Connector — Linux Setup                   ║"
    echo "  ║      Running Windows binaries through Proton/Wine        ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    download_release
    extract_installer   || true   # continue even if extraction is partial
    deploy_hook         || true   # continue — user may need to do this manually
    create_launcher
    create_desktop_integration
    register_protocol_handler
    print_instructions
}

main "$@"

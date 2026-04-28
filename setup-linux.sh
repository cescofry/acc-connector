#!/bin/bash
# =============================================================================
#  ACC Connector - Linux Setup Script (for Bazzite / Fedora-based distros)
# =============================================================================
#  This script automates the setup of ACC Connector on Linux by running the
#  Windows binaries inside ACC's Proton (Wine) prefix.
#
#  What this script does:
#   1. Checks prerequisites (Steam, ACC, required tools)
#   2. Downloads the latest ACC Connector Windows release from GitHub
#   3. Deploys the hook DLL into ACC's game directory inside Proton
#   4. Sets up a Proton runtime for the GUI inside ACC's Proton prefix
#   5. Creates launch scripts & desktop integration
#   6. Registers the acc-connect:// protocol handler
#
#  What you may need to do manually:
#   - If the Proton runtime doesn't support WinForms properly, you'll need
#     to install dotnet8 in the prefix (instructions provided at the end)
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

# Locate Steam/Proton paths
find_steam_paths() {
    # Try common Steam locations
    local steam_dirs=(
        "${HOME}/.steam/steam"
        "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam"
        "${HOME}/.local/share/Steam"
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam"
    )
    for d in "${steam_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            STEAM_DIR="$d"
            success "Found Steam at $STEAM_DIR"
            break
        fi
    done
    if [[ -z "${STEAM_DIR:-}" ]]; then
        error "Could not find Steam installation."
        error "Please set STEAM_DIR manually in this script."
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

    # Find Proton binary
    local proton_dirs=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/Proton"*
        "${HOME}/.steam/root/compatibilitytools.d/Proton"*
    )
    PROTON_BIN=""
    for pd in "${proton_dirs[@]}"; do
        # Expand globs
        for d in $pd; do
            if [[ -f "$d/proton" ]]; then
                PROTON_BIN="$d/proton"
                break 3
            fi
        done
    done
    if [[ -z "$PROTON_BIN" ]]; then
        warn "Could not automatically find Proton binary."
        warn "Will search in common locations at launch time."
        PROTON_BIN=""  # Will be resolved at runtime
    else
        # Get just the directory name for display
        local proton_ver
        proton_ver=$(basename "$(dirname "$PROTON_BIN")")
        success "Found Proton: ${proton_ver}"
    fi
}

# Check prerequisites
check_prerequisites() {
    step "Step 1: Checking prerequisites"

    local missing=()

    if ! command -v curl &>/dev/null; then missing+=("curl"); fi
    if ! command -v jq &>/dev/null; then missing+=("jq"); fi
    if ! command -v unzip &>/dev/null; then missing+=("unzip"); fi
    if ! command -v python3 &>/dev/null; then missing+=("python3"); fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required packages: ${missing[*]}"
        echo ""
        echo "On Bazzite / Fedora, install them with:"
        echo "  sudo dnf install curl jq unzip python3"
        echo ""
        echo "On Arch-based (non-Bazzite):"
        echo "  sudo pacman -S curl jq unzip python3"
        exit 1
    fi
    success "All prerequisites found"

    find_steam_paths

    # Verify ACC is installed (check for appmanifest file)
    local acc_manifest=""
    local acc_manifests=(
        "${STEAM_DIR}/steamapps/appmanifest_${ACC_APPID}.acf"
        "${STEAM_DIR}/steamapps/compatdata/${ACC_APPID}"
    )
    for m in "${acc_manifests[@]}"; do
        if [[ -e "$m" ]]; then
            acc_manifest="$m"
            break
        fi
    done

    if [[ -z "$acc_manifest" ]]; then
        warn "No appmanifest found for ACC (App ID ${ACC_APPID})"
        warn "This is fine if you launched ACC at least once via Proton."
    fi
}

# Download latest release
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
        echo "You can manually download the installer from:"
        echo "  https://github.com/${REPO}/releases"
        echo "Then extract it manually and re-run this script."
        exit 1
    fi
    info "Latest version: $tag_name"

    # Find the installer asset
    local installer_url
    installer_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("Setup.*\\.exe$")) | .browser_download_url' | head -1)

    if [[ -z "$installer_url" || "$installer_url" == "null" ]]; then
        error "No installer EXE found in the release."
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
    curl -L -o "$installer_file" "$installer_url"

    if [[ ! -f "$installer_file" ]]; then
        error "Download failed."
        exit 1
    fi

    success "Downloaded installer to $installer_file"
    ACC_CONNECTOR_VERSION="$tag_name"
    echo "$tag_name" > "$version_file"
}

# Extract files from the Inno Setup installer (without running it)
extract_installer() {
    step "Step 3: Extracting files from installer"

    local extract_dir="${ACC_CONNECTOR_HOME}/app"
    local installer_file="${ACC_CONNECTOR_HOME}/ACC-Connector-Setup.exe"

    mkdir -p "$extract_dir"

    # Check if the GUI EXE already exists (may have been extracted before)
    local gui_exe
    gui_exe=$(find "$extract_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
    if [[ -n "$gui_exe" ]]; then
        info "Files already extracted. Skipping."
        return
    fi

    # Try to install innoextract if not available
    if ! command -v innoextract &>/dev/null; then
        info "innoextract not found. Attempting to install it..."

        # Try system package manager first
        if command -v dnf &>/dev/null; then
            sudo dnf install -y innoextract 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y innoextract 2>/dev/null || true
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm innoextract 2>/dev/null || true
        fi

        # Fall back to pip
        if ! command -v innoextract &>/dev/null; then
            pip3 install innoextract 2>/dev/null || pip install innoextract 2>/dev/null || true
        fi
    fi

    if command -v innoextract &>/dev/null; then
        info "Extracting files from Inno Setup installer using innoextract..."
        local temp_dir="${ACC_CONNECTOR_HOME}/_temp"
        mkdir -p "$temp_dir"

        if innoextract -q "$installer_file" -d "$temp_dir" 2>/dev/null; then
            # Copy relevant files from the extracted tree to the flat app dir
            info "Extraction successful. Reorganizing files..."

            # Copy ACC Connector.exe
            find "$temp_dir" -name "ACC Connector.exe" -exec cp {} "$extract_dir/" \; 2>/dev/null || true

            # Copy all DLLs (including client-hooks.dll)
            find "$temp_dir" -name "*.dll" -exec cp {} "$extract_dir/" \; 2>/dev/null || true

            # Copy all JSON files (runtimeconfig, deps, etc.)
            find "$temp_dir" -name "*.json" -exec cp {} "$extract_dir/" \; 2>/dev/null || true

            # Copy license files
            for f in "$temp_dir"/**/LICENSE.txt "$temp_dir"/**/THIRD_PARTY_LICENSES.txt; do
                [[ -f "$f" ]] && cp "$f" "$extract_dir/" || true
            done

            # Clean up temp
            rm -rf "$temp_dir"
        else
            warn "innoextract failed. Trying to use it with --list to understand layout..."
            rm -rf "$temp_dir"
        fi
    fi

    # Verify extraction
    local gui_exe_check
    gui_exe_check=$(find "$extract_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
    if [[ -n "$gui_exe_check" ]]; then
        success "ACC Connector.exe found in: $extract_dir"
    else
        warn ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn "  Could not extract the installer automatically."
        warn "  The publisher is published as self-contained (includes all"
        warn "  .NET runtime DLLs), so you need all files from the installer."
        warn ""
        warn "  MANUAL STEP REQUIRED:"
        warn ""
        warn "  Option A — Try installing innoextract manually, then"
        warn "             re-run this script:"
        warn "      pip3 install --user innoextract"
        warn "      innoextract \"${installer_file}\" -d \"${extract_dir}\""
        warn ""
        warn "  Option B — On Windows, run the installer and copy files:"
        warn "      From: C:\\Program Files\\ACC Connector\\"
        warn "      To:   ${extract_dir}/"
        warn "      Copy ALL .exe, .dll, .json files + LICENSE.txt"
        warn ""
        warn "  Option C — Use 7z/wine to run the installer:"
        warn "      cd ${extract_dir} && wine \"${installer_file}\" /VERYSILENT"
        warn ""
        warn "  After copying, re-run this script."
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn ""
        # Don't exit — let the script continue so other steps can run
    fi
}

# Deploy the hook DLL to ACC's game directory inside Proton
deploy_hook() {
    step "Step 4: Deploying hook DLL"

    local app_dir="${ACC_CONNECTOR_HOME}/app"
    local hook_dll="${app_dir}/client-hooks.dll"

    # Find the hook DLL
    if [[ ! -f "$hook_dll" ]]; then
        # Look in subdirectories of extracted files
        hook_dll=$(find "$app_dir" -name "client-hooks.dll" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$hook_dll" || ! -f "$hook_dll" ]]; then
        error "Hook DLL (client-hooks.dll) not found in $app_dir"
        error "Make sure the installer was extracted properly."
        exit 1
    fi
    success "Found hook DLL: $hook_dll"

    # Find ACC's game directory inside the Proton prefix
    local acc_game_dir=""
    local acc_search_paths=(
        "${ACC_PREFIX}/drive_c/Program Files (x86)/Steam/steamapps/common/Assetto Corsa Competizione"
        "${ACC_PREFIX}/drive_c/Program Files/Steam/steamapps/common/Assetto Corsa Competizione"
        "${STEAM_DIR}/steamapps/common/Assetto Corsa Competizione"
    )

    # Also try reading the VDF manifest for the actual install directory name
    local vdf_path="${STEAM_DIR}/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf_path" ]]; then
        info "Looking for ACC in Steam libraries..."
        # Simple grep approach for finding ACC in libraryfolders
        local acc_path_native
        acc_path_native=$(python3 -c "
import re
with open('${vdf_path}', 'r') as f:
    content = f.read()
# Extract all library paths
paths = re.findall(r'\"path\"\s+\"([^\"]+)\"', content)
for p in paths:
    print(p)
" 2>/dev/null)
        if [[ -n "$acc_path_native" ]]; then
            while IFS= read -r lib; do
                local candidate="${lib}/steamapps/common"
                if [[ -d "$candidate" ]]; then
                    for dir in "$candidate"/*; do
                        if [[ -d "$dir" ]] && [[ -f "$dir/AC2/Binaries/Win64/AC2-Win64-Shipping.exe" ]]; then
                            acc_game_dir="$dir"
                            break 2
                        fi
                    done
                fi
            done <<< "$acc_path_native"
        fi
    fi

    # If native path found, prefer it (Proton maps Z: to / by default)
    if [[ -z "$acc_game_dir" ]]; then
        for p in "${acc_search_paths[@]}"; do
            if [[ -d "$p" ]] && [[ -f "$p/AC2/Binaries/Win64/AC2-Win64-Shipping.exe" ]]; then
                acc_game_dir="$p"
                break
            fi
        done
    fi

    if [[ -z "$acc_game_dir" ]]; then
        warn "Could not automatically find ACC install directory."
        warn "Searching inside Proton prefix..."

        local found
        found=$(find "${ACC_PREFIX}/drive_c" -path "*/AC2/Binaries/Win64/AC2-Win64-Shipping.exe" -type f 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            acc_game_dir="$(dirname "$(dirname "$(dirname "$(dirname "$found")")")")"
            success "Found ACC at: $acc_game_dir"
        fi
    fi

    if [[ -z "$acc_game_dir" ]]; then
        warn ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn "  Could not locate ACC install directory automatically."
        warn ""
        warn "  MANUAL STEP REQUIRED:"
        warn "  Find your ACC installation and copy the hook DLL there:"
        warn ""
        warn "    cp '${hook_dll}' '<ACC_DIR>/AC2/Binaries/Win64/hid.dll'"
        warn ""
        warn "  Where <ACC_DIR> is the path that contains 'AC2/Binaries/Win64/'."
        warn "  Common locations:"
        warn "    - Inside Proton prefix: ${ACC_PREFIX}/drive_c/Program Files*/Steam/steamapps/common/*ACC*"
        warn "    - Native Steam library: ${HOME}/.steam/steam/steamapps/common"
        warn ""
        warn "  After copying, re-run this script to continue."
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn ""

        # Save the found path for the user
        ACC_GAME_DIR=$(echo "$acc_game_dir" || echo "")
        echo "$ACC_GAME_DIR" > "${ACC_CONNECTOR_HOME}/.acc_path"
        return 1
    fi

    # Now copy the hook DLL as hid.dll
    local hid_dll_path="${acc_game_dir}/AC2/Binaries/Win64/hid.dll"

    # Backup existing hid.dll if it's the real one (not our hook)
    if [[ -f "$hid_dll_path" ]]; then
        local hash_ours hash_existing
        hash_ours=$(md5sum "$hook_dll" 2>/dev/null | cut -d' ' -f1)
        hash_existing=$(md5sum "$hid_dll_path" 2>/dev/null | cut -d' ' -f1)
        if [[ "$hash_ours" == "$hash_existing" ]]; then
            success "Hook DLL already installed: $hid_dll_path"
            ACC_GAME_DIR="$acc_game_dir"
            echo "$ACC_GAME_DIR" > "${ACC_CONNECTOR_HOME}/.acc_path"
            return
        fi
        info "Backing up existing hid.dll as hid.dll.bak"
        cp "$hid_dll_path" "${hid_dll_path}.bak" 2>/dev/null || true
    fi

    cp "$hook_dll" "$hid_dll_path"
    success "Hook DLL installed: $hid_dll_path"
    ACC_GAME_DIR="$acc_game_dir"
    echo "$ACC_GAME_DIR" > "${ACC_CONNECTOR_HOME}/.acc_path"
}

# Find the Proton binary (runtime resolution)
find_proton() {
    if [[ -n "${PROTON_BIN:-}" ]] && [[ -f "$PROTON_BIN" ]]; then
        echo "$PROTON_BIN"
        return
    fi

    local proton_dirs=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/"*
        "${HOME}/.steam/root/compatibilitytools.d/"*
    )

    for pattern in "${proton_dirs[@]}"; do
        for d in $pattern; do
            if [[ -f "$d/proton" ]]; then
                PROTON_BIN="$d/proton"
                echo "$PROTON_BIN"
                return
            fi
        done
    done

    warn "Proton binary not found."
    warn "You may need to set it manually before launching."
}

# Create the launch script
create_launcher() {
    step "Step 5: Creating launch scripts"

    local launch_script="${ACC_CONNECTOR_HOME}/acc-connector.sh"
    local app_dir="${ACC_CONNECTOR_HOME}/app"

    # Find the GUI executable
    local gui_exe
    gui_exe=$(find "$app_dir" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)

    if [[ -z "$gui_exe" ]]; then
        warn "GUI executable not found in $app_dir"
        warn "This might be in a subdirectory - check and update the launch script."
        gui_exe="${app_dir}/ACC Connector.exe"
    fi

    cat > "$launch_script" <<'LAUNCHSCRIPT'
#!/bin/bash
# ACC Connector launcher script
# Runs the Windows GUI inside ACC's Proton prefix for proper IPC

ACC_APPID=805550

# Try to determine Steam directory
for candidate in "${HOME}/.local/share/Steam" "${HOME}/.steam/steam" \
                  "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam"; do
    if [[ -d "$candidate" ]]; then
        STEAM_DIR="$candidate"
        break
    fi
done

ACC_CONNECTOR_DIR="${HOME}/.local/share/acc-connector"
APP_DIR="${ACC_CONNECTOR_DIR}/app"

# Locate GUI executable
GUI_EXE=$(find "$APP_DIR" -name "ACC Connector.exe" -type f 2>/dev/null | head -1)
if [[ -z "$GUI_EXE" ]]; then
    echo "ERROR: Could not find ACC Connector.exe in $APP_DIR"
    echo "Make sure you have extracted the installer files there."
    exit 1
fi

case "${1:-}" in
    --uninstall-hook)
        echo "Removing hook DLL..."
        ACC_GAME_DIR=$(cat "${ACC_CONNECTOR_DIR}/.acc_path" 2>/dev/null || echo "")
        if [[ -n "$ACC_GAME_DIR" ]]; then
            rm -f "${ACC_GAME_DIR}/AC2/Binaries/Win64/hid.dll"
            echo "Hook removed from ${ACC_GAME_DIR}/AC2/Binaries/Win64/hid.dll"
        else
            echo "ACC install path not known. Cannot remove hook."
        fi
        exit 0
        ;;
esac

# Find Proton
find_proton() {
    local proton_dirs=(
        "${STEAM_DIR}/steamapps/common/Proton"*
        "${STEAM_DIR}/compatibilitytools.d/"*
        "${HOME}/.steam/root/compatibilitytools.d/"*
    )
    for pattern in "${proton_dirs[@]}"; do
        for d in $pattern; do
            if [[ -f "$d/proton" ]]; then
                echo "$d/proton"
                return
            fi
        done
    done
}

PROTON=$(find_proton)
if [[ -z "$PROTON" ]]; then
    echo "ERROR: Could not find Proton."
    echo "Please install Proton via Steam (enable Steam Play for all titles)."
    exit 1
fi

COMPATDATA="${STEAM_DIR}/steamapps/compatdata/${ACC_APPID}"

if [[ ! -d "$COMPATDATA" ]]; then
    echo "ERROR: ACC Proton compatdata not found at $COMPATDATA"
    echo "Make sure ACC has been launched at least once with Proton enabled."
    exit 1
fi

# Resolve the GUI_EXE path to its Windows path within the prefix
# Wine maps Z: to / — so we convert the Linux path to a Z:-style Windows path
# e.g., /home/user/.local/share/acc-connector/app/... -> Z:\home\user\...
GUI_EXE_PATH=$(realpath "$GUI_EXE")
WIN_PATH="Z:${GUI_EXE_PATH//\//\\}"

# If the EXE is inside the Proton drive_c, use the internal C: path
PREFIX_DRIVE_C="${COMPATDATA}/pfx/drive_c"
if [[ "$GUI_EXE_PATH" == "${COMPATDATA}/"* ]]; then
    # It's inside the prefix, resolve to C:\...
    REL_PATH="${GUI_EXE_PATH#$PREFIX_DRIVE_C/}"
    WIN_PATH="C:\\\\${REL_PATH//\//\\\\}"
fi

echo "Using Proton: $(basename "$(dirname "$PROTON")")"
echo "Compat data: $COMPATDATA"
echo "GUI EXE:     $GUI_EXE_PATH"
echo "Win Path:    $WIN_PATH"

# Launch the GUI
STEAM_COMPAT_DATA_PATH="$COMPATDATA" \
STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR" \
    "$PROTON" run "$WIN_PATH" ${@+"$@"}
LAUNCHSCRIPT

    chmod +x "$launch_script"
    success "Launch script created: $launch_script"

    # Create a simple test script to check
    cat > "${ACC_CONNECTOR_HOME}/test-env.sh" <<'TESTSCRIPT'
#!/bin/bash
# Test the environment
echo "=== ACC Connector Environment Test ==="
echo "ACC Connector Home: ${HOME}/.local/share/acc-connector"
echo ""

ACC_COMPAT="${HOME}/.local/share/Steam/steamapps/compatdata/805550"

if [[ -d "$ACC_COMPAT" ]]; then
    echo "ACC Proton prefix exists at: $ACC_COMPAT"
    echo "  - system.reg: $([[ -f "$ACC_COMPAT/pfx/system.reg" ]] && echo "YES" || echo "NO")"
    echo "  - drive_c:    $([[ -d "$ACC_COMPAT/pfx/drive_c" ]] && echo "YES" || echo "NO")"
else
    echo "WARNING: ACC Proton prefix not found."
fi

echo ""
echo "Looking for Proton..."
for pattern in "${HOME}/.local/share/Steam/steamapps/common/Proton"* \
               "${HOME}/.local/share/Steam/compatibilitytools.d/"*; do
    for d in $pattern; do
        if [[ -f "$d/proton" ]]; then
            echo "  Found: $(basename "$d")"
            break
        fi
    done
done

echo ""
echo "Looking for ACC Connector binaries..."
ls -la "${HOME}/.local/share/acc-connector/app/"*.exe 2>/dev/null || echo "  No EXE files found in app dir"
ls -la "${HOME}/.local/share/acc-connector/app/"*.dll 2>/dev/null | head -5 || echo "  No DLL files found"

echo ""
echo "=== Done ==="
TESTSCRIPT
    chmod +x "${ACC_CONNECTOR_HOME}/test-env.sh"
    success "Test script created: ${ACC_CONNECTOR_HOME}/test-env.sh"
}

# Create desktop integration
create_desktop_integration() {
    step "Step 6: Creating desktop integration"

    local desktop_dir="${HOME}/.local/share/applications"
    mkdir -p "$desktop_dir"

    local icon_path="${ACC_CONNECTOR_HOME}/acc-connector.png"
    local launch_script="${ACC_CONNECTOR_HOME}/acc-connector.sh"

    # Desktop entry for launching the app
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

    # Protocol handler desktop entry
    cat > "${desktop_dir}/acc-connector-protocol.desktop" <<PROTDESKTOP
[Desktop Entry]
Type=Application
Name=ACC Connector Protocol Handler
Exec=${launch_script} %u
MimeType=x-scheme-handler/acc-connect
NoDisplay=true
Terminal=false
PROTDESKTOP

    success "Desktop entries created"
}

# Register protocol handler
register_protocol_handler() {
    step "Step 7: Registering acc-connect:// protocol"

    if command -v xdg-mime &>/dev/null; then
        xdg-mime default acc-connector-protocol.desktop x-scheme-handler/acc-connect 2>/dev/null || {
            warn "xdg-mime registration failed — this is ok, desktop file is still valid"
        }
    fi

    success "Protocol handler registration attempted (acc-connect:// links should work)"
}

# Final instructions
print_instructions() {
    step "Setup Complete!"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ACC Connector is now set up!"
    echo ""
    echo "  🚀 To launch:"
    echo "     ${ACC_CONNECTOR_HOME}/acc-connector.sh"
    echo ""
    echo "  🧪 To test the environment:"
    echo "     ${ACC_CONNECTOR_HOME}/test-env.sh"
    echo ""
    echo "  📁 Config & data are stored at:"
    echo "     ${ACC_CONNECTOR_HOME}/"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    warn ""
    warn "IMPORTANT — Potential issues and troubleshooting:"
    warn ""

    cat <<TROUBLE

  ⚠️  Issue 1: Windows Forms (.NET) may not work in Proton/Wine
     ───────────────────────────────────────────────────────
     ACC Connector uses .NET 8 Windows Forms. Proton may not
     include the .NET runtime by default. If launching fails:

     Solution A — Install dotnet in the ACC Proton prefix:
       PROTON="\$(find ~/.local/share/Steam/steamapps/common/Proton* -name proton | head -1)"
       WINEPREFIX="\${HOME}/.local/share/Steam/steamapps/compatdata/805550/pfx"
       WINEPREFIX="\$WINEPREFIX" "\$PROTON" run wineboot -u
       
       Then download and install the .NET 8 Desktop Runtime (x64):
       https://dotnet.microsoft.com/en-us/download/dotnet/8.0
       Run the installer EXE through Proton in the same prefix.

     Solution B — Use the publish output (self-contained build):
       If the published output is truly self-contained (includes
       all .NET DLLs), no extra .NET installation is needed.
       Check if the publish folder has 50+ DLL files — if yes,
       it's self-contained and should "just work".

  ⚠️  Issue 2: Named pipe IPC must share the Proton prefix
     ──────────────────────────────────────────────────────
     The hook DLL (inside ACC process) connects to the GUI via
     a Windows named pipe. Both MUST run in the SAME Proton
     prefix. This script ensures that by using ACC's own
     compatdata directory.

     ✓ The launch script automatically uses ACC's compatdata.

  ⚠️  Issue 3: Proton version compatibility
     ────────────────────────────────────────
     Proton 9+ has better WinForms/.NET support.
     Ensure Steam Play is enabled and a recent Proton version
     is selected for ACC.

  ⚠️  Issue 4: Steam must be running
     ───────────────────────────────
     Proton needs the Steam client running in the background
     for license checks and runtime dependencies.

TROUBLE

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enjoy direct IP racing on Linux! 🏎️"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =========================================================================
# Main execution
# =========================================================================

main() {
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║           ACC Connector — Linux Setup                   ║"
    echo "  ║      Running Windows binaries through Proton/Wine        ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    download_release
    extract_installer || true  # Continue even if extraction partially works
    deploy_hook || true       # Don't fail — user may need manual steps
    create_launcher
    create_desktop_integration
    register_protocol_handler
    print_instructions
}

# Run
main "$@"
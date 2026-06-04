#!/usr/bin/env bash
# g14-hdr-fix — enable HDR detection on ASUS ROG Zephyrus G14 (2024+) under Linux
#
# The 2024+ G14 (Samsung ATNA40CU05-0 OLED) stores its HDR metadata inside a
# DisplayID v2.0 EDID extension. libdisplay-info 0.3.x — used by KWin, Mutter,
# wlroots, etc. — doesn't parse DisplayID data blocks, so compositors see the
# display as HDR-incapable. This script installs an EDID firmware override
# that appends a standard CTA-861 extension containing the same HDR static
# metadata (and the 120 Hz DTD), which every compositor reads correctly.
#
# Safe to run multiple times. See uninstall.sh to revert.

set -euo pipefail

CONST_MKINITCPIO="mkinitcpio"
CONST_DRACUT_R="dracut-rebuild"
CONST_DRACUT="dracut"

FIRMWARE_DIR="/lib/firmware/edid"
FIRMWARE_FILE="g14_hdr_edid.bin"
FIRMWARE_PATH="${FIRMWARE_DIR}/${FIRMWARE_FILE}"

MKINITCPIO_CONF="/etc/mkinitcpio.conf"
DRACUT_CONF_F="/etc/dracut.conf.d"

LIMINE_DEFAULT="/etc/default/limine"

HOOK_DIR="/etc/pacman.d/hooks"
HOOK_PATH="${HOOK_DIR}/g14-hdr-fix.hook"
HELPER_DIR="/usr/local/share/g14-hdr-fix"
HELPER_PATH="${HELPER_DIR}/post-transaction.sh"
MIN_FIXED_VERSION="0.4.0"
KERNEL_PARAM=""  # set after connector detection

c_red=$'\e[31m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_blue=$'\e[34m'; c_reset=$'\e[0m'
log()  { printf '%s[*]%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo $0)"
}

detect_connector() {
    # Find the connected eDP connector on the dGPU (the panel)
    for c in /sys/class/drm/card*-eDP-*; do
        [[ -e "$c/status" ]] || continue
        if [[ "$(cat "$c/status")" == "connected" ]]; then
            basename "$c" | sed 's/^card[0-9]*-//'
            return 0
        fi
    done
    return 1
}

verify_display() {
    local edid="$1"
    # Samsung SDC manufacturer code + ATNA40CU05 product name
    if ! edid-decode < "$edid" 2>/dev/null | grep -q "ATNA40CU05"; then
        warn "This doesn't look like the Samsung ATNA40CU05-0 panel."
        warn "This script targets the 2024+ ASUS ROG Zephyrus G14 OLED."
        read -r -p "Continue anyway? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || die "Aborted."
    fi
    if ! edid-decode < "$edid" 2>/dev/null | grep -q "SMPTE ST2084"; then
        die "EDID has no SMPTE ST2084 support — display isn't HDR capable."
    fi
}

build_edid() {
    local input_edid="$1"
    local output_path="$2"

    python3 - "$input_edid" "$output_path" <<'PYEOF'
import sys, os

input_path, output_path = sys.argv[1], sys.argv[2]
raw = open(input_path, 'rb').read()
if len(raw) < 128:
    sys.exit("EDID too short")

# Keep original base block; force extension count to 1 (single CTA ext)
base = bytearray(raw[0:128])
base[0x7E] = 0x01
base[0x7F] = 0
base[0x7F] = (256 - (sum(base) % 256)) % 256
assert sum(base) % 256 == 0

# Parse HDR metadata from edid-decode output of the original EDID
import subprocess
decoded = subprocess.check_output(['edid-decode'], input=raw, stderr=subprocess.DEVNULL).decode()

def find_lum(label):
    for line in decoded.splitlines():
        if label in line and 'cd/m^2' in line:
            # e.g. "Desired content max luminance: 116 (616.884 cd/m^2)"
            parts = line.split(':')[1].strip()
            raw_byte = int(parts.split()[0])
            return raw_byte
    return None

max_lum = find_lum("Desired content max luminance") or 116
max_avg = find_lum("Desired content max frame-average luminance") or 96
min_lum = find_lum("Desired content min luminance") or 2

# CTA-861 data blocks
# Colorimetry (ext tag 0x05): BT2020RGB (bit 7 of byte 1)
colorimetry = bytes([0xe3, 0x05, 0x80, 0x00])
# HDR Static Metadata (ext tag 0x06): SDR + SMPTE ST2084 EOTF, SM type 1
hdr_metadata = bytes([0xe6, 0x06, 0x05, 0x01, max_lum & 0xff, max_avg & 0xff, min_lum & 0xff])
data_blocks = colorimetry + hdr_metadata

# DTD for the panel's high-refresh mode. Values measured from the original
# DisplayID block on the Samsung ATNA40CU05-0 (2880x1800 @ 120 Hz).
dtd_120hz = bytes([
    0x8A, 0xFE,  # pixel clock 652260 kHz (/10 = 65226)
    0x40, 0x64, 0xB0,  # H: active 2880, blank 100
    0x08, 0x18, 0x70,  # V: active 1800, blank 24
    0x20, 0x08, 0x88, 0x00,  # H/V sync offsets and widths
    0x2E, 0xBD, 0x10,  # 302 mm x 189 mm
    0x00, 0x00, 0x18,  # no borders, digital separate sync N/N
])

dtd_offset = 4 + len(data_blocks)
cta = bytearray(128)
cta[0] = 0x02
cta[1] = 0x03
cta[2] = dtd_offset
cta[3] = 0x00
cta[4:4+len(data_blocks)] = data_blocks
cta[dtd_offset:dtd_offset+18] = dtd_120hz
cta[127] = (256 - (sum(cta[0:127]) % 256)) % 256
assert sum(cta) % 256 == 0

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, 'wb') as f:
    f.write(bytes(base) + bytes(cta))
print(f"HDR bytes: max={max_lum} avg={max_avg} min={min_lum}")
PYEOF
}

update_mkinitcpio() {
    local conf="$1" entry="$2"
    [[ -f "$conf" ]] || die "$conf not found"

    # Back up once
    [[ -f "${conf}.g14hdr.bak" ]] || cp "$conf" "${conf}.g14hdr.bak"

    if grep -q "$FIRMWARE_FILE" "$conf"; then
        log "mkinitcpio already has the firmware entry"
        return 0
    fi

    # Append entry to FILES=( ... )
    if grep -qE '^FILES=\(\s*\)' "$conf"; then
        sed -i "s|^FILES=(\s*)|FILES=($entry)|" "$conf"
    elif grep -qE '^FILES=\(' "$conf"; then
        sed -i "s|^FILES=(|FILES=($entry |" "$conf"
    else
        printf '\nFILES=(%s)\n' "$entry" >> "$conf"
    fi
    ok "Added $entry to $conf FILES="
}

update_dracut_conf() {
    local conf_dir="$1" entry="$2"
    [[ -d "$conf_dir" ]] || die "$conf_dir not found"

    # Check if configuration already exists
    local conf_file="${conf_dir}/g14-hdr.conf"

    echo "install_items+=\" $entry \"" > $conf_file

    ok "Added bin to $conf_file"
}

install_pacman_hook() {
    # Install a pacman ALPM hook that prints a notice when libdisplay-info is
    # upgraded to a version containing MR !202 (DisplayID v2 CTA-861 decoding).
    # Once that version ships, this workaround is no longer needed.
    mkdir -p "$HELPER_DIR" "$HOOK_DIR"

    cat > "$HELPER_PATH" <<HELPEREOF
#!/usr/bin/env bash
# Installed by g14-hdr-fix. Runs after libdisplay-info upgrades and prints a
# notice if the installed version contains the upstream DisplayID v2 fix,
# meaning this workaround can be removed.
set -eu
min_version="$MIN_FIXED_VERSION"
current=\$(pacman -Q libdisplay-info 2>/dev/null | awk '{print \$2}')
[[ -n "\$current" ]] || exit 0
if (( \$(vercmp "\$current" "\$min_version") >= 0 )); then
    printf '\n'
    printf '==> g14-hdr-fix: libdisplay-info %s contains the upstream DisplayID v2 fix.\n' "\$current"
    printf '    The EDID firmware override is no longer needed.\n'
    printf '    To remove the workaround, run: sudo /path/to/g14-hdr-fix/uninstall.sh\n'
    printf '    (or re-clone from https://github.com/cashcon57/g14-hdr-fix)\n\n'
fi
HELPEREOF
    chmod 0755 "$HELPER_PATH"

    cat > "$HOOK_PATH" <<HOOKEOF
# Installed by g14-hdr-fix. Notifies when libdisplay-info gains the upstream
# DisplayID v2 fix, so this workaround can be removed.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = libdisplay-info

[Action]
Description = Checking if g14-hdr-fix workaround is still needed...
When = PostTransaction
Exec = $HELPER_PATH
HOOKEOF
    chmod 0644 "$HOOK_PATH"
    ok "Installed pacman hook → $HOOK_PATH"
}

update_limine() {
    local conf="$1"
    [[ -f "$conf" ]] || die "$conf not found — is limine installed?"
    [[ -f "${conf}.g14hdr.bak" ]] || cp "$conf" "${conf}.g14hdr.bak"

    if grep -q "drm.edid_firmware=eDP-1:edid/${FIRMWARE_FILE}" "$conf"; then
        log "limine already has the kernel parameter"
        return 0
    fi

    printf '\n# Added by g14-hdr-fix\nKERNEL_CMDLINE[default]+="%s"\n' "$KERNEL_PARAM" >> "$conf"
    ok "Added $KERNEL_PARAM to $conf"
}

main() {
    require_root

    command -v edid-decode >/dev/null || die "Need 'edid-decode' (pacman -S edid-decode)"
    command -v python3 >/dev/null     || die "Need 'python3'"
    
    local boot_configurator=""
    if command -v mkinitcpio >/dev/null; then
        boot_configurator=$CONST_MKINITCPIO
    elif command -v which dracut-rebuild >/dev/null; then
        boot_configurator=$CONST_DRACUT_R
    elif command -v which dracut >/dev/null; then
        boot_configurator=$CONST_DRACUT
    else
        die "Need 'mkinitcpio' or 'dracut'"
    fi

    log "Detecting connected internal panel..."
    local connector
    connector=$(detect_connector) || die "No connected eDP panel found."
    ok "Found $connector"
    KERNEL_PARAM="drm.edid_firmware=${connector}:edid/${FIRMWARE_FILE}"

    local source_edid="/sys/class/drm/card*-${connector}/edid"
    # Expand glob
    source_edid=$(ls $source_edid 2>/dev/null | head -1) || true
    [[ -n "$source_edid" && -f "$source_edid" ]] || die "Cannot read EDID for $connector"

    log "Verifying display..."
    verify_display "$source_edid"

    log "Generating EDID firmware at ${FIRMWARE_PATH}"
    build_edid "$source_edid" "$FIRMWARE_PATH"
    chmod 0644 "$FIRMWARE_PATH"
    ok "Wrote $(wc -c < "$FIRMWARE_PATH") bytes"

    log "Installing pacman notification hook..."
    install_pacman_hook

    log "Updating ${boot_configurator} FILES..."
    if [[ "$boot_configurator" = "$CONST_MKINITCPIO" ]]; then
        update_mkinitcpio "$MKINITCPIO_CONF" "$FIRMWARE_PATH"
    elif [[ "$boot_configurator" = "$CONST_DRACUT" || "$boot_configurator" = "$CONST_DRACUT_R" ]]; then
        update_dracut_conf "$DRACUT_CONF_F" "$FIRMWARE_PATH"
    else
        die "Boot configurator (dracut or mkinicpio) not found"
    fi

    # FUTURE TODO: Add grub support
    log "Updating bootloader kernel cmdline..."
    if [[ -f "$LIMINE_DEFAULT" ]]; then
        update_limine "$LIMINE_DEFAULT"
    else
        warn "Limine config not found at $LIMINE_DEFAULT."
        warn "Add this kernel parameter manually to your bootloader:"
        warn "    $KERNEL_PARAM"
    fi

    log "Rebuilding initramfs..."
    if [[ "$boot_configurator" = "$CONST_MKINITCPIO" ]]; then
        mkinitcpio -P >/dev/null 2>&1 || die "mkinitcpio failed — run 'mkinitcpio -P' manually"
    elif [[ "$boot_configurator" = "$CONST_DRACUT_R" ]]; then
        dracut-rebuild >/dev/null 2>&1 || die "dracut failed - run 'dracut-rebuild' manually"
    elif [[ "$boot_configurator" = "$CONST_DRACUT" ]]; then
        dracut --regenerate-all --force >/dev/null 2>&1 || die "dracut failed - run 'dracut --regenerate-all -f' manually"
    else
        die "Initramfs not generated, as boot configurator (dracut or mkinicpio) not found"
    fi

    ok "Initramfs rebuilt"

    printf '\n'
    ok "Install complete. Reboot to activate HDR detection."
    printf '    After reboot, enable HDR in System Settings → Display & Monitor\n'
    printf '    (or: kscreen-doctor output.%s.hdr.enable)\n' "$connector"
}

main "$@"

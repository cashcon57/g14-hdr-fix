#!/usr/bin/env bash
# g14-hdr-fix — uninstaller. Reverts everything install.sh set up.

set -euo pipefail

FIRMWARE_PATH="/lib/firmware/edid/g14_hdr_edid.bin"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
LIMINE_DEFAULT="/etc/default/limine"
HOOK_PATH="/etc/pacman.d/hooks/g14-hdr-fix.hook"
HELPER_DIR="/usr/local/share/g14-hdr-fix"

c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_reset=$'\e[0m'
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

if [[ -f "$FIRMWARE_PATH" ]]; then
    rm -f "$FIRMWARE_PATH"
    ok "Removed $FIRMWARE_PATH"
fi

if [[ -f "$HOOK_PATH" ]]; then
    rm -f "$HOOK_PATH"
    ok "Removed $HOOK_PATH"
fi

if [[ -d "$HELPER_DIR" ]]; then
    rm -rf "$HELPER_DIR"
    ok "Removed $HELPER_DIR"
fi

if [[ -f "${MKINITCPIO_CONF}.g14hdr.bak" ]]; then
    mv "${MKINITCPIO_CONF}.g14hdr.bak" "$MKINITCPIO_CONF"
    ok "Restored $MKINITCPIO_CONF"
elif grep -q "g14_hdr_edid.bin" "$MKINITCPIO_CONF" 2>/dev/null; then
    sed -i 's| */lib/firmware/edid/g14_hdr_edid\.bin||g; s|/lib/firmware/edid/g14_hdr_edid\.bin||g' "$MKINITCPIO_CONF"
    ok "Cleaned $MKINITCPIO_CONF"
fi

if [[ -f "${LIMINE_DEFAULT}.g14hdr.bak" ]]; then
    mv "${LIMINE_DEFAULT}.g14hdr.bak" "$LIMINE_DEFAULT"
    ok "Restored $LIMINE_DEFAULT"
elif [[ -f "$LIMINE_DEFAULT" ]] && grep -q "g14_hdr_edid.bin" "$LIMINE_DEFAULT"; then
    sed -i '/# Added by g14-hdr-fix/,/g14_hdr_edid.bin/d' "$LIMINE_DEFAULT"
    ok "Cleaned $LIMINE_DEFAULT"
fi

if command -v mkinitcpio >/dev/null; then
    mkinitcpio -P >/dev/null 2>&1 || warn "mkinitcpio failed — run it manually"
    ok "Rebuilt initramfs"
fi

ok "Uninstall complete. Reboot to revert."

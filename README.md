# g14-hdr-fix

Enable HDR detection on the 2024+ ASUS ROG Zephyrus G14 (OLED) under Linux.

## The problem

The 2024+ G14's OLED panel (Samsung ATNA40CU05-0) stores its HDR metadata inside a **DisplayID v2.0** EDID extension — not the conventional CTA-861 extension. `libdisplay-info` 0.3.x, which KWin, Mutter, wlroots, and most other Wayland compositors use to parse EDIDs, doesn't understand DisplayID data blocks. The result: compositors see the display as *HDR-incapable*, even though it can produce ~617 cd/m² peak HDR.

You'll see this in `kscreen-doctor -o`:

```
HDR: incapable
Wide Color Gamut: incapable
```

…despite `edid-decode` clearly showing SMPTE ST2084 (PQ / HDR10) support.

## The fix

This script installs an **EDID firmware override** via `drm.edid_firmware`. The override is the panel's original base EDID plus a single synthesized CTA-861 extension containing:

- A **Colorimetry Data Block** advertising BT2020-RGB
- An **HDR Static Metadata Data Block** with the panel's real PQ/SMPTE ST2084 limits (pulled from its own DisplayID block)
- A **Detailed Timing Descriptor** for the native 2880×1800 @ 120 Hz mode (CTA-861-only parsers would otherwise cap out at the 60 Hz DTD in the base EDID)

The panel's hardware is unchanged — the override only changes what the DRM layer *reports* to userspace so libdisplay-info-based compositors see the capabilities that were always there.

## Compatibility

- **Hardware**: 2024+ ASUS ROG Zephyrus G14 with the Samsung ATNA40CU05-0 OLED (other panels with the same DisplayID-only-HDR issue may work; the script warns if the panel doesn't match)
- **OS**: CachyOS / Arch Linux (uses `mkinitcpio`)
- **Bootloader**: Limine (auto-configured). For GRUB / systemd-boot the script prints the kernel parameter and you add it yourself.
- **Compositor**: KDE Plasma 6 (tested), GNOME 46+, Sway/Hyprland with HDR patches — anything using libdisplay-info

## Install

```bash
git clone https://github.com/YOUR_USER/g14-hdr-fix.git
cd g14-hdr-fix
sudo ./install.sh
sudo reboot
```

After reboot, enable HDR:

```bash
kscreen-doctor output.eDP-1.hdr.enable
kscreen-doctor output.eDP-1.sdr-brightness.400   # peg SDR white at panel max
```

…or via **System Settings → Display & Monitor → HDR**.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

The installer backs up `/etc/mkinitcpio.conf` and `/etc/default/limine` to `*.g14hdr.bak` on first run; the uninstaller restores them.

## What the script does

1. Detects the connected internal eDP connector.
2. Verifies the panel is the ATNA40CU05-0 and has SMPTE ST2084 in its EDID.
3. Reads the real HDR luminance bytes from the panel's own EDID so the override reflects the panel's actual capabilities.
4. Writes a 256-byte EDID to `/lib/firmware/edid/g14_hdr_edid.bin`.
5. Adds that file to `FILES=` in `/etc/mkinitcpio.conf` (so it's available in early boot).
6. Appends `drm.edid_firmware=eDP-1:edid/g14_hdr_edid.bin` to `/etc/default/limine`.
7. Runs `mkinitcpio -P` to regenerate the initramfs.

## Caveats

- The 120 Hz DTD produces 119.88 Hz due to an unavoidable 10 kHz rounding step in the CTA-861 DTD format. In practice every driver / compositor I've tested treats this as 120 Hz. If your driver refuses the mode, file an issue.
- The override hides the panel's DisplayID Adaptive-Sync data block. FreeSync/VRR still works on the NVIDIA driver because it advertises VRR via the connector's `vrr_capable` DRM property, not EDID parsing. If you find a compositor that breaks, tell me.
- This is a workaround. The proper fix is `libdisplay-info` learning to parse DisplayID Data Blocks; track that upstream at <https://gitlab.freedesktop.org/emersion/libdisplay-info>.

## License

MIT. See [LICENSE](LICENSE).

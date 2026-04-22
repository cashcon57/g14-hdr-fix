<div align="center">

# g14-hdr-fix

**Enable HDR detection on the 2024+ ASUS ROG Zephyrus G14 (OLED) under Linux.**

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Linux-informational?logo=linux&logoColor=white)
![Distro](https://img.shields.io/badge/distro-CachyOS%20%7C%20Arch-1793d1?logo=archlinux&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Python](https://img.shields.io/badge/python-3.8%2B-3776AB?logo=python&logoColor=white)
![Hardware](https://img.shields.io/badge/hardware-ASUS%20ROG%20G14-cc0000)
![Status](https://img.shields.io/badge/status-working-brightgreen)

</div>

---

## TL;DR

Your G14 OLED panel **is** HDR-capable. KWin thinks it isn't because `libdisplay-info` can't parse the panel's non-standard EDID. This script installs a one-line EDID firmware override that fixes detection — no kernel patches, no recompiling.

> **This is a stopgap.** The upstream `libdisplay-info` fix ([MR !202](https://gitlab.freedesktop.org/emersion/libdisplay-info/-/merge_requests/202)) has already been merged — it just hasn't been cut into a tagged release yet (latest is 0.3.0 from Aug 2025). Once `libdisplay-info` ≥ 0.4.0 ships and Arch/CachyOS picks it up, run `uninstall.sh` and use stock detection.

```bash
git clone https://github.com/cashcon57/g14-hdr-fix.git
cd g14-hdr-fix
sudo ./install.sh && sudo reboot
```

After reboot, HDR will be toggleable in KDE System Settings (or via `kscreen-doctor output.eDP-1.hdr.enable`).

---

## Why this exists

Fresh CachyOS install on a 2024 ROG Zephyrus G14 OLED. Everything Just Works™: NVIDIA open modules picked up, 2880×1800 native, KDE Plasma 6.6 boots straight to the login screen at 120 Hz. But pop open *System Settings → Display & Monitor* and the HDR toggle is greyed out with "This display doesn't support HDR." Run `kscreen-doctor -o` and it flatly reports `HDR: incapable`.

Which is strange, because this panel absolutely is HDR-capable — Samsung's ATNA40CU05-0, ~617 nits peak, full DCI-P3, advertised by ASUS as an HDR True Black 500 display. The hardware spec sheet says yes. Every Linux tool in the stack says no.

A few hours of tracing from KWin → `kscreen` → `libdisplay-info` → `di-edid-decode` surfaced the problem: ASUS stores the panel's HDR metadata inside a **DisplayID v2.0 extension block**, which is spec-compliant but an uncommon choice — most panels put HDR data in a CTA-861 extension instead. `libdisplay-info` (0.3.0 is current as of CachyOS in early 2026) doesn't yet parse DisplayID data blocks, so every compositor that uses it — KWin, Mutter, wlroots, Cosmic — sees the DisplayID extension, can't decode it, and concludes the panel is HDR-incapable.

The proper fix has already [landed upstream](https://gitlab.freedesktop.org/emersion/libdisplay-info/-/merge_requests/202) but hasn't been tagged into a release yet. Rather than wait an unknown number of weeks for that release to wind its way through `libdisplay-info` → Arch `extra` → CachyOS, this script synthesizes a well-formed CTA-861 extension from the panel's own HDR bytes and installs it as an EDID firmware override. Every compositor already handles CTA-861 correctly, so HDR lights up on the next boot. `uninstall.sh` peels the whole thing off when upstream catches up.

## Why this is broken

Samsung's ATNA40CU05-0 — the panel ASUS ships in the 2024+ G14 OLED — advertises its HDR capabilities inside a **DisplayID v2.0 extension block** instead of the conventional CTA-861 extension. That's spec-compliant, but `libdisplay-info` (the EDID parser used by **KWin**, **Mutter**, **wlroots**, **Cosmic**, and most other Wayland compositors) doesn't yet parse DisplayID data blocks.

The panel reports this:

```
$ edid-decode
  HDR Static Metadata Data Block:
    Electro optical transfer functions:
      SMPTE ST2084              ← HDR10 / PQ
    Desired content max luminance: 616.884 cd/m²
```

`libdisplay-info` sees this:

```
$ di-edid-decode
  Block 1, DisplayID Extension Block:
    Version: 2.0
    (nothing)              ← DisplayID contents not parsed
```

And compositors reach this conclusion:

```
$ kscreen-doctor -o
  HDR: incapable
  Wide Color Gamut: incapable
```

Meanwhile the hardware can happily produce ~617 nits peak with full BT.2020 coverage.

## How the fix works

```
┌─────────────────────────────────────────────────────────────────┐
│  Real panel EDID (as shipped)                                   │
│                                                                 │
│  ┌─────────────┐  ┌──────────────────────────────────────────┐  │
│  │ Base EDID   │  │ DisplayID v2.0 ext (HDR metadata here) ✗ │  │
│  └─────────────┘  └──────────────────────────────────────────┘  │
│                                                                 │
│  Compositors: "no HDR block in CTA → incapable"                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  EDID firmware override (what this script installs)             │
│                                                                 │
│  ┌─────────────┐  ┌──────────────────────────────────────────┐  │
│  │ Base EDID   │  │ CTA-861 ext: Colorimetry + HDR + 120 Hz  │  │
│  └─────────────┘  └──────────────────────────────────────────┘  │
│                                                                 │
│  Compositors: "SMPTE ST2084 in CTA → HDR capable" ✓             │
└─────────────────────────────────────────────────────────────────┘
```

1. Read the panel's real EDID from `/sys/class/drm/cardN-eDP-1/edid`.
2. Keep the base EDID block byte-for-byte.
3. Replace the DisplayID extension with a synthesized CTA-861 extension containing:
   - **Colorimetry Data Block** — BT.2020 RGB
   - **HDR Static Metadata Data Block** — SMPTE ST2084, with the panel's real luminance bytes (pulled from the panel, not hardcoded)
   - **Detailed Timing Descriptor** — the native 2880×1800 @ 120 Hz mode (otherwise only the 60 Hz DTD from the base block survives)
4. Install it to `/lib/firmware/edid/g14_hdr_edid.bin` and register it with `drm.edid_firmware=eDP-1:edid/g14_hdr_edid.bin`.

The hardware is untouched — we only change what the DRM layer *reports* to userspace.

## Install

```bash
git clone https://github.com/cashcon57/g14-hdr-fix.git
cd g14-hdr-fix
sudo ./install.sh
sudo reboot
```

After reboot:

```bash
kscreen-doctor output.eDP-1.hdr.enable
kscreen-doctor output.eDP-1.sdr-brightness.400   # peg SDR white at panel max
```

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

Backups of `/etc/mkinitcpio.conf` and `/etc/default/limine` are created on first install (`*.g14hdr.bak`) and restored on uninstall.

## Dependencies

| Package | Why | Ships with CachyOS? |
| --- | --- | --- |
| `bash` ≥ 5 | installer / uninstaller | ✅ |
| `python3` | EDID blob generation | ✅ |
| `edid-decode` | reads HDR byte values from the real EDID | ✅ |
| `mkinitcpio` | bakes the firmware into initramfs | ✅ |
| `limine` *(or any bootloader)* | applies the kernel cmdline parameter | ✅ (CachyOS default) |

If `edid-decode` is missing: `sudo pacman -S edid-decode`.

## Compatibility matrix

The underlying technique (`drm.edid_firmware=` kernel override) is distro-agnostic — every Linux kernel supports it. **The installer, however, is Arch-family only**: it hard-depends on `mkinitcpio`, `pacman` (for the notification hook), and optionally `/etc/default/limine`. On Fedora / Ubuntu / openSUSE / NixOS it will exit cleanly at the `mkinitcpio` check.

| Component | Tested | Plausibly works (unverified) | Won't work without manual effort |
| --- | --- | --- | --- |
| **Hardware** | ASUS ROG Zephyrus G14 (2024, GA403) w/ Samsung ATNA40CU05-0 OLED | Any laptop with the same panel SKU | Other OLED panels with different HDR block layouts |
| **GPU driver** | NVIDIA 595.58.03 (open kernel modules) | NVIDIA ≥ 550, AMD `amdgpu`, Intel `i915` | — |
| **Distro** | CachyOS (kernel 7.0, pacman, mkinitcpio, Limine) | Arch Linux, EndeavourOS, Manjaro, Garuda — any `mkinitcpio` + `pacman` distro | Fedora, Ubuntu, openSUSE, NixOS — installer doesn't run, but the EDID firmware technique itself still applies if you port the steps |
| **Bootloader** | Limine (auto-patched) | GRUB / systemd-boot — script prints the kernel param, you add it manually | — |
| **Compositor** | KDE Plasma 6.6 (Wayland) | GNOME 46+ Mutter, Cosmic, Hyprland/Sway with HDR patches (all use `libdisplay-info`, so the detection fix should apply identically) | — |

PRs to extend installer support (dracut, initramfs-tools, GRUB/systemd-boot auto-patching, non-`pacman` notification hooks) are welcome.

## What the script touches

| Path | Change |
| --- | --- |
| `/lib/firmware/edid/g14_hdr_edid.bin` | ➕ created (256 bytes, synthesized EDID) |
| `/etc/mkinitcpio.conf` | `FILES=` gains the firmware path |
| `/etc/default/limine` | `KERNEL_CMDLINE[default]+=` gains `drm.edid_firmware=…` |
| `/boot/<machine-id>/linux-*/initramfs-*` | regenerated so the firmware is available in early boot |

Both config files are backed up to `*.g14hdr.bak` before the first edit.

## Caveats

- The 120 Hz DTD comes out to **119.88 Hz** — a 0.12 Hz rounding artefact of the CTA-861 DTD 10 kHz pixel-clock quantum. Every driver I've tested (NVIDIA 595, `amdgpu`, `i915`) accepts it as 120 Hz. If yours refuses, open an issue with `modetest -M <driver>` output.
- The override hides the panel's DisplayID **Adaptive-Sync data block**. On NVIDIA, VRR still works because the driver advertises it via the `vrr_capable` DRM property (not EDID parsing). If you lose VRR on AMD/Intel, open an issue.
- This is a **workaround**. The proper fix — `libdisplay-info` parsing CTA-861 Data Block Encapsulation inside DisplayID v2 — has **already landed upstream** in [MR !202](https://gitlab.freedesktop.org/emersion/libdisplay-info/-/merge_requests/202) (merged 2026-01-06). It's in `main` but hasn't been cut into a release yet; the latest tag (0.3.0, Aug 2025) predates the fix. Once upstream tags a new release and Arch/CachyOS pick it up, run `uninstall.sh` and use stock detection.

## Contributing

PRs welcome. If the script fails on your hardware, please include:

```bash
sudo cat /sys/class/drm/card*-eDP-*/edid | edid-decode       # full EDID decode
kscreen-doctor -o                                            # what the compositor sees
uname -a && cat /etc/os-release                              # kernel/distro
```

## License

[MIT](LICENSE).

## Credits

- [`edid-decode`](https://git.linuxtv.org/edid-decode.git/) — essential for understanding what the panel is actually saying.
- [`libdisplay-info`](https://gitlab.freedesktop.org/emersion/libdisplay-info) — getting there; this workaround exists for the gap.
- The KDE HDR team — their Plasma 6 HDR pipeline is what made this worth fixing.

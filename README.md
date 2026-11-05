# plustek-z300-macos

Use the **Plustek ePhoto Z300** photo scanner on macOS outside Plustek's ePhoto app:

- **Z300 Scan**, a menu-bar app: insert a photo or page, a panel asks *Photo* or *Document*, and the scan lands on
  the Desktop (or, at a tick, in another folder such as a network share) as JPEG/PNG/TIFF or as a (multi-page,
  searchable) PDF. Tilted items are straightened and cropped.
- **A SANE driver behind AirSane**: the scanner appears in Preview, Image Capture and any other app that scans
  through macOS, as the feeder scanner "Plustek ePhoto Z300".

Both drive the scanner through Plustek's own scanner engine (`ScanApi.framework`), which is loaded at runtime from
your ePhoto installation. ePhoto must therefore be installed; nothing of it is copied or modified. Tested with
ePhoto 2.5.14 on macOS 26 (Apple silicon), scanner USB ID `07b3:131c` (`07b3:143d` is the other Z300 revision).

> **Not affiliated with or endorsed by Plustek.** Plustek and ePhoto are trademarks of Plustek Inc., used here only
> to say which hardware and software this works with. This repository contains no Plustek code; see
> [Legal](#legal).

## How it fits together

```
Z300 Scan.app ──┐                                    ┌── holds the scanner between scans, listens to its paper sensor
                ├── ScanApi.framework (Plustek) ── USB ── ePhoto Z300
airsaned ── SANE ── libsane-plustek_scanapi ──┘      └── takes it only for a scan (asks the app to let go first)
   │
   └── AirScan/eSCL on 127.0.0.1:8090 ── macOS ImageCaptureCore ── Preview, Image Capture, ...
```

Only one process can hold the scanner. The app gives it up when ePhoto opens (and takes it back when ePhoto quits),
before sleep, and when the SANE driver posts the distributed notification `z300bridge.release`
(`…resume` hands it back). AirSane listens on the loopback interface only, so other computers cannot reach it.

## Install, update, remove

```
brew install sane-backends cmake
git clone --recursive https://github.com/havurgiray/plustek-z300-macos.git
cd plustek-z300-macos
./install.sh      # builds everything, installs, (re)starts both login items
./uninstall.sh    # removes all of it again
```

Needs the Xcode Command Line Tools (or Xcode) and ePhoto in `/Applications/Plustek/ePhoto Z300/`.

`app/build.sh` signs the app ad hoc unless `config/signing` names a code-signing identity (its SHA-1 from
`security find-identity -v -p codesigning`; the file is not tracked). With a stable identity, macOS keeps the app's
Desktop-folder permission across rebuilds; ad hoc builds are asked again after each rebuild.

A prebuilt app is attached to the [releases](https://github.com/havurgiray/plustek-z300-macos/releases). It is
signed ad hoc and not notarized: after unzipping, open it once with right-click > Open, or allow it in System
Settings > Privacy & Security. The prebuilt app alone gives you the menu-bar app; Preview and Image Capture support
needs `./install.sh`.

| What | Where |
|---|---|
| App | `/Applications/Z300 Scan.app` |
| AirSane, driver, config | `~/Library/Application Support/z300-bridge/` |
| Login items | `~/Library/LaunchAgents/z300bridge.app.plist`, `…airsaned.plist` |
| Logs | `~/Library/Logs/z300-bridge/` (`app.log`, one log per login item) |
| App settings | `defaults read z300bridge.scan` (panel choices, `saturation`, `gamma`, `otherFolder`) |
| Driver settings | `~/Library/Application Support/z300-bridge/sane.d/plustek_scanapi.conf` (waits, `saturation`, `gamma`) |

The runtime files live outside `~/Desktop` on purpose: login items cannot read Desktop files without a privacy
prompt nobody would see.

## Using it

- **App**: insert something; choose Photo (300/600 dpi, crop to the photo) or Document (150/300/600 dpi, colour or
  grey, searchable text by macOS's on-device text recognition); press Scan. Both can straighten items fed in at an
  angle. For a document, insert further pages when asked, then Save PDF. The menu-bar icon shows the state and
  holds the colour settings.
- **Another folder**: `defaults write z300bridge.scan otherFolder /Volumes/scans` adds a checkbox to the panel
  to save there instead of on the Desktop. While the folder's volume is not mounted the checkbox is greyed out; if
  the folder cannot take a scan (say, the share went away), the scan goes to the Desktop and the notification says
  so. For a network share, macOS asks once for the app's permission to access network volumes.
- **Preview / Image Capture**: File > Import from "Plustek ePhoto Z300". It is a feeder: the driver waits 60 s for
  the first photo and 10 s for each further one of the same batch. Quit ePhoto first.
- **Colour**: raw scans are oversaturated and dark. The defaults, chosen by eye on photo scans, are 15% less
  saturation and a brightness curve of gamma 1.6 ("35% brighter"); both are adjustable. Plustek's ICC profiles
  (`Photo Scanner(M11/M21).icm`) were tried and not used: applied as ePhoto does, they brighten far too much.
- **Calibration**: the engine uses ePhoto's calibration files `SC300.shd` (up to 300 dpi) and `SC600.shd` (600 dpi)
  from `~/Library/Application Support/Plustek/ePhoto Z300_Scanner/Shading/`. Calibrate once in ePhoto with the
  calibration sheet that came with the scanner, and again if streaks or colour casts appear.
- **Long items**: up to 36 inches at 300 dpi (18 at 600). The scanner's firmware ends a scan a fixed distance after
  the item leaves the paper sensor, so feed narrow items along the sensor side; the app warns when an item may have
  been cut off.

## Hardware quirks found on the way

- The engine's gray mode and resolutions below 300 dpi break the feed (the motor jolts and the sheet does not
  advance). Everything is therefore scanned in colour at 300 or 600 dpi; gray is computed from it, and 150 dpi is a
  2×2 average.
- The engine makes the scanner re-enumerate on USB whenever it releases it, so AirSane runs with USB hotplug off.
- The scanner's eject command is not implemented in the engine; after Cancel, take the item back out by hand.

## Troubleshooting

- Scanner light: orange = nobody holds it, blue = held and ready.
- "Paused: ePhoto is open" in the menu: quit ePhoto.
- Preview says the scanner is busy: the app did not let go within 8 s; check `app.log`.
- Crop keeps a grey frame: the photo was in a protective sleeve, which reads grey, not black.
- The engine recreates an empty `~/Library/Application Support/Plustek/Debug_Info/` whenever it connects; while it
  exists the engine logs verbosely to the unified log (subsystem `com.plustek.ScanApi`). Harmless.

## Layout

| Path | Contents |
|---|---|
| `scanapi/scanapi.h` | Reconstructed interface of Plustek's engine |
| `scanapi/*.c` | Small test programs against the engine (`probe`, `layout`, `scantest`, `hold`) |
| `backend/` | SANE backend `plustek_scanapi` |
| `app/` | Z300 Scan (Swift, AppKit), `app/build.sh` |
| `AirSane/` | [AirSane](https://github.com/SimulPiscator/AirSane) (GPL-3.0) as a git submodule, unmodified; built into `AirSane-build/` |
| `tools/` | `list-scanners` and `icscan`: list and scan through macOS ImageCaptureCore, as Preview does |
| `run-airsaned.sh`, `sane.d/`, `airsane-etc/` | Running AirSane from the project folder during development |

## Legal

This project exists to make a scanner its owner bought work with other software on their own Mac. Its interface to
Plustek's engine was worked out for interoperability, as permitted for lawful users under Article 6 of the EU
Software Directive (2009/24/EC). The repository contains no Plustek code, binaries, profiles or calibration data;
the engine is loaded at runtime from the user's own ePhoto installation, under the user's own license for it. No
copy protection is circumvented. Plustek and ePhoto are trademarks of Plustek Inc.; this project is not affiliated
with or endorsed by Plustek.

The code in this repository is released under the [MIT License](LICENSE). AirSane, included as a submodule, is
licensed separately under the GPL-3.0.

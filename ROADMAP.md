# Lumina Roadmap

Forward-looking plan. Shipped milestones move to [the release history](https://github.com/abdul-abdi/lumina/releases).

## Shipped

- **v0.7.0** (2026-04-20) — Lumina Desktop: full-OS guests (Linux ISO, Windows 11 ARM, macOS IPSW) + SwiftUI app + clipboard scaffolding + ARM64 ISO pre-flight + virtio sound + Rosetta-at-runtime for desktop guests. Ad-hoc signed; notarization deferred to v0.7.1.
- **v0.6.0** (2026-04-20) — Interactive agent sessions: PTY, port forwarding, unified JSON envelope, `lumina ps`, typed exec errors.
- v0.5.0 — Agent-grade VM execution: concurrent exec, stdin piping, pre-warmed pools, unified NDJSON (pre-unified-envelope).
- v0.4.x and earlier — initial runtime, sessions, images, volumes.

## v0.7.1 candidates (post-v0.7 follow-ups)

- **Notarization** — once Apple Developer Program account is set up, swap ad-hoc signing for Developer ID + notarytool.
- **Lumina Guest Additions repo** — publish .deb/.rpm packages at https://guest.lumina.app/ so the cloud-init seed actually finishes the clipboard install. M7 ships the host-side scaffolding; this completes the loop.
- **Real ISO checksum verification** — replace placeholder SHA-256s in `DesktopOSCatalog` with values from each distro's signed SHA256SUMS file.
- **Windows scancode remap at runtime** — apply `WindowsInputQuirks` table inside the running-VM input layer for Windows guests.
- **Multi-display per VM** — `VZGraphicsDeviceConfiguration.displays` accepts arrays.

## In progress (none — v0.7.0 was the last in-progress release)

_Originally written when v0.7.0 was the upcoming release. Kept here for context — see "Shipped" above for the actual outcome._

**The entire desktop VM stack, shipped together.** Linux desktop guests · Windows 11 on ARM · macOS guests · SwiftUI app · shared clipboard · drag-and-drop · USB. One big release, not six small ones.

The rationale for compressing v0.7 → v1.1 into a single release is iteration velocity: with Claude-assisted development, the per-feature marginal cost is low enough that coherent integration wins over incremental shipping. The agent runtime stays on a separate code path throughout — no regressions to boot time or exec latency.

### Internal milestones (not separate releases)

Each milestone is a mergeable chunk. The public release is a single tag `lumina-v0.7.0` at the end.

**M1 — Monorepo restructure**
- Multi-product `Package.swift`: `Lumina` (current), `LuminaGraphics`, `LuminaBootable`, `LuminaDesktopKit`
- `Apps/LuminaDesktop/` Xcode project scaffold (needed for proper App Sandbox + VM entitlements + notarization)
- CI extended to build all products
- **Agent-boot regression gate**: CI fails if `lumina run "true"` cold-boot P50 exceeds baseline by >10%

**M2 — Graphics + input (library only)**
- `VZGraphicsDevice` wiring behind `VMOptions.graphics: GraphicsConfig?` (opt-in, default `nil`)
- `VZVirtioKeyboard` + `VZUSBScreenCoordinatePointingDevice`
- `VZVirtualMachineView` wrapper in `LuminaDesktopKit`
- Smoke test: boot an Ubuntu ISO from a Swift playground, see the framebuffer

**M3 — Linux desktop guests**
- ISO boot flow: `VZLinuxBootLoader` + `VZUSBMassStorageDeviceConfiguration` for CD-ROM
- Persistent HDD via `VZDiskImageStorageDeviceAttachment`
- Ubuntu / Kali / Fedora / Debian desktop ISO tested end-to-end
- Guest additions (clipboard + shared folder + mouse release) via vsock agent — reuses existing `lumina-agent`

**M4 — Windows 11 on ARM**
- `VZEFIBootLoader` + `VZEFIVariableStore` for EFI boot
- Windows 11 ARM retail ISO install flow
- `VZVirtioSoundDevice` for audio
- Input device mapping (scancode quirks)

**M5 — macOS guests**
- `VZMacOSVirtualMachine` — separate VM type from `VZVirtualMachine`
- IPSW download + `VZMacOSInstaller` + auxiliary storage + hardware model + machine identifier
- Recovery-mode install flow
- macOS 12+ guests on Apple Silicon hosts only (licensing + framework constraint)

**M6 — Lumina Desktop app**
- SwiftUI: VM library, "New VM" wizard, snapshot browser, settings
- Distribution: notarized `.app` bundle via GitHub Releases
- Preferences: CPU/memory limits, disk location, image library root

**M7 — Shared clipboard + drag-and-drop**
- Clipboard: bidirectional sync via vsock, guest agent handles paste/copy
- File drag-and-drop: drop on window → `lumina cp` internally
- Only for Linux guests initially (macOS and Windows need their own integration agents)

**M8 — Extras**
- Rosetta-at-runtime for x86 user binaries inside Linux guests (extends existing image-level `--rosetta` to session-level)
- USB virtio (virtual USB devices; no arbitrary host-USB passthrough — VZ doesn't expose that)
- UI polish + first-run experience

### Hard constraints

Stated upfront so the UI can set honest expectations:

- **No x86 Windows** — VZ doesn't emulate x86. Only Windows 11 on ARM (retail ISO).
- **No x86 Linux as a desktop guest** — x86 user-space runs via Rosetta *inside* an ARM Linux guest; no full x86 desktop.
- **macOS guests** require macOS 12+ and Apple Silicon host (framework + licensing).
- **USB passthrough** is limited to virtio-usb virtual devices. Host webcams, YubiKeys, etc. are not available to guests.
- **Agent path stays protected** — the boot-time CI gate is non-negotiable. Desktop features may not land if they slow the agent path.

## Post-v0.7

No fixed schedule — direction depends on what users ask for once desktop ships. Candidates:

- **Snapshotting** — full VM snapshots (disk + RAM) via VZ's `VZVirtualMachine.saveMachineStateTo(url:completionHandler:)`
- **Wayland-native clipboard** for modern Linux desktops (currently X11 assumptions)
- **Linux agent-in-desktop-guest** — run agent commands inside a desktop guest without breaking the windowed UI
- **CLI `lumina desktop`** — launch the .app from the CLI with a specific guest preselected
- **iCloud-sync image library** — shared VM images across multiple Macs
- **Fleet management** — remote orchestration of multiple Lumina hosts

## Contributing

Pre-v0.7 issues welcome — bugs in the runtime, doc gaps, recipe requests. v0.7 work is happening on a long-running branch; small PRs targeting it are fine once the M1 scaffolding lands.

File at https://github.com/abdul-abdi/lumina/issues.

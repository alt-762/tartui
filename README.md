# TartUI

A native macOS app (SwiftUI) for [Tart](https://github.com/cirruslabs/tart) virtual machines on Apple Silicon.

## Features

| Area | What you can do | tart command |
|---|---|---|
| VMs | List local VMs with live state | `tart list --format json` (polled every 5s) |
| Create | From a registry image, from a macOS IPSW, or an empty Linux VM | `tart clone <image> <name>`, `tart create --from-ipsw`, `tart create --linux` |
| Run | Start (with headless, recovery, shared folder, Softnet isolation with allowed networks and exposed ports), stop, suspend, see IP, copy SSH command | `tart run`, `tart stop`, `tart suspend`, `tart ip` |
| Clone | Clone any local VM or cached image into a new VM | `tart clone` |
| Settings | CPU, memory, disk size, display | `tart get --format json`, `tart set` |
| Images | List cached OCI images, pull, push, delete, registry login, prune cache | `tart pull`, `tart push`, `tart delete`, `tart login`, `tart prune` |
| Activity | Live progress log for creates, clones, pulls and pushes, with cancel | streamed stdout/stderr |

## Architecture

```
┌──────────────────────── TartUI (executable, SwiftUI) ────────────────────────┐
│  Views                                                                       │
│   ContentView ── NavigationSplitView                                         │
│     sidebar: Virtual Machines · Images · Activity                            │
│     detail:  VMDetailView · ImageDetailView · ActivityView                   │
│     sheets:  Create · Clone · Pull · Push · Login                             │
│   AppSettingsView (⌘,)                                                       │
│                         │ @Environment                                       │
│  VMStore  (@MainActor @Observable)                                           │
│    vms, configs, operations, lastError                                       │
│    polling · lifecycle actions · TartOperation tracking for long jobs        │
└─────────────────────────┬────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼──────── TartKit (library, no UI) ──────────────────┐
│  TartCLI       typed API: list/get/create/clone/run/stop/set/pull/push/...   │
│  Models        TartVM, TartVMConfig, RunOptions (lenient JSON decoding)      │
│  ProcessRunner run-to-completion · line streaming · detached launch          │
└─────────────────────────┬────────────────────────────────────────────────────┘
                          ▼
                    /opt/homebrew/bin/tart
```

Design choices:

- **Wrap the CLI, don't reimplement it.** Every action maps to one `tart` subcommand, so the app keeps working as tart evolves and never edits `~/.tart` directly.
- **TartKit is UI-free** so it can be unit tested and reused (e.g. a future menu bar extra or widget).
- **`tart run` is launched detached.** The VM window is tart's own; the app tracks the process and refreshes when it exits. If it crashes, the last log lines are shown in an alert.
- **Long jobs stream.** Pull, push, create and clone print progress; `ProcessRunner.stream` splits on `\n` and `\r` so progress bars show up line by line in Activity.
- **Polling** keeps the list in sync with VMs started or stopped from the terminal or CI.

## Requirements

- Apple Silicon Mac, macOS 14 Sonoma or later
- Xcode 15.3+ (Swift 5.10)
- tart: `brew install cirruslabs/cli/tart`

## Build and run

```sh
swift run TartUI          # quick dev run
swift test                # TartKit unit tests
./scripts/bundle.sh       # builds build/TartUI.app (ad-hoc signed)
```

Or open `Package.swift` in Xcode and press Run.

## Releasing

Push a version tag and GitHub Actions builds the app, packages it as a DMG and
attaches it (plus a SHA-256 checksum) to a GitHub Release:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The tag (minus the leading `v`) becomes `CFBundleShortVersionString`. Tags with
a suffix such as `v0.2.0-beta.1` are published as pre-releases. You can also
re-run a release for an existing tag from the Actions tab (Release, Run workflow).

To build a DMG locally: `./scripts/bundle.sh && ./scripts/make_dmg.sh 0.2.0`.

Signing and notarization are optional. Without secrets the app is ad-hoc signed,
so on first launch users need to right-click the app and choose Open (or run
`xattr -dr com.apple.quarantine /Applications/TartUI.app`). To ship a signed and
notarized DMG, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of a Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_APP_PASSWORD` | app-specific password for that Apple ID |
| `APPLE_TEAM_ID` | your 10-character team ID |

## Roadmap

- [ ] Menu bar extra with quick start/stop
- [ ] Rename VM inline from the sidebar
- [ ] Image browser for ghcr.io/cirruslabs with tags
- [ ] Export / import (`tart export`, `tart import`)
- [ ] Notifications when long jobs finish
- [ ] App icon and proper Xcode project for notarized releases

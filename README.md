# TartUI

A native macOS app (SwiftUI) for [Tart](https://github.com/cirruslabs/tart) virtual machines on Apple Silicon.

## Features

| Area | What you can do | tart command |
|---|---|---|
| VMs | List local VMs with live state | `tart list --format json` (polled every 5s) |
| Create | From a registry image, from a macOS IPSW, or an empty Linux VM | `tart clone <image> <name>`, `tart create --from-ipsw`, `tart create --linux` |
| Run | Start (with headless, recovery, shared folder), stop, suspend, see IP, copy SSH command | `tart run`, `tart stop`, `tart suspend`, `tart ip` |
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

## Roadmap

- [ ] Menu bar extra with quick start/stop
- [ ] Rename VM inline from the sidebar
- [ ] Image browser for ghcr.io/cirruslabs with tags
- [ ] Export / import (`tart export`, `tart import`)
- [ ] Notifications when long jobs finish
- [ ] App icon and proper Xcode project for notarized releases

# Gershwin-on-GhostBSD

Build system for generating Gershwin Desktop live media based on GhostBSD.

## Architecture

- `build.sh`: The main build orchestrator.
- `resources/`:
  - `config/`: System configuration templates and package repository configs.
  - `packages/`: Clean package lists for base system, drivers, and Gershwin.
  - `scripts/`: Low-level ISO generation scripts.
  - `overlays/`: Files injected into the live system and boot environment.

## Requirements

- A FreeBSD or GhostBSD host system.
- Superuser privileges (root).
- At least 20GB of free disk space and 4GB of RAM.

## Getting Started

1. **Install Build Dependencies:**
   ```bash
   pkg install git transmission-utils makefs
   ```

2. **Run the Build:**
   ```bash
   sudo ./build.sh
   ```

The resulting ISO and its SHA256 checksum will be located in `/usr/local/gershwin-build/iso/`.

## Live Environment

The live system uses a memory-efficient `uzip` and `nullfs` layering architecture. The default user is `user` with UID `5001`.

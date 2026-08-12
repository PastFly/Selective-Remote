# Selective Remote

**English** · [Русский](README.md)

[![CI](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml/badge.svg)](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://support.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Selective Remote** is a native macOS remote-access client that combines RDP, SSH terminals, dual-pane SFTP, and SSH port forwarding in one application.

The project targets Apple Silicon and macOS 14 or later. The interface is available in English and Russian.

## Highlights

### RDP

- SDL-FreeRDP in full-screen and windowed modes;
- multi-monitor and Retina support;
- clipboard, audio, microphone, camera, printer, and folder redirection;
- connection quality profiles;
- macOS-oriented Command, Option, and Fn keyboard mapping;
- `.rdp` import, launch logs, and built-in diagnostics;
- multiple parallel RDP sessions.

## SSH terminal workspace

- embedded terminal powered by the system `/usr/bin/ssh`;
- up to eight tabs, each able to connect to a different server;
- one, two, or four visible panes;
- independent SSH processes with persistent workspace layout;
- local command history, favorites, and templates;
- searchable suggestions backed by a catalog of 300+ commands;
- built-in hints for SSH, `authorized_keys`, systemd, Docker, Kubernetes, networking, and diagnostics;
- broadcast input to multiple active panes;
- `⌘K` command palette;
- 14 themes plus font, cursor, sizing, and window-opacity controls.

### SSH credentials and Touch ID

Each SSH profile can explicitly select an authentication mode:

- **Automatic**;
- **Password**;
- **SSH key**;
- **Touch ID Key**;
- **ssh-agent / `~/.ssh/config`**.

Saved SSH passwords are stored only in **macOS Keychain** and are excluded from profile exports. A saved password can require Touch ID before Selective Remote releases it to OpenSSH.

Selective Remote can generate SSH keys, import existing private keys, and safely append a public key to the server's `~/.ssh/authorized_keys` without overwriting existing entries.

**Touch ID Key** is a separate mode that requires Touch ID before Selective Remote uses the selected private key. In the current community implementation the private key remains a regular OpenSSH file under `~/.ssh`; it is not a Secure Enclave key.

### SFTP

The standalone dual-pane file manager includes:

- local Mac and remote server panes;
- saved SSH profiles or temporary servers;
- a persistent SSH master connection so a password is not requested for every file operation;
- file and directory upload/download;
- Finder drag and drop;
- multi-selection with Command and Shift;
- recursive directory deletion;
- folder creation, rename, properties, and POSIX permissions;
- file and directory size calculation;
- progress, transferred bytes, and speed for large transfers;
- periodic automatic refresh of the remote pane;
- path suggestions and navigation history;
- built-in editing for remote UTF-8 text files.

## Independent forwarding

Forwarding is an independent workspace rather than a side effect of the selected connection card. It supports:

- local forwarding;
- remote forwarding;
- SOCKS5;
- saved profiles or manual SSH targets;
- password authentication through Keychain/AskPass;
- SSH keys and ssh-agent;
- keepalive and forwarding-failure detection.

### Proxy

SSH profiles can use:

- direct connections;
- **HTTP CONNECT proxy**;
- **SOCKS5 proxy**.

The proxy configuration is shared by Terminal, SFTP, and Forwarding. HTTP CONNECT supports a proxy username. A proxy password is intentionally not passed on a process command line; secure proxy-password storage will require a dedicated credential helper.

## Install

Download the DMG from the [latest GitHub Release](https://github.com/PastFly/Selective-Remote/releases/latest), open it, and drag **Selective Remote** into `Applications`.

Community builds without a Developer ID certificate use ad-hoc signing. On a new Mac, macOS may require a one-time approval in **System Settings → Privacy & Security → Open Anyway**, or by using **Open** from Finder's context menu.

A fully standard first launch requires Developer ID Application signing and Apple notarization.

## SSH quick start

1. Create an SSH profile and enter the hostname/IP, username, and SSH port.
2. Select an authentication mode.
3. For **Password**, save the SSH password in Keychain and optionally require Touch ID.
4. For **SSH key**, select an existing key or generate a new one.
5. For **Touch ID Key**, create a dedicated key and install its public key on the server.
6. Choose **Open SSH**.

Terminal, SFTP, and Forwarding reuse the authentication settings of the selected SSH profile.

## Build from source

Requirements: macOS 14 or later, Xcode Command Line Tools, and Homebrew.

```bash
brew install freerdp sdl3
git clone https://github.com/PastFly/Selective-Remote.git
cd Selective-Remote
./scripts/build_and_install.sh
```

For development:

```bash
swift test
swift run SelectiveRemote
```

Build the distributable app and DMG with:

```bash
./scripts/build_app.sh
```

## Privacy

- SSH passwords are stored in macOS Keychain;
- private SSH keys remain user-controlled files;
- exported profiles contain neither passwords nor private keys;
- terminal history stays local and common secret-looking commands are excluded automatically;
- camera, microphone, and folder permissions are requested only for the matching RDP features.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## Updates

Selective Remote uses `Resources/updates.json` to discover new GitHub releases. Release history is maintained in [CHANGELOG.md](CHANGELOG.md).

## Project status

Selective Remote is under active development. When reporting a bug, include the app version, reproduction steps, and the relevant session log where possible.

## License

Selective Remote is distributed under the [MIT License](LICENSE). FreeRDP, SDL, xterm.js, and other bundled components retain their own licenses; see [third-party notices](Resources/THIRD-PARTY-NOTICES.txt).

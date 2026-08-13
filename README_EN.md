# Selective Remote

**English** · [Русский](README.md)

[![CI](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml/badge.svg)](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://support.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Selective Remote** is a native macOS remote-access client that combines RDP, SSH terminals, dual-pane SFTP, SSH port forwarding, and SSH credential management in one application.

The project targets Apple Silicon and macOS 14 or later. The interface is available in English and Russian.

<!-- SELECTIVE_REMOTE_0_21_3_BEGIN -->
## What's new in 0.21.3

**0.21.3** is a small stability release following 0.21.2.

- Forwarding Manager: single-click selection is reliable again while double-click still starts a stopped tunnel;
- Terminal Grid: fixed the focus loop that could make History & Suggestions bounce endlessly between two connected panes;
- Forwarding context actions and the earlier 0.21.x UX fixes are preserved.
<!-- SELECTIVE_REMOTE_0_21_3_END -->

<!-- SELECTIVE_REMOTE_0_21_2_BEGIN -->
## What's new in 0.21.2

**0.21.2** is a UX/stability release on top of the larger Connection Center / Forwarding / Terminal update in the 0.21.x line.

- Connection Center: sortable columns and right-click runtime actions;
- Forwarding Manager: double-click start is restored for stopped tunnels, with a new context menu;
- Terminal: a user-requested disconnect is no longer reported as an `Exit code 255` error;
- Terminal Grid: fixed History & Suggestions bouncing between panes and added a large `+` action in the next empty grid cell;
- reconnecting an existing Terminal pane now uses the same server without an unnecessary profile picker;
- Server Commands: All / Active / Inactive service filters, active-first ordering, and aligned search UI;
- summary-card labels no longer get unnecessarily truncated.

Connection Center and Forwarding Manager screenshots remain available below in this README.
<!-- SELECTIVE_REMOTE_0_21_2_END -->

<!-- SELECTIVE_REMOTE_0_21_1_BEGIN -->
## What's new in 0.21.1

**0.21.1** is a major runtime-workflow update for Selective Remote. Active connections can now be observed and operated from unified workspaces without introducing parallel SSH or RDP session managers.

### Connection Center

Connection Center aggregates the **real runtime state** of active RDP, Terminal, SFTP, and SSH Forwarding sessions, including connection type, profile, host/port, Jump Host or RDP Gateway, authentication mode, state, uptime, and relevant actions. RDP entries are backed by the actual SDL-FreeRDP process/session state rather than profile existence alone.

![Connection Center in Selective Remote 0.21.1](docs/images/connection-center-0.21.1.png)

### Forwarding Manager 2.0

The global Forwarding workspace presents Profile and Independent tunnels in one manager while preserving their distinct ownership, persistence, and runtime state. The inspector exposes route details, and the diagram adapts to Local, Remote, and Dynamic/SOCKS forwarding while showing Jump Hosts and proxies only when they are actually part of the route.

![Forwarding Manager 2.0 in Selective Remote 0.21.1](docs/images/forwarding-manager-0.21.1.png)

### Terminal, recovery, and diagnostics

- **Terminal Workspace 2.0** — clearer active tab/pane state, runtime status and uptime, quick reconnect, duplicate-with-connect, and stronger Broadcast Input indication;
- **Smart Reconnect** — bounded retry attempts with backoff for temporary transport failures, with no infinite reconnect loops;
- **Server Commands 2.0** — real remote Linux discovery and contextual systemd, logs, network, disk, and Docker/Podman actions through the existing Terminal/SSH session;
- **Quick Connect 2.0** — `user@host`, custom ports, authentication mode, SSH ID, Touch ID Key, ssh-agent, Jump Host, recent targets, and Save as Profile;
- **Diagnostics Center 2.0** — safe Copy/Export Diagnostic reports for RDP/Terminal/SFTP/Forwarding that exclude passwords, passphrases, Keychain secrets, and proxy secrets.

> External server addresses in the UI previews above have been anonymized.
<!-- SELECTIVE_REMOTE_0_21_1_END -->


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
- broadcast input to multiple active panes with an explicit warning state;
- pinned tabs, tab color markers, duplicate/reconnect, and drag-and-drop ordering;
- terminal command palette on `⇧⌘K` and global **Quick Connect** on `⌘K`;
- 14 themes plus font, cursor, sizing, and window-opacity controls.

### SSH credentials and Touch ID

Each SSH profile can explicitly select an authentication mode:

- **Automatic**;
- **Password**;
- **SSH key**;
- **Touch ID Key**;
- **ssh-agent / `~/.ssh/config`**.

Saved SSH passwords are stored only in **macOS Keychain** and are excluded from profile exports. A saved password can require Touch ID before Selective Remote releases it to OpenSSH.

Selective Remote can generate SSH keys, import existing private keys, and safely append a public key to the server's `~/.ssh/authorized_keys` without overwriting existing entries. The global **Keychain** workspace shows SSH IDs, Touch ID keys, saved passwords, OpenSSH certificates, certificate authorities, and `known_hosts`.

OpenSSH `*-cert.pub` files are inspected and used through `CertificateFile`. SSH CA public keys can be registered in Keychain; when the matching private CA key exists next to the public key, Selective Remote can issue a standard OpenSSH certificate through the system `ssh-keygen`. The private CA key remains a normal file and is never copied into Keychain.

The **Known Hosts** view reads `~/.ssh/known_hosts`, displays SHA256 fingerprints, and warns when the server's current host key differs from the saved value. New host keys are never accepted automatically by this manager.

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

Forwarding is an independent workspace rather than a side effect of the selected connection card. The list and inspector are separated, active routes are visually highlighted, double-click starts a tunnel, and context menus expose start/stop/restart/copy/delete actions. It supports:

- local forwarding;
- remote forwarding;
- SOCKS5;
- saved profiles or manual SSH targets;
- password authentication through Keychain/AskPass;
- SSH keys and ssh-agent;
- keepalive and forwarding-failure detection.

### SSH config, Quick Connect, and Jump Hosts

Selective Remote keeps passing `Host` aliases to the system OpenSSH client, so native `~/.ssh/config` features such as `Include`, `IdentityFile`, `Match`, and other options continue to work. Quick Connect also discovers concrete `Host` entries from `~/.ssh/config` and can import them as Selective Remote profiles without copying secrets.

For bastion scenarios an SSH profile can select another saved SSH profile as a **Jump Host / ProxyJump**. The route is shown as `Mac → Jump Host → Target` and OpenSSH is launched with `-J`.

### Proxy

SSH profiles can use:

- direct connections;
- **HTTP CONNECT proxy**;
- **SOCKS5 proxy**.

The proxy configuration is shared by Terminal, SFTP, and Forwarding. HTTP CONNECT and SOCKS5 support username/password authentication. Proxy passwords are stored in macOS Keychain and handed to a dedicated helper through a short-lived `0600` secret file, so credentials never appear in OpenSSH command-line arguments. SSH profiles also include built-in diagnostics for TCP reachability, proxy configuration, and the selected authentication mode.

## Install

Download the DMG from the [latest GitHub Release](https://github.com/PastFly/Selective-Remote/releases/latest), open it, and drag **Selective Remote** into `Applications`.

Community builds without a Developer ID certificate use ad-hoc signing. On a new Mac, macOS may require a one-time approval in **System Settings → Privacy & Security → Open Anyway**, or by using **Open** from Finder's context menu.

A fully standard first launch requires Developer ID Application signing and Apple notarization.

## Navigation and context actions

- right-click an SSH/RDP profile for connect, Terminal/SFTP/Forwarding, favorites, duplicate, and delete actions;
- right-click a terminal tab for reconnect, pin, color, duplicate, or connection editing;
- right-click Keychain items for key, ssh-agent, and credential actions;
- right-click a tunnel for start, stop, restart, logs, duplicate, and delete;
- press **⌘K** for Quick Connect across profiles, hostnames, groups, and `~/.ssh/config` Hosts.

The **Help** menu now contains built-in guidance for the main application workspaces.

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

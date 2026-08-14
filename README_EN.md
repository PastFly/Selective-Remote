# Selective Remote

**English** · [Русский](README.md)

[![CI](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml/badge.svg)](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://support.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Selective Remote** is a native remote-access client for macOS that brings RDP, an SSH terminal, SFTP, SSH forwarding, diagnostics, and SSH credential management into one application.

The project targets Apple Silicon and macOS 14+. The interface is available in English and Russian.

## Main workspaces

### Connection Center

**Connection Center** presents the real state of active RDP, Terminal, SFTP, and Forwarding sessions in one place, including server, profile, authentication method, state, uptime, and available actions.

![Connection Center](docs/images/connection-center.png)

### RDP

- SDL-FreeRDP with windowed mode and true macOS fullscreen;
- Retina rendering without scaling the whole application window;
- multi-monitor RDP across Retina and external displays;
- manual monitor layout;
- correct Windows taskbar visibility in fullscreen;
- clipboard, audio, microphone, camera, printer, and folder redirection;
- RDP Gateway;
- Smart Reconnect after temporary network failures;
- macOS-oriented Command, Option, and Fn behavior;
- parallel RDP sessions for different profiles.

### Terminal Workspace

The built-in SSH terminal uses the system `/usr/bin/ssh` and supports:

- independent tabs and split/grid panes;
- different servers in different tabs and panes;
- persistent workspace layout;
- command history, favorites, templates, and suggestions;
- Server Commands for common Linux, systemd, network, disk, and container tasks;
- reconnect, duplicate, drag-and-drop ordering, and tab colors;
- Broadcast Input with an explicit warning;
- an action palette and quick SFTP handoff;
- configurable terminal themes, fonts, text size, and cursor.

### SFTP

A standalone dual-pane file manager with:

- local Mac and remote server panes;
- saved SSH profiles or temporary servers;
- a persistent SSH master so a password is not requested for every operation;
- upload and download of files and directories;
- drag and drop between Finder and SFTP;
- multi-selection;
- recursive directory deletion;
- folder creation, rename, and POSIX permissions;
- large-transfer progress, transferred size, and speed;
- periodic remote refresh;
- path history and suggestions;
- editing of remote UTF-8 files.

### Forwarding Manager

The global SSH forwarding workspace combines profile tunnels and independent tunnels while keeping their settings and runtime state separate.

- Local forwarding;
- Remote forwarding;
- Dynamic / SOCKS5;
- saved SSH profiles or temporary SSH targets;
- Keychain/AskPass, SSH IDs, and ssh-agent;
- keepalive and port-open error diagnostics;
- an Inspector with parameters and a visual route diagram;
- quick start/stop/restart and context actions.

![Forwarding Manager](docs/images/forwarding-manager.png)

### Keychain

The global **Keychain** workspace brings together:

- SSH IDs;
- Touch ID Keys;
- saved SSH passwords;
- OpenSSH certificates;
- SSH Certificate Authorities;
- `~/.ssh/known_hosts`.

SSH passwords and passphrases are stored in macOS Keychain. Saved SSH passwords can optionally require Touch ID confirmation before use.

Selective Remote can create and import SSH keys, work with `ssh-agent`, install a public key without overwriting `authorized_keys`, inspect OpenSSH certificates, and verify saved host keys.

In the community implementation, **Touch ID Key** requires biometrics before the selected ECDSA key is used, but the private key itself remains a regular OpenSSH file; it is not a Secure Enclave key.

### Quick Connect, Jump Host, and Proxy

**Quick Connect** can open a saved profile, `user@host`, or a temporary SSH target and optionally save it as a profile.

For bastion scenarios, an SSH profile can use another saved profile as a **Jump Host / ProxyJump**. HTTP CONNECT and SOCKS5 proxies with authentication are also supported.

### Diagnostics Center

**Diagnostics Center** presents RDP, Terminal, SFTP, and Forwarding state, application environment information, and active problems. The diagnostic report can be copied or exported.

The report intentionally does not read passwords, passphrases, Keychain values, proxy secrets, or private-key contents. SSH key and certificate paths are reduced to a basename where needed for a safe report.

### Appearance, language, and updates

- system, light, and dark application themes;
- separate terminal themes;
- multiple text sizes and interface density options;
- English and Russian UI;
- built-in update checks;
- DMG download with SHA-256 verification;
- update installation only after explicit user confirmation.

## Security

Selective Remote prefers native macOS and OpenSSH mechanisms:

- SSH passwords and related secrets are stored in macOS Keychain;
- exported profiles do not contain saved passwords;
- new SSH host keys are not accepted automatically;
- proxy passwords are not passed in OpenSSH command-line arguments;
- Diagnostics Center redacts potential secrets before Copy/Export;
- private SSH keys remain user-owned files and are not copied into application profiles.

Verify trust in Jump Hosts, proxies, certificate authorities, and changed host keys before using them.

## System requirements

- macOS 14 or later;
- Apple Silicon for the prebuilt arm64 DMG releases;
- network access to the required RDP/SSH servers;
- macOS microphone, camera, and other device permissions are needed only when the corresponding redirection is enabled.

## Installation

1. Download the DMG from the [latest GitHub Release](https://github.com/PastFly/Selective-Remote/releases/latest).
2. Open the disk image.
3. Drag **Selective Remote** to `Applications`.
4. Launch the application.

Community releases without a Developer ID may use ad-hoc signing. In that case, macOS may require a one-time approval in **System Settings → Privacy & Security** or via Finder's context menu.

## Quick start

### RDP

1. Create an RDP profile.
2. Enter the computer, username, and optional RDP Gateway.
3. Choose windowed/fullscreen mode and displays.
4. Configure the required device redirection.
5. Click **Connect**.

### SSH

1. Create an SSH profile or open Quick Connect.
2. Enter the hostname/IP, username, and port.
3. Choose password, SSH ID, Touch ID Key, or the system `ssh-agent` / `~/.ssh/config`.
4. Configure a Jump Host or Proxy when needed.
5. Open Terminal, SFTP, or Forwarding.

## Building from source

Basic project checks:

```bash
swift test
swift build -c release
```

Build and install the app locally:

```bash
bash scripts/build_and_install.sh
```

Additional documentation:

- [BUILD-RU.md](BUILD-RU.md)
- [Publishing](docs/PUBLISHING-RU.md)
- [Release preparation](docs/RELEASING-RU.md)

## Changelog

Release-specific history lives in [CHANGELOG.md](CHANGELOG.md). The README describes the current product instead of duplicating release notes.

## License

The project is distributed under the [MIT License](LICENSE).

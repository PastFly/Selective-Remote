# Selective Remote

**English** · [Русский](README.md)

[![CI](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml/badge.svg)](https://github.com/PastFly/Selective-Remote/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://support.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Selective Remote is a native macOS client that brings multi-monitor RDP, SSH,
dual-pane SFTP, independent terminal workspaces, and SSH port forwarding into a
single application.

The interface is available in English and Russian. It follows the macOS
language by default, or you can explicitly select System Default, Russian, or
English in the application's appearance settings.

## Highlights

- SDL-FreeRDP sessions with multi-monitor, Retina, full-screen, and windowed modes;
- macOS-friendly keyboard mapping, clipboard, audio, microphone, camera, printer,
  and folder redirection;
- an independent SSH workspace with up to eight tabs and one, two, or four-pane
  layouts, where every tab can connect to a different server; panes fill the
  available workspace and can be reordered with drag and drop;
- local command history, searchable suggestions, favorites, templates, and
  server-aware service and container commands;
- standalone dual-pane SFTP with a saved profile or a temporary hostname/IP,
  plus search, transfer queue, drag and drop, remote text editing, POSIX
  permissions, and persistent sessions;
- independent local, remote, and SOCKS forwarding rules, each with its own SSH
  target;
- local profiles with passwords and passphrases stored only in macOS Keychain.

## Install

Apple Silicon users can download the DMG from the
[latest GitHub Release](https://github.com/PastFly/Selective-Remote/releases/latest),
open it, and drag **Selective Remote** into `Applications`. End users do not need
Homebrew, FreeRDP, SDL, or the source code.

If a community DMG is not signed with a Developer ID certificate, macOS may ask
you to confirm the first launch in **System Settings → Privacy & Security**.

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

Build the distributable application and DMG with:

```bash
./scripts/build_app.sh
```

## SSH terminal workspace

Open **Terminal** in the main sidebar. Create a tab and either choose a saved SSH
profile or enter a temporary `username@host:port` target. The connection starts
immediately after confirmation. Tabs keep independent processes, history,
suggestions, and detected server context.

Temporary sessions use `/usr/bin/ssh`, the system `ssh-agent`, and
`~/.ssh/config`. Password and key passphrases are entered directly into the
terminal and are not stored by the application.

## Standalone SFTP

Open **SFTP** in the main sidebar. The local Mac pane is available immediately;
in the remote pane, select a saved SSH profile or enter a temporary hostname/IP,
username, and port. Use **Change Server** to switch the remote endpoint without
opening a connection card. Background SFTP authentication uses an SSH key, an
authenticated system agent, or suitable `~/.ssh/config` settings.

## Independent forwarding

Open **Forwarding** in the main sidebar and create a local, remote, or SOCKS
tunnel. Each rule selects its own saved profile or temporary SSH target and is
not tied to the currently selected connection card. Background tunnels require
an SSH key, an authenticated system agent, or suitable `~/.ssh/config`; they
cannot request an interactive terminal password.

## Privacy and permissions

Microphone, camera, and folder permissions are needed only when their respective
redirection options are enabled. Denying any of them must not block a normal RDP
session. Exported profiles do not include passwords or private keys.

## Updates

Selective Remote checks its GitHub update feed at most once per day. A manual
check is available from **Selective Remote → Check for Updates…**. Release notes
are generated from [CHANGELOG.md](CHANGELOG.md).

## License

Selective Remote is distributed under the [MIT License](LICENSE). FreeRDP, SDL,
xterm.js, and other bundled components retain their own licenses; see
[third-party notices](Resources/THIRD-PARTY-NOTICES.txt).

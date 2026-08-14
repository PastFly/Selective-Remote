## 0.21.8

- The What's New button now opens a native Selective Remote window instead of sending the user to GitHub.
- Release history shows every skipped version between the installed and available versions, ordered from newest to oldest.
- Added loading, retry, and error states; the window remains readable when several releases were skipped.
- Added a separate `CHANGELOG_EN.md`; the application selects RU/EN release-note sources from the interface language and falls back to the other language when the preferred source is temporarily unavailable.
- The update manifest now includes separate RU/EN release-history URLs while preserving `releaseNotesURL` for compatibility with older application versions.
- Added regression tests for skipped-version filtering, release ordering, and localized history-URL decoding.

## 0.21.7

- Finished the application text-size work: Small / Normal / Large / Very Large now use four clearly distinct native point sizes without scaling the whole window or interfering with Retina/DPI.
- Improved Keychain: selected rows use system contrast for icons, and SSH IDs, certificates, passwords, and Known Hosts use more consistent Russian localization.
- Refined Diagnostics Center: user-facing labels and states were localized, content width is bounded on wide windows, while the technical Raw Report remains a separate diagnostic format.
- README.md and README_EN.md were synchronized and rewritten as current product documentation instead of a stack of historical release notes; RDP, Terminal Workspace, SFTP, Forwarding, Connection Center, Diagnostics, and Keychain are described in one structure.
- Added regression tests for text sizing, persistence, selected-state contrast, Diagnostics Center, and the current English documentation structure.

## 0.21.6

- Fixed fullscreen RDP on Retina and multi-monitor macOS configurations: the remote desktop no longer occupies only part of the screen, the correct 1× SDL framebuffer is preserved, and true fullscreen is restored.
- Fixed built-in MacBook display geometry: the Windows taskbar stays fully visible and the native macOS menu bar can again appear at the top edge.
- Fixed manual RDP monitor layouts: displays snap exactly to neighboring edges and saved micro-gaps are normalized before FreeRDP starts.
- Text-size settings now visibly affect the macOS interface; selected-item contrast in Keychain was improved.
- Diagnostics Center received improved Russian localization, adaptive layout, and better runtime-state presentation on wide windows.
- README was simplified: detailed history for older 0.21.x releases was moved from the top of the document to CHANGELOG.

## 0.21.5

- Updated the update mechanism: checks at launch and roughly every five hours, a new-version indicator, unobtrusive system notifications, and optional automatic download.
- Added user-confirmed DMG installation with progress, SHA-256/codesign/bundle-id validation, safe rollback, and restart without sudo; when the application directory is not writable, a manual Finder flow is used.
- Audited RU/EN localization for key user-facing areas and dynamic states.
- Added native appearance settings: System/Light/Dark, text size, and interface density; terminal themes are preserved and organized.
- Diagnostics Center was upgraded to a structured interface with search, sections, and Raw Report while keeping Copy/Export diagnostics safe.
- Forwarding route diagrams became adaptive: narrow inspectors switch to a vertical layout without mandatory horizontal scrolling.
- Added regression tests for update-notification policy.

## 0.21.4

- Improved Forwarding route diagrams: route nodes are wider and text can scale so IPv4/IPv6 endpoints and ports are not clipped.
- Local tunnel Destination can become confirmed green from real OpenSSH events after traffic reaches the local port and no later `connect failed` appears.
- Destination shows an error for `open failed: connect failed`; before the first real request the destination remains unknown.
- SSH tunnel logging now uses `LogLevel=DEBUG1` to expose listener creation, real forwarding attempts, and channel-open failures.
- Added a safe runtime summary at the beginning of the tunnel log: mode, ownership, bind, destination, SSH endpoint, auth type, Jump Host/Proxy, KeepAlive, and the last error — without password/passphrase data.
- Forwarding diagnostics now include local-listener confirmation and Destination state derived from the OpenSSH log.
- Added regression tests for Local forwarding runtime evidence and detailed DEBUG1 logging.

## 0.21.3

- Fixed unstable selection in Forwarding Manager: a single click reliably selects Profile and Independent tunnels while double-click still starts a stopped tunnel.
- Fixed an endless focus loop in the Command History & Suggestions panel when switching active Terminal panes in split/grid layouts.
- Programmatically hiding history from the previous Terminal pane no longer steals focus back; manually closing history still returns focus to the current terminal.
- Preserved Forwarding context actions and Terminal Grid fixes from 0.21.2.
- Added regression tests for tunnel selection and Terminal pane switching with history open.

## 0.21.2

- Connection Center gained column sorting and context actions for runtime connections.
- Forwarding Manager restored double-click start for stopped tunnels and added context menus for Profile and Independent tunnels.
- Manual Terminal disconnect is no longer reported as `Exit code 255`; Disconnect remains a normal state and does not trigger Smart Reconnect.
- Fixed a race in the Command History & Suggestions panel when moving between active split/grid terminal panes.
- Fixed clipped summary-card labels in Connection Center and Forwarding Manager.
- Reconnect in an existing Terminal pane now reconnects to the same server; choosing another server remains a separate action.
- Empty Terminal Grid cells now have a `+` button for quickly creating a new SSH pane.
- Server Commands 2.0 gained All / Active / Inactive filtering, active-service sorting, and an aligned search field.
- Added regression tests for the new Terminal/Grid, Connection Center, Forwarding, and Server Commands scenarios.

## 0.21.1

- Added Connection Center — a unified view of real runtime RDP, Terminal, SFTP, Profile Forwarding, and Independent Forwarding connections with state, uptime, inspector, and actions.
- Reworked Forwarding into Forwarding Manager 2.0 with separate Profile/Independent ownership, inspector, logs, and Local / Remote / Dynamic route diagrams that show Jump Host and proxy only when actually used.
- Terminal Workspace 2.0 received clearer active tab/pane state, runtime states and uptime, quick reconnect, duplicate-with-connect, and stronger Broadcast Input indication.
- Added Smart Reconnect with bounded attempts and backoff for temporary network failures; manual disconnect does not auto-reconnect and Touch ID is not repeatedly requested.
- Server Commands 2.0 now builds commands from real remote discovery for systemd, logs, networking, disks, Docker/Podman, and other available tools using the existing Terminal/SSH session.
- Quick Connect 2.0 understands `user@host`, `user@host:port`, and ssh commands, and supports recent targets, auth mode, SSH ID, Touch ID Key, ssh-agent, Jump Host, and Save as Profile.
- Added Diagnostics Center 2.0 with safe Copy Diagnostic and Export Diagnostic for application runtime state; passwords, passphrases, Keychain secrets, and proxy secrets are excluded.
- Updated README.md and README_EN.md and added anonymized Connection Center and Forwarding Manager 2.0 previews.
- Expanded regression tests for runtime scenarios, reconnect, Server Commands, Quick Connect, and safe diagnostics.

## 0.20.18

- Fixed starting SSH tunnels by double-click in Forwarding.
- Fixed double-click for both independent tunnels and tunnels attached to a saved SSH profile.
- A single click still only selects a tunnel.
- Double-click starts a stopped tunnel without breaking selection state.

## 0.20.17

- Fixed repeated Touch ID requests after connecting SSH in Terminal Workspace.
- Background Server Commands discovery no longer asks for approval again after the active SSH session is already authorized.
- Server context survives navigation between application sections and is reused when returning to Terminal.
- A real reconnect asks for Touch ID once again, without an extra request for server context.
- Authorization remains isolated between different Terminal tabs and SSH connections.
- Command History & Suggestions was moved to a dedicated Terminal toolbar button.

## 0.20.16

- Fixed server-context retrieval for the active tab and Terminal Workspace pane.

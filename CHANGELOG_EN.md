## 0.21.16

- Added a live Terminal theme preview: hovering a theme updates only the enlarged preview, while the real terminal theme is applied only on click.
- Command suggestions are now fully keyboard accessible: Arrow keys select a suggestion, Enter applies the selected item, and Tab accepts the selected or first suggestion.
- Improved suggestion recovery after shell Tab completion, Backspace/Delete, and readline redraws so fixing a typo no longer requires retyping the whole command.
- Added configurable shell syntax highlighting for commands, options, strings, paths, variables, numbers, operators, and comments.
- Syntax highlighting can target only the current command or all shell command lines in the visible terminal viewport; previous commands can be dimmed and command names can be bold.
- Syntax colors follow the active terminal theme by default, with an optional persistent custom syntax palette.
- Full-viewport highlighting scans only visible xterm rows and does not modify PTY/SSH input, remote output, or server-provided ANSI colors.
- RDP, SFTP, Forwarding, privacy preflight, and other network runtime behavior were not changed in this release.

## 0.21.15

- Expanded Terminal appearance to 26 themes with compact SwiftUI previews, search, All / Dark / Light / Favorites filters, and persistent favorites.
- Custom terminal colors are now stored separately and survive switching to built-in themes while all existing theme identifiers and saved settings remain compatible.
- Added Known Host → SSH Profile creation for concrete known_hosts entries, including multi-address selection, port extraction, authentication selection, and duplicate detection. Hashed, marker, and wildcard entries are intentionally not converted, and ~/.ssh/known_hosts is never modified by profile creation.
- Fixed an application crash after granting camera or microphone permission in local diagnostics by safely bridging TCC callbacks back to MainActor before updating UI state.
- RDP fullscreen/Retina/multi-monitor/topology, native privacy preflight, SFTP runtime, and Forwarding runtime were not changed in this release.

## 0.21.14

- Minor improvements to the built-in help and the application's system menu.
- RDP, SSH, Terminal, SFTP, and Forwarding runtime behavior was not changed in this release.

## 0.21.13

- Completely refreshed the SSH profile editor in Connections with a modern header, vertical navigation, quick facts, and a responsive Mac → Jump Host → SSH server route summary.
- Split SSH settings into General, Authentication, Route, and Security while keeping Terminal, SFTP, and Tunnels as full-size workspaces without a cramped side inspector.
- Terminal Focus mode now exposes a permanently visible Restore Interface button instead of hiding the action in the ellipsis menu.
- Terminal Grid can now be selected and persisted with no open terminals; an empty grid immediately presents four SSH cells with a clear add-pane action.
- Fixed the top of the sidebar when an update and active sessions or tunnels are shown together: the Selective Remote title and update notice no longer collapse into narrow vertical columns.
- Added regression coverage for the modern SSH UI, independent workspaces, empty Grid, Focus mode, and stable update-notice layout.
- RDP fullscreen/Retina/multi-monitor/topology, system SSH/PTY, SFTP service, and Forwarding launch logic were not changed in this release.

## 0.21.12

- Performed a safe repository cleanup without changing user-facing application behavior.
- Removed the unused legacy Independent SSH tunnel view; the global Forwarding section continues to use the current Forwarding Manager.
- Redirected tunnel regression tests to the active Forwarding Manager while preserving Profile/Independent and double-click start coverage.
- Removed obsolete temporary materials: the emergency Retina patcher, its README, and two unused legacy screenshot versions.
- RDP fullscreen/Retina/multi-monitor/topology, SFTP runtime, and the active Forwarding runtime were not changed in this release.

## 0.21.11

- Completely refreshed the RDP profile editor in Connections with a modern profile header, vertical section navigation, quick facts, and a responsive connection summary.
- Existing working RDP settings continue to use the established logic: displays, RD Gateway, devices, folders, security, and the bottom connection bar were not rewritten.
- Added a persistent Description field to RDP profiles for purpose or connection notes.
- Preserved backward compatibility: existing profiles without Description decode with an empty value and require no migration.
- Selective Remote profile export and import preserve the new Description field.
- SSH profiles continue to use the existing interface.
- Added regression tests for legacy-profile compatibility and Codable/export-import round trips of Description.
- RDP fullscreen/Retina/multi-monitor/topology runtime, SFTP, and Forwarding were not changed in this release.

## 0.21.10

- Fixed Camera and Microphone permission diagnostics: System Check now distinguishes the main-app state from the last known privacy markers produced by real RDP Session runs, without reading TCC.db or triggering hidden permission prompts.
- System Check gained a Selective Remote readiness summary, SSH / RDP / Camera / Microphone / Updates health states, a Problems Only filter, and safe actions without automatic remediation.
- A one-time quiet post-upgrade check now verifies critical packaged components and the update feed after a real upgrade; it does not start SSH/RDP, Touch ID, or Camera/Microphone permission requests and only alerts for meaningful problems.
- The Diagnostics version card now opens the built-in release history, and What's New also shows the installed internal build number.
- Connection Center gained a single Reset action for search, filters, sorting, and column customization.
- Removed the deprecated NSRunningApplication activation option used on macOS 14.
- Fixed Swift 6 compatibility for the new Diagnostics System Check in GitHub Actions.
- README.md and README_EN.md now use current Connection Center and Forwarding Manager screenshots.
- RDP fullscreen/Retina/topology, SFTP runtime, and Forwarding runtime were not changed in this release.

## 0.21.9

- Added a permanent `Help → What's New…` command: release history can now be opened at any time, and a newly installed version is shown once automatically after an upgrade.
- Update Experience 2.0 now presents clearer update stages, the last successful check time, and bundled release history so installed notes remain available without GitHub access.
- Connection Center gained clickable summary cards, a separate state filter, persisted filters and sorting, configurable column visibility, and additional context actions.
- Terminal Workspace gained output search with `⌘F`, match navigation, keyboard tab switching, and double-click tab renaming.
- Keychain gained search and sorting across SSH IDs, saved SSH passwords, Known Hosts, and SSH CAs without changing the existing Inspector.
- Diagnostics Center gained a System Check section with safe preflight checks for the app, SSH, Keychain, Touch ID, macOS permissions, FreeRDP helpers, and the update feed without starting real RDP/SSH sessions or reading secrets.
- Preserved macOS 14.0 compatibility for configurable Connection Center columns and fixed Keychain search/sort compatibility with the Swift compiler used by GitHub Actions.
- Added regression tests for Update Experience, Connection Center, Terminal, Keychain, and Diagnostics; the 0.21.9 functional build passed the full CI workflow.

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

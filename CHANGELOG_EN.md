## 0.24.0

- Added custom connection tags: a profile can have multiple tags with creation, assignment, global rename, deletion, search, and compound filtering.
- The connection catalog can now switch between list and compact grid views; the resizable sidebar fits more profile cards per row.
- Added Touch ID App Lock on launch, wake, minimize, inactivity, or manually with `⌘⇧L`.
- Fixed a Swift 6 LocalAuthentication crash after successful Touch ID by moving authentication to safe `async/await` handling that resumes on MainActor.
- Closed App Lock bypasses through the separate Settings window, Session menu, menu-bar extra, and `⌘T`; disabling protection while locked now requires system authentication.
- Added a local RDP and SSH connection activity log with filters, search, and clearing; it stores no passwords, keys, commands, or terminal contents and redacts potential secrets from errors.
- Kept the existing Support Project destinations in the Help menu without subscriptions or paid plans.
- Added a dedicated CI workflow for safe ARM64 test DMG builds without creating a tag or production release.

## 0.23.0

- The Snippets library now has a group root, back navigation, persisted folder selection, and list/grid presentation modes.
- Fixed the library collapsing after an empty-area click by removing its dependency on unstable `List(selection:)` behavior and forced first-item selection.
- Snippet-to-group relationships now use a stable `groupID`; existing commands and targets migrate automatically without data loss.
- The in-terminal Snippets panel adds Run Here, Insert Without Running, and Copy Command while keeping execution on assigned targets.
- The existing global remote Terminal is now named SSH, while a new Terminal section launches the current user's local login shell.
- Local Terminal supports up to eight tabs, a per-tab working directory, history, themes, Snippets, and the native `⌘T` shortcut.
- The PTY runtime now supports a working directory without changing the application process directory.
- Added a native Settings window with Appearance and Updates sections, installed/available version status, release history, manual checks, and automatic check/download controls.
- Theme, text size, and density now apply to Help, Settings, and What's New; transparency affects the backdrop without dimming controls and text.
- Added migration, persistence, PTY, SwiftUI, and browser regression coverage for the new model.

## 0.22.6

- Added a global Snippets library shared by all Terminal workspaces and SSH profiles.
- A snippet can target up to eight saved SSH hosts; existing templates migrate without data loss.
- Snippet execution reuses an active SSH session or connects the required target and sends the command once the shell is ready.
- Added groups, search, create, edit, duplicate, move, and reliable snippet deletion.
- Added double-click, Enter, and context-menu execution plus inline creation inside empty groups.
- The global library now reports per-target delivery state and can manually disconnect the related SSH sessions with confirmation.
- The in-terminal Snippets editor now supports assigning multiple targets.
- Added migration, persistence, bridge, and browser regression coverage for global Snippets.

## 0.22.5

- Fixed application crashes during Server → Server and Server → Mac drag-and-drop in release builds.
- Internal SFTP drag-and-drop no longer reads string payloads through the problematic NSItemProvider data callback.
- String drag payloads are now loaded through an NSString/object representation compatible with the Xcode 16.2 production build.
- The fix was validated using a DMG built by GitHub Actions with the same toolchain used for production releases.

## 0.22.4

- Fixed an application crash when dragging files between two SFTP servers.
- Moved NSItemProvider callbacks completely out of MainActor-isolated SwiftUI views into a dedicated non-actor bridge.
- Drag-and-drop handling now hops back to MainActor only after Foundation has delivered a Sendable value.
- The fix also covers Mac ↔ Server and Server → Mac file transfer paths.
- Added runtime regression tests for asynchronous NSItemProvider delivery and actor isolation.

## 0.22.3

- Fixed an application crash when dragging files between two SFTP servers.
- Fixed NSItemProvider callback actor isolation so drag-and-drop safely switches to MainActor before accessing the SFTP Workspace.
- Added a regression test protecting Server → Server drag-and-drop from this crash.

## 0.22.2

- Stabilized the SFTP Workspace lifecycle and transfer cancellation when panes are disconnected or closed.
- Fixed shared OpenSSH ControlMaster lifecycle management across multiple SFTP panes.
- Deleting an SSH profile now also removes its stored proxy credentials.
- Connection Center now operates on real SFTP Workspace panes and supports opening, disconnecting, and reconnecting individual panes.
- Fixed Mac ↔ Server and Server ↔ Server drag and drop.
- Stabilized SFTP layout after Transfer Queue updates and constrained expanded transfer history to a scrollable area.
- Removed the legacy single-session SFTP runtime, legacy observers, and obsolete SFTPBrowserView; AppModel.sftpWorkspace is now the single SFTP runtime source of truth.
- Removed the stale default tag from the Release workflow; the release version must now be supplied explicitly.
- RDP monitor topology and hot-plug behavior were intentionally left unchanged.

## 0.22.1

- Fixed fullscreen multi-monitor RDP recovery when physical displays are connected or disconnected: Selective Remote now performs a controlled reconnect with the currently available selected monitors instead of leaving stale, stuck, or jumping windows.
- Preserved the primary display and virtual monitor order across hot-plug changes: a `Mac – HP1 – HP2` layout now remains `Mac – HP2` after the middle monitor is disconnected even when macOS reassigns local display coordinates.
- Added a temporary application-scoped CoreGraphics alignment for conflicting local display layouts; the user's persistent macOS Displays configuration is not changed.
- Fixed the MacBook clamshell scenario so RDP rebuilds on the remaining external displays without the previous `SDL:Invalid display` failure.
- Reduced the delay before RDP recovery after an external monitor is disconnected, and restored the full saved monitor layout automatically when a selected display returns.
- Fixed Dynamic Window mode: SDL monitor probes no longer cancel startup and dynamic resolution follows window resizing.
- Improved handling of expected RDP termination during monitor reconfiguration and connection error reporting; a user-requested disconnect does not trigger Smart Reconnect.
- Added regression coverage for monitor hot-plug, clamshell, monitor ordering, Dynamic Window, and Smart Reconnect.

## 0.22.0

- Added a new global SFTP Workspace with two independent panes; each pane can show this Mac or a separate SSH/SFTP server.
- SFTP inside an SSH profile now uses the same multi-server Workspace: the current host opens automatically and the opposite pane can switch from the Mac to any saved or temporary SFTP server.
- Added independent SFTP tabs and quick server switching per pane.
- Added Server → Server copies through a safe temporary staging copy on the Mac without passing credentials directly between servers.
- Restored selection and multi-select, context actions, navigation, sorting, filtering, properties, and permissions inside SFTP Workspace.
- Added drag and drop between server panes and between local and remote panes.
- Transfer Queue now shows real transfer stages, bytes, percentage, speed, and ETA, with pause, resume, cancel, and retry controls.
- Server → Server transfers show two-stage A → Mac → B progress.
- Added Terminal Smart Links and SSH Agent Forwarding support; Agent Forwarding is disabled by default.

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

# Notification Center v1 synthetic rendering evidence

`NotificationCenterRenderedTests` rendered 80 Mac combinations: RU/EN ×
Light/Graphite × 320/390 points × empty, device, invitation, sync error,
conflict, fail-closed, host identity, mixed, read and resolved. The test can
save the full local matrix with `SR_CAPTURE_NOTIFICATION_MATRIX=<directory>
swift test --filter NotificationCenterRenderedTests`.

The Cloud screenshots use the production CSS and notification modules through
`cloud/tests/fixtures/notification-center.html`. Representative desktop/mobile
states were inspected for layout and DOM semantics. The browser keyboard pass
covered Tab, Shift-Tab, Enter, Space and Escape. The fixture is synthetic:
these images are visual evidence, not authenticated staging or Owner acceptance.

The seven committed PNGs are representative samples for PR review. The full
Mac matrix and additional Cloud captures were produced locally; no account
data, Vault content or credentials were used.

# Global Sync status utility: synthetic rendering evidence

`SyncStatusUtilityRenderedTests` rendered 72 combinations: RU/EN ×
Light/Graphite × 220/280/360 points × synced, syncing, unknown, error,
conflict and Team fail-closed. The six committed PNGs show representative
states and widths. To reproduce the full local matrix:

```sh
mkdir -p /private/tmp/sync-status-rendered-matrix
SR_CAPTURE_SYNC_STATUS_MATRIX=/private/tmp/sync-status-rendered-matrix \
  swift test --filter SyncStatusUtilityRenderedTests
```

The fixture uses the real `SyncStatusUtilityView` in a small synthetic header
with the existing bell kept at the upper edge. It checks the status control's
language, color, icon and narrow layout. It is not an installed-app or Owner
manual acceptance result. The production `ContentView` keeps its existing
Notification bell and existing Sync Center sheet; the status button is now in
the service area under the sidebar header, outside primary navigation.

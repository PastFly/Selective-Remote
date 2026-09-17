# Team Snippets in the browser

The Snippets tab now projects the existing encrypted `snippet.data.folder` path as a tree. It does not add an API endpoint, database migration, record type, or encryption format.

- **New folder** selects a parent and a name, then opens the first snippet. The folder becomes shared only after that snippet is saved and synchronized, matching the native client. No synthetic or empty folder record is created. Empty folders are not persisted independently.
- **New child folder** is also available through the `+` beside a folder. Editing a snippet's Folder field moves that snippet; an empty field moves it out of folders. Existing extension fields are preserved.
- Search matches the full command, title and folder. Folder filtering includes descendants, not similarly named siblings. Name sorting uses numeric order; modification sorting is newest first within each folder.
- Disclosure buttons, Expand all and Collapse all do not write to the Vault. Search/filter results start expanded without overwriting the unfiltered collapse choices. These in-memory choices survive re-rendering, not browser reloads. Lock, logout and a Team/Vault switch clear folder labels, search, collapse state and editor drafts. Changing resource sections resets the snippet filters.
- Viewers can browse, search, sort and disclose folders, but cannot create/edit/delete. Card actions and the existing 18×18 checkbox remain separate from opening the card.

## Verification

`npm --prefix cloud test` includes `team-snippet-browser.test.mjs`: native data shape, old folderless records, edit preservation, validation, virtual ancestors, reserved/prototype-like names, search boundaries, numeric and date sorting, counts, accessible disclosure and select-visible behavior.

Optional browser smoke:

```sh
python cloud/tests/browser/team-snippets-smoke.py /tmp/team-snippet-smoke
```

It requires the Python `playwright` package and Chromium (system `chromium` or Playwright's installation). It loads local HTML/CSS/modules into an offline browser fixture, uses the real workspace handlers and modern selects, and substitutes only the Vault/API boundary. It verifies creation/editing/filtering, role restrictions, scope cleanup and card/checkbox behavior; it captures Graphite, Emerald, Light and narrow-screen screenshots. It is not a live-server, PostgreSQL or cross-device synchronization test.

Before accepting a deployment, verify one existing native nested folder in the browser, then create or move a browser snippet and confirm it appears in the same Team Vault in the native app. Public-main merge and staging deployment remain separate approvals.

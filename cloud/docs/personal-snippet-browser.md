# Personal Snippet folders

This closes the Personal/Team browser gap reported after PR #187. Personal Snippets use the same tree renderer but retain a separate scope, editor and native data adapter.

Personal folder paths are `data.category` and, for native exports, `template.category`. They are **not** Team Snippet `data.folder`. Existing Personal groups and nested paths are projected without rewriting the Vault. Records lacking a group remain visible under No folder; a malformed portable template does not hide an otherwise readable record.

The personal Snippets view provides New folder, New child folder, expansion/collapse, title/full-command/path search, descendant filtering and individual moves in the editor. Its former Host-folder filter now switches to the correct context. New groups are materialized after saving their first snippet, matching the Team web flow; independent empty folders, group-wide rename and drag-and-drop are outside this change. Expansion state is in-memory only.

Edits update both outer title/body/category and the existing native template, retaining profile/target IDs and extension fields. A move resets the old group ID so the new category can be resolved; explicit ungrouping is preserved. Invalid or mismatched templates fail the write rather than discarding configuration. The existing portable template encoding remains unchanged; no source files are encoded as data payloads.

macOS now materializes groups after both initial import and a newer synchronized snapshot, not only after application restart. Incoming native group IDs are adopted to avoid repeatedly replacing them with local aliases. An updated native build is needed for this immediate group-materialization behavior. The browser can read existing native categories once its own server assets are deployed; installing the DMG alone does not update the website.

## Verification

- `npm --prefix cloud test` includes adapter/preservation/invalid-data tests and a round trip through the real encrypted Personal Vault controller.
- Swift `PersonalSnippetFolderSyncTests` covers import, live replacement, move/ungroup, stable imported IDs and exporter/importer compatibility.
- `python cloud/tests/browser/personal-snippets-smoke.py /tmp/personal-snippets` requires Python Playwright and Chromium. It loads the real DOM, scripts and CSS offline, substituting only the in-memory Vault boundary. It checks controls and editor handlers, category/template consistency, full-command search, scope cleanup, checkbox/card isolation, themes and narrow layout.
- The existing Team browser smoke remains a regression gate. Neither offline browser fixture proves live cross-device synchronization.

API, server authorization, migration ledger, encryption implementation and dependencies are unchanged. Main merge and staging deployment remain separate approvals. After rollout, accept one pre-existing Personal nested folder and one browser-created/moved Personal snippet on the updated running macOS client; no repeated full Team acceptance matrix is required.

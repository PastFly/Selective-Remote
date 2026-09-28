# Access & Sharing 0.33 — interactive concept

Static, offline Mac + Cloud UX prototype for Owner review. It is **not** the
current app, an authorization implementation, or a deployed Cloud page. All
people, groups, resources and changes are synthetic and live only in browser
memory. Refreshing resets the demonstration.

Open `index.html` from a local static server, for example:

```sh
python3 -m http.server 8766 --directory docs/prototypes/access-sharing-033
```

Then visit `http://127.0.0.1:8766/`. Use the top controls for Mac/Cloud,
RU/EN and Light/Graphite. Right-click a Mac resource (or its visible Share
button), choose a recipient and preset, preview then apply a demo grant.
Cloud has Members, Groups and Resources, both Access Manager perspectives,
Effective Access and bulk grant/revoke preview. Resize the browser to inspect
narrow and mobile layouts.

The prototype intentionally disables `Credential.Use without Reveal` and
explains that the current whole-Team-Vault client decryption cannot enforce
that security property. See the source-backed current architecture audit and
permission/threat design in the Continuity repository checkpoints dated
2026-09-29. No backend, crypto, schema, feed or production state is touched.

import test from "node:test";
import assert from "node:assert/strict";
import { accessConsequence, accessErrorCopy } from "../public/access-copy.js";
import { createAccessManager } from "../public/access-manager.js";

// Catches a preview showing protocol bit masks instead of the permission changes.
test("credential consequences name gained permissions and distinguish no lost permissions", () => {
  const detail = { gainedMask: 7, lostMask: 0, after: { policyEffective: { paths: [] } } };
  const english = accessConsequence(detail, "en", "CREDENTIAL");
  assert.match(english, /View metadata, Reveal secret, Edit/);
  assert.match(english, /Lost permissions: None/);
  assert.doesNotMatch(english, /permissions: [0-9]/);
  const russian = accessConsequence(detail, "ru", "CREDENTIAL");
  assert.match(russian, /Просмотр метаданных, Раскрытие секрета, Редактирование/);
  assert.doesNotMatch(russian, /View|Reveal|Edit|права: [0-9]/);
});

test("consequences describe every supported permission bit without inventing device usability", () => {
  const text = accessConsequence({ gainedMask: 0, lostMask: 29, after: { policyEffective: { paths: [{}] } } }, "en", "VAULT");
  assert.match(text, /View, Edit, Manage access, Create resources/);
  const folder = accessConsequence({ gainedMask: 33, lostMask: 0, after: { policyEffective: { paths: [] } } }, "en", "FOLDER");
  assert.match(folder, /View, Manage folder/);
  assert.match(text, /Other paths remain/);
  assert.doesNotMatch(text, /confirmed|available on this device/);
});

test("credential permission errors explain the requirement in the selected language", () => {
  for (const code of ["credential_edit_requires_reveal", "invalid_access_permissions"]) {
    const ru = accessErrorCopy({ code }, "ru");
    assert.match(ru, /редактир|Редактир/);
    assert.match(ru, /секрет/);
    assert.doesNotMatch(ru, /Credential|Edit|Reveal/);
    const en = accessErrorCopy({ code }, "en");
    assert.match(en, /edit|Edit/);
    assert.match(en, /secret/);
  }
});

function fixture(locale = "en", formatState = "V2_PREPARING") {
  const doc = { documentElement: { lang: locale }, addEventListener() {}, removeEventListener() {} };
  function node(tag = "div") {
    const n = { tagName: tag, ownerDocument: doc, children: [], dataset: {}, attributes: {}, events: {}, textContent: "", append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; }, setAttribute(k, v) { this.attributes[k] = v; }, addEventListener(k, f) { this.events[k] = f; }, removeEventListener() {}, focus() { doc.activeElement = this; } };
    return n;
  }
  doc.createElement = node;
  const teamID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", vaultID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", userID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const empty = async () => ({ rows: [], nextCursor: null });
  const client = { listVaults: async () => ({ rows: [{ id: vaultID, name: "QA", formatState }], nextCursor: null }), getContext: async () => ({ formatState, policyMutationAvailable: true, groupMutationAvailable: true, blockers: [] }), listMembers: async () => ({ rows: [{ id: teamID, userID, displayName: "Alex" }], nextCursor: null }), listGroups: empty, listResources: empty, listGrants: empty, resourcesByPrincipal: empty, listDevices: empty };
  const root = node(), manager = createAccessManager({ root, client, context: { teamID, vaultID, role: "owner" } });
  const nodes = (n = root) => [n, ...n.children.flatMap(c => typeof c === "object" ? nodes(c) : [])];
  const text = () => nodes().map(n => n.textContent).join("\n");
  return { manager, root, nodes, text };
}

test("vault state rendering translates protocol states into honest access availability", async () => {
  for (const locale of ["ru", "en"]) for (const state of ["V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE"]) {
    const f = fixture(locale, state);
    await f.manager.refresh();
    const text = f.text();
    assert.doesNotMatch(text, /\b(?:V[12](?:_[A-Z_]+)?|PREPARING|READY|ACTIVE)\b|cryptographic|policy changes/);
    if (locale === "ru") assert.doesNotMatch(text, /Vault|Credential|Edit|Reveal/);
    if (state === "V2_PREPARING") assert.match(text, locale === "en" ? /does not confirm.*device/ : /не подтверждает.*устройств/);
    if (["V2_READY", "V2_ACTIVE"].includes(state)) assert.match(text, locale === "en" ? /unavailable/ : /недоступны/);
    f.manager.destroy();
  }
});

test("selected member heading uses a localized category rather than USER", async () => {
  for (const locale of ["ru", "en"]) {
    const f = fixture(locale);
    await f.manager.refresh();
    const directory = f.nodes().find(n => n.className === "access-directory");
    const button = f.nodes(directory).find(n => n.tagName === "button");
    button.events.click();
    for (let i = 0; i < 8; i++) await Promise.resolve();
    assert.doesNotMatch(f.text(), /\bUSER\b/);
    assert.match(f.text(), locale === "en" ? /Member · cccc/ : /Участник · cccc/);
    f.manager.destroy();
  }
});

// Preview impact can include a resource outside the current directory page.
test("off-page credential consequences use the authoritative path permission names", () => {
  const detail = { gainedMask: 1, lostMask: 0, after: { policyEffective: { paths: [{ permissions: ["ViewMetadata"] }] } } };
  assert.match(accessConsequence(detail, "en"), /Gained permissions: View metadata;/);
});

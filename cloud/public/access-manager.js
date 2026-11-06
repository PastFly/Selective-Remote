import {
  accessLabel,
  normalizeMutation,
  permissionsFor,
  presetMask,
  validateMask,
  effectiveSummary,
} from "./access-model.js";
import {
  accessCopy,
  accessErrorCopy,
  accessConsequence,
  accessReasonCopy,
} from "./access-copy.js";

export function createAccessManager({
  root,
  client,
  context = {},
  resolveLabel = () => null,
  onCommitted = () => {},
  publicationDriver = null,
} = {}) {
  if (!root?.ownerDocument || !client)
    throw new Error("invalid_access_manager");
  const documentValue = root.ownerDocument;
  root.setAttribute("translate", "no");
  if (!root.hasAttribute?.("tabindex")) root.setAttribute("tabindex", "-1");
  let focusIndex = 0,
    previewSequence = 0,
    focusPreview = false,
    groupNameDraft = "",
    editSequence = 0,
    draftFocus = null,
    restoreDraftFocus = false;
  let scope = { ...context },
    generation = 0,
    draftGeneration = 0,
    destroyed = false,
    capability = null,
    tab = "members",
    loading = false,
    error = null,
    status = "",
    draft = null,
    impact = null,
    committing = null,
    details = null;
  let wholeDriver = null, moveParentFolderID = null;
  let selectedGroup = null,
    selectedResource = null,
    selectedPrincipal = null,
    selectedDevice = null,
    deviceResult = null,
    permissionKind = "HOST",
    permissionMask = 1,
    targetScope = "RESOURCE";
  const recipients = new Map(),
    targets = new Map(),
    grantSelection = new Map();
  const pages = {};
  for (const key of [
    "vaults",
    "members",
    "groups",
    "resources",
    "grants",
    "groupMembers",
    "principalResources",
    "who",
    "devices",
  ])
    pages[key] = { rows: [], nextCursor: null, search: "", sequence: 0 };
  const locale = () =>
    documentValue.documentElement?.lang === "en" ? "en" : "ru";
  const t = (key) => accessCopy(key, locale());
  const active = (g) => !destroyed && g === generation;
  const node = (tag, text = null, attrs = {}) => {
    const n = documentValue.createElement(tag);
    if (["button", "input", "select"].includes(tag))
      n.dataset.accessFocus = String(focusIndex++);
    if (text !== null) n.textContent = String(text);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") n.className = v;
      else if (k === "value") n.value = v;
      else n.setAttribute(k, String(v));
    }
    return n;
  };
  const button = (key, fn, disabled = false) => {
    const n = node("button", t(key), { type: "button" });
    n.dataset.accessAction = key;
    n.disabled = disabled;
    n.addEventListener("click", () => {
      void run(fn);
    });
    return n;
  };
  const input = (label, value, change, attrs = {}) => {
    const wrap = node("label", t(label));
    const n = node("input", null, { ...attrs, value });
    n.addEventListener("change", () => {
      change(n.value);
      render();
    });
    wrap.append(n);
    return wrap;
  };
  const select = (label, options, value, change) => {
    const wrap = node("label", t(label));
    const n = node("select");
    for (const [id, text] of options) {
      const option = node("option", text, { value: id });
      option.selected = id === value;
      n.append(option);
    }
    n.value = value ?? "";
    n.addEventListener("change", () => {
      void run(() => change(n.value));
    });
    wrap.append(n);
    return wrap;
  };
  const check = (text, checked, fn) => {
    const label = node("label", null, { class: "access-check" });
    const n = node("input", null, { type: "checkbox" });
    n.checked = checked;
    n.addEventListener("change", () => {
      void run(() => fn(n.checked));
    });
    label.append(n, node("span", text));
    return label;
  };
  const policyAvailable = () =>
    (capability?.formatState === "V2_PREPARING" || (capability?.wholePublication === true && wholeDriver?.enabled)) &&
    capability?.policyMutationAvailable === true;
  const groupAvailable = () =>
    (capability?.formatState === "V2_PREPARING" || (capability?.wholePublication === true && wholeDriver?.enabled)) &&
    capability?.groupMutationAvailable === true;
  const ref = (row) => ({
    teamID: scope.teamID,
    vaultID: scope.vaultID,
    id: row.id ?? row.resourceID,
    policyKind: row.policyKind ?? "RESOURCE",
    resourceVersion: row.resourceVersion,
  });
  const label = (row) => accessLabel(ref(row), resolveLabel, t);
  function resetPages() {
    for (const p of Object.values(pages)) {
      p.rows = [];
      p.nextCursor = null;
      p.search = "";
      p.kind = "";
      p.sequence++;
    }
  }
  function clearDraft() {
    draft = null;
    impact = null;
    draftGeneration++;
    grantSelection.clear();
  }
  async function run(fn) {
    const g = generation;
    try {
      await fn();
    } catch (e) {
      if (active(g)) {
        error = e;
        render();
      }
    }
  }
  function setDraft(value) {
    if (committing) throw new Error("access_commit_in_progress");
    if (!draft) draftFocus = documentValue.activeElement?.dataset?.accessFocus ?? null;
    editSequence++;
    details = null;
    draft = value === null ? null : value.type === 'RESOURCE_EDIT' && capability?.wholePublication === true
      ? structuredClone(value) : normalizeMutation(value);
    impact = null;
    draftGeneration++;
    error = null;
    status = "";
    render();
    return draft;
  }
  function gate() {
    if (!draft) throw new Error("invalid_access_request");
    if (!(draft.changes ? policyAvailable() : groupAvailable()))
      throw new Error(
        ["V2_READY", "V2_ACTIVE"].includes(capability?.formatState) ||
        capability?.blockers?.includes("crypto_publication_required")
          ? "crypto_publication_required"
          : capability?.formatState === "V1_ACTIVE"
            ? "access_v2_preparing_required"
            : "team_permission_denied",
      );
  }
  async function loadPage(key, more = false) {
    const g = generation,
      p = pages[key],
      seq = ++p.sequence,
      s = { ...scope },
      options = {
        limit: 50,
        cursor: more ? p.nextCursor : null,
        search: p.search,
      };
    const principal = selectedPrincipal ? { ...selectedPrincipal } : null,
      resource = selectedResource ? { ...selectedResource } : null,
      group = selectedGroup ? { ...selectedGroup } : null;
    let result;
    if (!s.teamID) return;
    if (key === "resources" && p.kind) options.kind = p.kind;
    if (key === "vaults") result = await client.listVaults(s.teamID, options);
    else if (key === "members")
      result = await client.listMembers(s.teamID, options);
    else if (key === "groups" && wholeDriver?.enabled) result = wholeDriver.groups();
    else if (key === "resources" && wholeDriver?.enabled) result = wholeDriver.resources(s);
    else if (key === "grants" && wholeDriver?.enabled) result = wholeDriver.grants(s);
    else if (key === "groupMembers" && group && wholeDriver?.enabled) result = wholeDriver.groupMembers(group.id);
    else if (key === "groups")
      result = await client.listGroups(s.teamID, options);
    else if (key === "resources")
      result = await client.listResources(s, options);
    else if (key === "grants") result = await client.listGrants(s, options);
    else if (key === "groupMembers" && group)
      result = await client.listGroupMembers(s.teamID, group.id, options);
    else if (key === "principalResources" && principal)
      result = await (wholeDriver?.enabled?wholeDriver:client).resourcesByPrincipal(
        s,
        principal.kind,
        principal.id,
        options,
      );
    else if (key === "who" && resource)
      result = await (wholeDriver?.enabled?wholeDriver:client).whoHas(s, resource.id, options);
    else if (key === "devices" && principal?.kind === "USER")
      result = await (wholeDriver?.enabled?wholeDriver:client).listDevices(s, principal.id, options);
    if (active(g) && seq === p.sequence && result) {
      p.rows = result.rows;
      p.nextCursor = result.nextCursor;
      error = null;
      render();
    }
  }
  async function refresh() {
    const g = ++generation;
    clearDraft();
    loading = true;
    error = null;
    status = "";
    capability = null;
    wholeDriver = null;
    resetPages();
    details = null;
    editSequence++;
    selectedGroup = null;
    selectedResource = null;
    selectedPrincipal = null;
    deviceResult = null;
    recipients.clear();
    targets.clear();
    render();
    try {
      if (!scope.teamID) return;
      const recoveryDriver=typeof publicationDriver==='function'?await publicationDriver({...scope}):null;
      if(!active(g))return;
      if(recoveryDriver?.pendingOperationID){capability=await recoveryDriver.getContext({...scope});if(active(g))wholeDriver=recoveryDriver;return;}
      await loadPage("vaults");
      if (!active(g) || !scope.vaultID) return;
      const result = await client.getContext({ ...scope });
      if (!active(g)) return;
      capability = result;
      if(result.formatState === 'V2_ACTIVE' && typeof publicationDriver === 'function') {
        const driver=await publicationDriver({...scope});if(!active(g))return;
        if(driver){const enabled=await driver.getContext({...scope});if(!active(g))return;wholeDriver=driver;capability=enabled;}
      }
      await Promise.all([
        loadPage("members"),
        loadPage("groups"),
        ...(result.formatState === "V2_PREPARING" || wholeDriver?.enabled
          ? [loadPage("resources"), loadPage("grants")]
          : []),
      ]);
    } catch (e) {
      if (active(g)) error = e;
      throw e;
    } finally {
      if (active(g)) {
        loading = false;
        render();
      }
    }
  }
  function setContext(value) {
    generation++;
    scope = { ...value };
    capability = null;
    wholeDriver = null;
    loading = false;
    error = null;
    status = "";
    clearDraft();
    resetPages();
    groupNameDraft = "";
    recipients.clear();
    targets.clear();
    details = null;
    editSequence++;
    selectedGroup = null;
    selectedResource = null;
    selectedPrincipal = null;
    selectedDevice = null;
    deviceResult = null;
    render();
  }
  async function preview() {
    gate();
    const g = generation,
      dg = draftGeneration,
      seq = ++previewSequence,
      request = structuredClone(draft);
    impact = null;
    error = null;
    render();
    const result = wholeDriver?.enabled ? await wholeDriver.preview({...scope},request) : await client.preview({ ...scope }, request);
    if (active(g) && dg === draftGeneration && seq === previewSequence) {
      if(result.wholePublication) {
        if(result.complete !== true || result.nextCursor !== null || result.rows?.length !== result.binding?.rowCount)throw Error('access_preview_incomplete');
      } else validateImpact(result);
      impact = {
        ...result,
        request: result.wholePublication ? result.request : request,
        idempotencyKey:
          globalThis.crypto?.randomUUID?.() ??
          `access-${Date.now()}-${Math.random()}`,
        complete: result.nextCursor === null,
      };
      focusPreview = true;
      render();
    }
    return result;
  }
  async function previewMore() {
    gate();
    if (!impact?.nextCursor) return;
    const prior = impact,
      g = generation,
      dg = draftGeneration;
    const result = await client.preview(
      { ...scope },
      prior.request,
      prior.nextCursor,
    );
    if (!active(g) || dg !== draftGeneration || impact !== prior) return;
    if (result.snapshotID !== prior.snapshotID) {
      impact = null;
      render();
      throw new Error("access_preview_conflict");
    }
    for (const key of ["pairs", "widened", "lost", "affectedGrants"])
      if (prior.counts?.[key] !== result.counts?.[key]) {
        impact = null;
        render();
        throw new Error("access_preview_incomplete");
      }
    const combined = {
      ...prior,
      token: result.token,
      details: [...prior.details, ...result.details],
      affectedGrants: [
        ...(prior.affectedGrants ?? []),
        ...(result.affectedGrants ?? []),
      ],
      nextCursor: result.nextCursor,
      complete: result.nextCursor === null,
    };
    try {
      validateImpact(combined, prior.counts);
    } catch (e) {
      impact = null;
      render();
      throw e;
    }
    impact = combined;
    render();
  }
  function validateImpact(value, expectedCounts = value.counts) {
    const counts = value.counts ?? {};
    for (const key of ["pairs", "widened", "lost", "affectedGrants"])
      if (Number.isInteger(expectedCounts[key]) && counts[key] !== expectedCounts[key])
        throw new Error("access_preview_incomplete");
    const pairs = value.details.map((d) => `${d.vaultID}/${d.resourceID}/${d.subjectUserID}`);
    const grants = (value.affectedGrants ?? []).map((g) => g.grantID);
    if (new Set(pairs).size !== pairs.length || new Set(grants).size !== grants.length)
      throw new Error("access_preview_incomplete");
    if ((Number.isInteger(counts.pairs) && pairs.length > counts.pairs) ||
        (Number.isInteger(counts.affectedGrants) && grants.length > counts.affectedGrants) ||
        (value.nextCursor === null &&
          ((Number.isInteger(counts.pairs) && pairs.length !== counts.pairs) ||
           (Number.isInteger(counts.affectedGrants) && grants.length !== counts.affectedGrants))))
      throw new Error("access_preview_incomplete");
  }
  async function confirm() {
    if (committing) return committing;
    gate();
    if (!impact?.complete) throw new Error("access_preview_incomplete");
    const g = generation,
      dg = draftGeneration,
      approved = impact,
      s = { ...scope };
    committing = (async () => {
      try {
        const result = approved.wholePublication ? await wholeDriver.commit(s,approved) : await client.commit(
          s,
          approved.request,
          approved.token,
          approved.idempotencyKey,
        );
        if (active(g) && dg === draftGeneration) {
          clearDraft();
          status = "committed";
          try {
            await onCommitted(result, { ...s, request: approved.request });
          } catch (callbackError) {
            error = callbackError;
          }
          if (active(g)) {
            try {
              await refresh();
            } catch {
              /* Read failure is shown separately from the successful commit. */
            }
            status = "committed";
          }
        }
        return result;
      } catch (e) {
        if (active(g) && dg === draftGeneration) {
          impact =
            approved.wholePublication || e instanceof TypeError || e.message === "network_unavailable"
              ? approved
              : null;
          error = e;
          render();
        }
        throw e;
      } finally {
        committing = null;
        if (!destroyed) render();
      }
    })();
    render();
    return committing;
  }
  function buildGrant() {
    if (!recipients.size) throw new Error("invalid_access_request");
    const targetRows =
      targetScope === "VAULT"
        ? [{ id: scope.vaultID, kind: "VAULT" }]
        : [...targets.values()];
    if (!targetRows.length) throw new Error("invalid_access_request");
    const changes = [];
    for (const target of targetRows) {
      if (targetScope === "FOLDER" && target.policyKind !== "FOLDER")
        throw new Error("invalid_access_request");
      const kind = targetScope === "VAULT" ? "VAULT" : target.policyKind;
      validateMask(kind, permissionMask);
      for (const recipient of recipients.values())
        changes.push({
          type: "GRANT_CREATE",
          principalKind: recipient.kind,
          principalID: recipient.id,
          targetKind: targetScope,
          targetID: target.id,
          permissionMask,
        });
    }
    setDraft({ changes });
  }
  function recipientToggle(row, kind, checked) {
    const id = kind === "USER" ? row.userID : row.id;
    const key = `${kind}:${id}`;
    if (checked) {
      if (recipients.size >= 20) throw new Error("access_batch_too_large");
      recipients.set(key, {
        id,
        kind,
        name: kind === "USER" ? row.displayName || row.username : row.name,
      });
    } else recipients.delete(key);
    clearDraft();
    render();
  }
  function targetToggle(row, checked) {
    if (checked) {
      if (targets.size >= 50) throw new Error("access_batch_too_large");
      targets.set(row.id, row);
      permissionKind = row.policyKind;
      permissionMask = 1;
    } else targets.delete(row.id);
    clearDraft();
    render();
  }
  function pathList(policy) {
    const list = node("ul", null, { class: "access-paths" });
    for (const path of policy?.paths ?? []) {
      const text = `${t(path.principalKind)} · ${path.principalID} → ${t(path.grantTargetKind)} · ${path.grantTargetID} · ${t(path.sourceType === "DIRECT" ? "direct" : "inherited")} · ${path.permissions.map(t).join(", ")}`;
      list.append(node("li", text));
    }
    return list;
  }
  function showPolicy(parent, value) {
    const p = value?.policyEffective ?? value;
    parent.append(
      node("p", `${t("policy")}: ${t(p?.policyAllowed ? "allowed" : "denied")}`),
      pathList(p),
    );
    if (value?.deviceUsability) {
      const summary = effectiveSummary(value);
      const device = value.deviceUsability;
      parent.append(
        node("p", `${t("key")}: ${t(device.cryptoAvailable)}`),
        node("p", `${t("usability")}: ${t(summary.usable === "YES" ? "yes" : summary.usable === "NO" ? "no" : "unknown")}`),
      );
      for (const [permission, state] of Object.entries(device.cryptoAvailableByPermission ?? {}))
        parent.append(node("p", `${t("key")} · ${t(permission)}: ${t(state)}`));
      for (const reason of summary.blockedReasons)
        parent.append(node("p", accessReasonCopy(reason, locale())));
      for (const [permission, state] of Object.entries(
        value.deviceUsability.effectiveUsableByPermission ?? {},
      ))
        parent.append(
          node(
            "p",
            `${t("usability")} · ${t(permission)}: ${t(state === "YES" ? "yes" : state === "NO" ? "no" : "unknown")}`,
          ),
        );
    } else parent.append(node("p", `${t("key")}: ${t("notChecked")}`), node("p", `${t("usability")}: ${t("notChecked")}`));
  }
  function paging(parent, key) {
    const p = pages[key];
    if (p.rows.length === 0) parent.append(node("p", t("empty")));
    if (p.nextCursor)
      parent.append(button("more", () => loadPage(key, true), loading));
  }
  function listPanel(key) {
    const panel = node("section", null, {
      class: "access-directory",
      "aria-label": t(key),
    });
    panel.append(node("h3", t(key)));
    if (["members", "groups", "resources"].includes(key)) {
      const search = node("input", null, {
        type: "search",
        value: pages[key].search,
        "aria-label": t(key === "resources" ? "pageSearch" : "search"),
        maxlength: 120,
      });
      search.addEventListener("change", () => {
        pages[key].search = search.value;
        if (key === "resources") render();
        else void run(() => loadPage(key));
      });
      panel.append(search);
    }
    if (key === "resources") {
      panel.append(
        select(
          "resourceKind",
          [
            ["", t("allKinds")],
            ...["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].map(
              (kind) => [kind, t(kind)],
            ),
          ],
          pages.resources.kind ?? "",
          async (kind) => {
            pages.resources.kind = kind;
            await loadPage("resources");
          },
        ),
      );
    }
    const rows =
      key === "resources" && pages[key].search
        ? pages[key].rows.filter((row) =>
            label(row).toLowerCase().includes(pages[key].search.toLowerCase()),
          )
        : pages[key].rows;
    const list = node("ul", null, { class: "access-rows" });
    for (const row of rows) {
      const li = node("li");
      if (key === "members") {
        li.append(
          check(
            row.displayName || row.username,
            recipients.has(`USER:${row.userID}`),
            (v) => recipientToggle(row, "USER", v),
          ),
          button("resources", async () => {
            selectedPrincipal = { kind: "USER", id: row.userID };
            selectedDevice = null;
            deviceResult = null;
            pages.devices.rows = [];
            pages.principalResources.rows = [];
            render();
            await Promise.all([
              loadPage("principalResources"),
              loadPage("devices"),
            ]);
          }),
        );
      }
      if (key === "groups") {
        li.append(
          check(row.name, recipients.has(`GROUP:${row.id}`), (v) =>
            recipientToggle(row, "GROUP", v),
          ),
          button("groupMembers", async () => {
            selectedGroup = row;
            pages.groupMembers.rows = [];
            pages.groupMembers.sequence++;
            render();
            await loadPage("groupMembers");
          }),
          button("resources", async () => {
            selectedPrincipal = { kind: "GROUP", id: row.id };
            deviceResult = null;
            pages.devices.rows = [];
            pages.principalResources.rows = [];
            render();
            await loadPage("principalResources");
          }),
          button(
            "rename",
            () => {
              selectedGroup = row;
              editSequence++;
              details = {
                type: "rename",
                groupID: row.id,
                expectedVersion: row.version,
                groupName: row.name,
                name: row.name,
              };
              render();
            },
            !groupAvailable(),
          ),
          button(
            "delete",
            () =>
              setDraft({
                type: "GROUP_DELETE",
                groupID: row.id,
                expectedVersion: row.version,
              }),
            !groupAvailable(),
          ),
        );
      }
      if (key === "resources") {
        li.append(
          check(label(row), targets.has(row.id), (v) => targetToggle(row, v)),
          button("who", async () => {
            selectedResource = row;
            pages.who.rows = [];
            pages.who.sequence++;
            render();
            await loadPage("who");
          }),
        );
      }
      list.append(li);
    }
    panel.append(list);
    paging(panel, key);
    return panel;
  }
  function renderComposer(parent) {
    const box = node("section", null, { class: "access-composer" });
    box.append(node("h3", t("recipient")));
    const chips = node("div", null, { class: "access-chips" });
    for (const [key, r] of recipients) {
      const b = node("button", `${r.name || r.id} ×`, {
        type: "button",
        "aria-label": `${t("cancel")}: ${r.name || r.id}`,
      });
      b.addEventListener("click", () => {
        recipients.delete(key);
        clearDraft();
        render();
      });
      chips.append(b);
    }
    box.append(
      chips,
      node("p", `${t("selected")}: ${targets.size}`),
      select(
        "scope",
        [
          ["RESOURCE", t("resourceScope")],
          ["FOLDER", t("folderScope")],
          ["VAULT", t("vaultScope")],
        ],
        targetScope,
        (v) => {
          targetScope = v;
          permissionKind =
            v === "FOLDER"
              ? "FOLDER"
              : v === "VAULT"
                ? "VAULT"
                : (targets.values().next().value?.policyKind ?? "HOST");
          permissionMask = 1;
          clearDraft();
          render();
        },
      ),
    );
    const presets = node("div", null, { class: "access-presets" });
    for (const preset of ["view", "edit", "manage"]) {
      let mask = null;
      try {
        mask = presetMask(permissionKind, preset);
      } catch {}
      presets.append(
        button(
          preset,
          () => {
            permissionMask = mask;
            clearDraft();
            render();
          },
          mask === null,
        ),
      );
    }
    box.append(presets, node("p", t("custom")));
    for (const p of permissionsFor(permissionKind))
      box.append(
        check(t(p.name), !!(permissionMask & p.bit), (checked) => {
          let mask = checked ? permissionMask | p.bit : permissionMask & ~p.bit;
          if (permissionKind === "CREDENTIAL") {
            if (p.bit === 4 && checked) mask |= 2;
            if (p.bit === 2 && !checked) mask &= ~4;
          }
          permissionMask = mask;
          clearDraft();
          render();
        }),
      );
    box.append(
      node(
        "p",
        t(
          targetScope === "FOLDER"
            ? "folderConsequence"
            : targetScope === "VAULT"
              ? "vaultConsequence"
              : "limits",
        ),
      ),
      button("grant", buildGrant, !policyAvailable()),
    );
    parent.append(box);
  }
  function renderDetails(parent) {
    if(details?.type === 'move' && wholeDriver?.enabled) {
      const section=node('section',null,{class:'access-detail'});
      section.append(node('h3',t('move')),select('destination',[['',t('vaultScope')],...pages.resources.rows.filter(r=>r.policyKind==='FOLDER'&&r.id!==details.resourceID).map(r=>[r.id,label(r)])],moveParentFolderID??'',value=>{moveParentFolderID=value||null;impact=null;render();}),
        button('move',()=>setDraft({changes:[{type:'RESOURCE_MOVE',resourceID:details.resourceID,newParentFolderID:moveParentFolderID,expectedResourceVersion:wholeDriver.getResource(scope,details.resourceID).resourceVersion}]}),!!committing));
      parent.append(section);
    }
    if (selectedGroup) {
      const section = node("section", null, { class: "access-detail" });
      section.append(node("h3", `${t("groupMembers")}: ${selectedGroup.name}`));
      for (const edge of pages.groupMembers.rows)
        section.append(
          node("p", edge.userID),
          button(
            "removeMember",
            () =>
              setDraft({
                type: "GROUP_MEMBER_REMOVE",
                groupID: selectedGroup.id,
                edgeID: edge.id,
                expectedVersion: edge.version,
              }),
            !groupAvailable(),
          ),
        );
      paging(section, "groupMembers");
      const options = [
        ["", t("members")],
        ...pages.members.rows.map((m) => [m.id, m.displayName || m.username]),
      ];
      section.append(
        select("addMember", options, "", (membershipID) => {
          if (membershipID)
            setDraft({
              type: "GROUP_MEMBER_ADD",
              groupID: selectedGroup.id,
              targetMembershipID: membershipID,
            });
        }),
      );
      parent.append(section);
    }
    if (selectedPrincipal) {
      const section = node("section", null, { class: "access-detail" });
      section.append(
        node("h3", `${t(selectedPrincipal.kind)} · ${selectedPrincipal.id}`),
      );
      for (const r of pages.principalResources.rows) {
        const item = node("div");
        item.append(node("h4", label(r)));
        showPolicy(item, r);
        if (selectedPrincipal.kind === "USER")
          item.append(
            button("checkDevice", async () => {
              if (!selectedDevice) throw new Error("invalid_access_device");
              const g = generation,
                principalID = selectedPrincipal.id,
                deviceID = selectedDevice;
              const result = await (wholeDriver?.enabled?wholeDriver:client).effective(
                { ...scope },
                r.resourceID,
                principalID,
                deviceID,
              );
              if (
                active(g) &&
                selectedPrincipal?.id === principalID &&
                selectedDevice === deviceID
              ) {
                deviceResult = { resourceID: r.resourceID, result };
                render();
              }
            }),
          );
        section.append(item);
      }
      paging(section, "principalResources");
      if (selectedPrincipal.kind === "USER") {
        section.append(
          select(
            "device",
            [
              ["", t("chooseDevice")],
              ...pages.devices.rows.map((d) => [
                d.id,
                `${d.name} · ${d.platform} · ${d.admitted ? "✓" : "×"}`,
              ]),
            ],
            selectedDevice,
            (v) => {
              selectedDevice = v || null;
              deviceResult = null;
              render();
            },
          ),
        );
        paging(section, "devices");
        if (deviceResult) {
          section.append(
            node("h4", label({ resourceID: deviceResult.resourceID })),
          );
          showPolicy(section, deviceResult.result);
        }
      }
      parent.append(section);
    }
    if (selectedResource) {
      const section = node("section", null, { class: "access-detail" });
      section.append(node("h3", `${t("who")}: ${label(selectedResource)}`));
      for (const row of pages.who.rows) {
        section.append(node("h4", row.userID));
        showPolicy(section, row);
      }
      paging(section, "who");
      parent.append(section);
    }
    if (details?.type === "grant") {
      const form = node("section", null, {
        class: "access-detail access-grant-editor",
        "aria-label": t("change"),
      });
      form.append(
        node("h3", t("change")),
        node("p", `${details.kind} · ${details.targetID}`),
      );
      for (const preset of ["view", "edit", "manage"]) {
        let mask = null;
        try {
          mask = presetMask(details.kind, preset);
        } catch {}
        form.append(
          button(
            preset,
            () => {
              details.permissionMask = mask;
              clearDraft();
              render();
            },
            mask === null,
          ),
        );
      }
      for (const permission of permissionsFor(details.kind))
        form.append(
          check(
            t(permission.name),
            !!(details.permissionMask & permission.bit),
            (checked) => {
              let mask = checked
                ? details.permissionMask | permission.bit
                : details.permissionMask & ~permission.bit;
              if (details.kind === "CREDENTIAL") {
                if (permission.bit === 4 && checked) mask |= 2;
                if (permission.bit === 2 && !checked) mask &= ~4;
              }
              details.permissionMask = mask;
              clearDraft();
              render();
            },
          ),
        );
      form.append(
        button("change", () => {
          validateMask(details.kind, details.permissionMask);
          const request = {
            changes: [
              {
                type: "GRANT_CHANGE",
                grantID: details.grantID,
                expectedVersion: details.expectedVersion,
                permissionMask: details.permissionMask,
              },
            ],
          };
          details = null;
          editSequence++;
          setDraft(request);
        }),
        button("cancel", () => {
          details = null;
          editSequence++;
          render();
        }),
      );
      parent.append(form);
    }
    if (details?.type === "rename") {
      const form = node("section", null, { class: "access-detail" });
      form.append(
        node("h3", `${t("rename")}: ${details.groupName}`),
        node("p", details.groupID),
        input("groupName", details.name, (value) => {
          details.name = value;
          clearDraft();
        }),
        button("rename", () => {
          setDraft({
            type: "GROUP_RENAME",
            groupID: details.groupID,
            expectedVersion: details.expectedVersion,
            name: details.name,
          });
          details = null;
          render();
        }),
        button("cancel", () => {
          details = null;
          render();
        }),
      );
      parent.append(form);
    }
  }
  function renderGrants(parent) {
    if (capability?.formatState !== "V2_PREPARING" && !wholeDriver?.enabled) return;
    const section = node("section", null, { class: "access-detail" });
    section.append(node("h3", t("grants")));
    if (pages.grants.rows.length) section.append(node("p", t("preserved")));
    for (const row of pages.grants.rows) {
      const item = node("div", null, { class: "access-grant" });
      item.append(
        check(
          `${t(row.principal_kind)} · ${row.principal_id} → ${t(row.target_kind)} · ${row.target_id}`,
          grantSelection.has(row.id),
          (checked) => {
            if (checked) {
              if (grantSelection.size >= 50)
                throw new Error("access_batch_too_large");
              grantSelection.set(row.id, row);
            } else grantSelection.delete(row.id);
            impact = null;
            draft = null;
            draftGeneration++;
            render();
          },
        ),
        button(
          "revoke",
          () =>
            setDraft({
              changes: [
                {
                  type: "GRANT_REVOKE",
                  grantID: row.id,
                  expectedVersion: row.version,
                },
              ],
            }),
          !policyAvailable(),
        ),
        button(
          "change",
          async () => {
            const g = generation,
              sequence = ++editSequence,
              requestScope = { ...scope };
            let kind;
            if (row.target_kind === "VAULT") {
              if (row.target_id !== requestScope.vaultID)
                throw new Error("access_scope_mismatch");
              kind = "VAULT";
            } else {
              const target = wholeDriver?.enabled ? wholeDriver.getResource(requestScope,row.target_id) : await client.getResource(
                requestScope,
                row.target_id,
              );
              if (
                (row.target_kind === "FOLDER" &&
                  target.policyKind !== "FOLDER") ||
                (row.target_kind === "RESOURCE" &&
                  target.policyKind === "FOLDER")
              )
                throw new Error("access_scope_mismatch");
              kind = target.policyKind;
            }
            if (!active(g) || sequence !== editSequence) return;
            validateMask(kind, row.permission_mask);
            clearDraft();
            details = {
              type: "grant",
              grantID: row.id,
              expectedVersion: row.version,
              kind,
              targetKind: row.target_kind,
              targetID: row.target_id,
              permissionMask: row.permission_mask,
            };
            render();
          },
          !policyAvailable(),
        ),
      );
      section.append(item);
    }
    paging(section, "grants");
    section.append(
      button(
        "bulkRevoke",
        () =>
          setDraft({
            changes: [...grantSelection.values()].map((g) => ({
              type: "GRANT_REVOKE",
              grantID: g.id,
              expectedVersion: g.version,
            })),
          }),
        !policyAvailable() || !grantSelection.size,
      ),
    );
    parent.append(section);
  }
  function renderImpact(parent) {
    if (!draft) return;
    const section = node("section", null, { class: "access-preview" });
    section.append(
      node("h3", t("preview")),
      node(
        "p",
        draft.changes
          ? `${t("selected")}: ${draft.changes.length}`
          : t(
              {
                GROUP_CREATE: "createGroup",
                GROUP_RENAME: "rename",
                GROUP_DELETE: "delete",
                GROUP_MEMBER_ADD: "addMember",
                GROUP_MEMBER_REMOVE: "removeMember",
              }[draft.type],
            ),
      ),
      button("preview", preview, !!committing),
    );
    for (const operation of draft.changes ?? [draft]) {
      const action = {
        GRANT_CREATE: "grant",
        GRANT_CHANGE: "change",
        GRANT_REVOKE: "revoke",
        GROUP_CREATE: "createGroup",
        GROUP_RENAME: "rename",
        GROUP_DELETE: "delete",
        GROUP_MEMBER_ADD: "addMember",
        GROUP_MEMBER_REMOVE: "removeMember",
        RESOURCE_MOVE: "move",
        RESOURCE_EDIT: "edit",
      }[operation.type];
      section.append(
        node(
          "p",
          [
            t(action),
            operation.name,
            operation.principalKind && t(operation.principalKind),
            operation.principalID,
            operation.targetKind && t(operation.targetKind),
            operation.targetID,
            operation.groupID,
            operation.grantID,
            operation.edgeID,
            operation.targetMembershipID,
            operation.resourceID,
          ]
            .filter((value) => value !== null && value !== undefined)
            .join(" · "),
        ),
      );
    }
    if (impact) {
      section.setAttribute("role", "dialog");
      section.setAttribute("aria-modal", "false");
      section.setAttribute("aria-label", t("preview"));
      section.tabIndex = -1;
      if(impact.wholePublication) {
        section.append(node('p',`${t('wholeUpdate')} · ${t('vaults')}: ${impact.binding.counts.vaults} · ${t('resources')}: ${impact.binding.counts.resources}`));
        for(const row of impact.details){const kind=row.kind??pages.resources.rows.find(r=>r.id===row.resourceID)?.policyKind;
          const permissionNames=mask=>mask===0?t('denied'):kind?permissionsFor(kind).filter(p=>(mask&p.bit)===p.bit).map(p=>t(p.name)).join(', '):t('allowed');
          section.append(node('p',`${row.accountID} · ${accessLabel({teamID:scope.teamID,vaultID:row.vaultID,resourceID:row.resourceID,policyKind:'RESOURCE'},resolveLabel,t)} · ${t('before')}: ${permissionNames(row.beforeMask)} → ${t('after')}: ${permissionNames(row.afterMask)}`));}
        section.append(button('confirm',confirm,!impact.complete||!!committing));
      } else {
      section.append(
        node(
          "p",
          `${t("gainedPairs")}: ${impact.counts.widened ?? 0} · ${t("lostPairs")}: ${impact.counts.lost ?? 0} · ${t("affected")}: ${impact.counts.affectedGrants ?? 0}`,
        ),
      );
      for (const detail of impact.details) {
        const item = node("article");
        const kind = pages.resources.rows.find((r) => r.id === detail.resourceID)?.policyKind;
        item.append(
          node(
            "h4",
            `${detail.subjectUserID} · ${accessLabel({ teamID: scope.teamID, vaultID: detail.vaultID, resourceID: detail.resourceID, policyKind: "RESOURCE" }, resolveLabel, t)}`,
          ),
          node("p", accessConsequence(detail, locale(), kind)),
          node("h5", t("before")),
        );
        showPolicy(item, detail.before);
        item.append(node("h5", t("after")));
        showPolicy(item, detail.after);
        section.append(item);
      }
      for (const grant of impact.affectedGrants ?? [])
        section.append(
          node(
            "p",
            `${grant.vaultID} · ${t(grant.targetKind)} · ${grant.targetID}`,
          ),
        );
      if (impact.nextCursor)
        section.append(
          node("p", t("previewIncomplete")),
          button("previewMore", previewMore, !!committing),
        );
      section.append(
        button("confirm", confirm, !impact.complete || !!committing),
      );
      }
    }
    section.append(
      button(
        "cancel",
        () => {
          restoreDraftFocus = true;
          clearDraft();
          render();
        },
        !!committing,
      ),
    );
    parent.append(section);
  }
  function render() {
    if (destroyed) return;
    const focused = documentValue.activeElement?.dataset?.accessFocus;
    const previewFocused = documentValue.activeElement?.closest?.(".access-preview");
    const previewAction = previewFocused && documentValue.activeElement?.dataset?.accessAction;
    focusIndex = 0;
    const fragment = node("div", null, { class: "access-manager" });
    fragment.append(
      node("h2", t("title")),
      node("p", t("opaque")),
      node("p", t("limits")),
    );
    if (!scope.teamID) {
      fragment.append(node("p", t("chooseTeam")));
      root.replaceChildren(fragment);
      return;
    }
    fragment.append(
      select(
        "vault",
        [
          ["", t("chooseVault")],
          ...(scope.vaultID &&
          !pages.vaults.rows.some((v) => v.id === scope.vaultID)
            ? [[scope.vaultID, scope.vaultID]]
            : []),
          ...pages.vaults.rows.map((v) => [
            v.id,
            `${v.name} · ${t(["V1_ACTIVE", "V2_PREPARING", "V2_READY", "V2_ACTIVE"].includes(v.formatState) ? v.formatState : "stateUnknown")}`,
          ]),
        ],
        scope.vaultID ?? "",
        async (vaultID) => {
          setContext({ ...scope, vaultID: vaultID || null });
          await refresh();
        },
      ),
      button("refresh", refresh, loading),
    );
    paging(fragment, "vaults");
    if (loading) fragment.append(node("p", t("loading"), { role: "status" }));
    if (error)
      fragment.append(
        node("p", accessErrorCopy(error, locale()), {
          role: "alert",
          "aria-live": "assertive",
        }),
        button("retry", refresh),
      );
    if (status)
      fragment.append(
        node("p", t(status), { role: "status", "aria-live": "polite" }),
      );
    if (capability) {
      fragment.append(
        node(
          "p",
          t(
            capability.formatState === "V1_ACTIVE"
              ? "legacy"
              : capability.wholePublication ? 'wholeUpdate' : capability.formatState === "V2_PREPARING"
                ? "preparing"
                : "publication",
          ),
          { class: "access-state" },
        ),
      );
      if (!groupAvailable() && policyAvailable())
        fragment.append(node("p", t("groupPublication")));
      if (capability.blockers.includes("team_permission_denied"))
        fragment.append(node("p", t("permissionDenied")));
      if(wholeDriver?.pendingOperationID) {
        const recover=async discard=>{if(committing)return committing;const g=generation,s={...scope};
          committing=(async()=>{try{const result=discard?await wholeDriver.discardPrepared(s):await wholeDriver.resumePrepared(s);if(!active(g))return;if(!discard)await onCommitted(result,s);if(active(g))await refresh();}finally{committing=null;if(!destroyed)render();}})();render();return committing;};
        fragment.append(node('p',t('resumeUpdate')),button('retry',()=>recover(false),!!committing||(!wholeDriver.canResumePending&&!wholeDriver.pendingReceipt)));
        if(!wholeDriver.pendingReceipt)fragment.append(button('discardUpdate',()=>recover(true),!!committing));
      }
      const tabs = node("nav", null, { "aria-label": t("title") });
      for (const name of ["members", "groups", "resources"]) {
        const b = button(name, () => {
          tab = name;
          render();
        });
        b.setAttribute("aria-current", tab === name ? "page" : "false");
        tabs.append(b);
      }
      fragment.append(tabs);
      if (capability.formatState === "V2_PREPARING" || wholeDriver?.enabled || tab !== "resources")
        fragment.append(listPanel(tab));
      if (tab === "groups") {
        const form = node("section", null, { class: "access-composer" });

        const field = node("input", null, {
          type: "text",
          maxlength: 120,
          value: groupNameDraft,
          "aria-label": t("groupName"),
        });
        field.addEventListener("input", () => {
          groupNameDraft = field.value;
          impact = null;
          draft = null;
          draftGeneration++;
        });
        form.append(
          field,
          button(
            "createGroup",
            () => setDraft({ type: "GROUP_CREATE", name: groupNameDraft }),
            !groupAvailable(),
          ),
        );
        fragment.append(form);
      }
      if (capability.formatState === "V2_PREPARING" || wholeDriver?.enabled) {
        renderComposer(fragment);
        renderGrants(fragment);
      }
      renderDetails(fragment);
      renderImpact(fragment);
    }
    root.replaceChildren(fragment);
    if (committing)
      for (const control of root.querySelectorAll?.("button, input, select") ??
        [])
        control.disabled = true;
    root.setAttribute("aria-label", t("title"));
    if (focusPreview) {
      root.querySelector?.(".access-preview")?.focus();
      focusPreview = false;
    } else if (restoreDraftFocus) {
      const control = draftFocus !== null && root.querySelector?.(`[data-access-focus="${draftFocus}"]`);
      if (control && !control.disabled) control.focus();
      else root.focus?.();
      restoreDraftFocus = false;
    } else if (previewFocused) {
      const preview = root.querySelector?.(".access-preview");
      const control = previewAction && preview?.querySelector?.(`[data-access-action="${previewAction}"]`);
      if (control && !control.disabled) control.focus();
      else preview?.focus();
    } else if (focused !== undefined)
      root.querySelector?.(`[data-access-focus="${focused}"]`)?.focus();
  }
  function escape(event) {
    if (event.key === "Escape" && !committing) {
      event.preventDefault?.();
      const hadDraft = !!draft;
      restoreDraftFocus = hadDraft;
      clearDraft();
      details = null;
      editSequence++;
      render();
      if (!hadDraft) root.focus?.();
    }
  }
  function localeChanged() {
    render();
  }
  root.addEventListener("keydown", escape);
  documentValue.addEventListener(
    "selective-remote:locale-changed",
    localeChanged,
  );
  render();
  return {
    setContext,
    async openResource(reference, action = "who") {
      if (!reference?.teamID || !reference.vaultID || !reference.resourceID || !["HOST","CREDENTIAL","SNIPPET","FORWARDING","FOLDER"].includes(reference.kind)) throw new Error("invalid_access_resource");
      setContext({teamID:reference.teamID,vaultID:reference.vaultID,role:reference.role,deviceID:reference.deviceID});
      await refresh();
      if (scope.teamID !== reference.teamID || scope.vaultID !== reference.vaultID) return;
      selectedResource={id:reference.resourceID,policyKind:wholeDriver?.enabled ? reference.kind : reference.kind === "FOLDER" ? "FOLDER" : reference.kind === "CREDENTIAL" ? "SECRET" : "GENERAL"};
      if(action === 'share' && wholeDriver?.enabled){tab='resources';targets.set(reference.resourceID,wholeDriver.getResource(scope,reference.resourceID));permissionKind=reference.kind;permissionMask=presetMask(reference.kind,'view');targetScope=reference.kind==='FOLDER'?'FOLDER':'RESOURCE';}
      else if(action === 'share') status="publication";
      if(action === 'move' && wholeDriver?.enabled){tab='resources';moveParentFolderID=reference.parentFolderID??null;details={type:'move',resourceID:reference.resourceID};}
      render();
      if(action === 'who' || !wholeDriver?.enabled)await loadPage("who");
    },
    async readPublishedRecord(reference){setContext({...reference});await refresh();if(!wholeDriver?.enabled)throw Error('publication_unavailable');return wholeDriver.readRecord(reference);},
    async previewPublishedEdit(reference,record){setContext({...reference});await refresh();if(!wholeDriver?.enabled)throw Error('publication_unavailable');setDraft({type:'RESOURCE_EDIT',resourceID:reference.resourceID,record});return preview();},
    refresh,
    destroy() {
      destroyed = true;
      generation++;
      root.removeEventListener("keydown", escape);
      documentValue.removeEventListener(
        "selective-remote:locale-changed",
        localeChanged,
      );
      root.replaceChildren();
    },
    setDraft,
    preview,
    previewMore,
    confirm,
    state() {
      return structuredClone({
        context: scope,
        capability,
        tab,
        loading,
        error: error ? { code: error.code ?? error.message } : null,
        draft,
        preview: impact,
        pages,
      });
    },
    loadPage,
  };
}

// Real Chromium WebCrypto, IndexedDB and actual app workspace. Only HTTP responses are synthetic.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";
const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
const root = resolve("cloud/public");
const server = createServer(async (req, res) => {
  try {
    const path = new URL(req.url, "http://localhost").pathname;
    const name = path === "/" ? "index.html" : path.slice(1);
    if (!/^[a-z0-9-]+\.(js|css|html)$/.test(name)) throw Error();
    let content = await readFile(root + "/" + name, "utf8");
    if (name === "index.html")
      content = content.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "");
    res.setHeader(
      "Content-Type",
      name.endsWith(".js")
        ? "application/javascript"
        : name.endsWith(".css")
          ? "text/css"
          : "text/html",
    );
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
let browser;
try {
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROMIUM_PATH ?? chromium.executablePath(),
  });
  const page = await browser.newPage();
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("http://127.0.0.1:" + server.address().port);
  const result = await page.evaluate(async () => {
    const { generateTeamDeviceIdentity } = await import(
      "/team-vault-crypto.js"
    );
    const {
      createTrustRoot,
      issueDeviceCertificate,
      signDeviceDirectory,
      deviceDirectoryDigest,
    } = await import("/device-trust-v1.js");
    const { prepareLegacyMigration } = await import("/vault-v2-migration.js");
    const {
      createVaultPublicationClient,
      createIndexedDBPublicationRepository,
      renderPublishedVault,
      requestPublisherVerification,
    } = await import("/vault-publication-client.js");
    const { initializeTeamWorkspace, completeBrowserSessionLogout } =
      await import("/app.js");
    const uuid = () => crypto.randomUUID(),
      endpoint = "https://staging.example.test",
      accountID = uuid(),
      deviceID = uuid(),
      identity = { ...(await generateTeamDeviceIdentity()), deviceID },
      scope = {
        teamID: uuid(),
        vaultID: uuid(),
        attemptID: uuid(),
        sourceRevision: 1,
        sourceHash: "a".repeat(64),
        snapshotHash: "b".repeat(64),
        policyVersion: 1,
      };
    const root = await createTrustRoot({ endpoint, accountID }),
      certificate = await issueDeviceCertificate({
        root,
        accountID,
        deviceID,
        publicKey: identity.publicKey,
        keyVersion: 1,
        issuedAt: 1800000000,
        serial: uuid(),
      }),
      checkpoint = await signDeviceDirectory({
        root,
        accountID,
        version: 1,
        certificates: [certificate],
      }),
      pin = {
        endpoint,
        accountID,
        rootFingerprint: root.fingerprint,
        highWater: 1,
        checkpointDigest: await deviceDirectoryDigest(checkpoint),
      },
      ownTrustRepository = {
        loadPin: async () => pin,
        advancePin: async () => {},
      };
    const recipient = {
      accountID,
      deviceID,
      membershipID: uuid(),
      membershipEpoch: 1,
      deviceKeyVersion: 1,
      publicKey: identity.publicKey,
      rootPublicKey: root.publicKey,
      certificate,
      checkpoint,
    };
    const record = (type, data) => ({
      id: uuid(),
      type,
      version: { [deviceID]: 1 },
      modifiedAt: "2026-10-01T08:00:00.000Z",
      data,
    });
    const out = await prepareLegacyMigration({
      document: {
        schemaVersion: 1,
        records: [
          record("host", {
            title: "Actual browser host",
            address: "private.example",
            folder: "Production",
          }),
          record("credential", {
            title: "Metadata only",
            username: "alice",
            secret: "BROWSER_PRIVATE_SECRET",
          }),
          { ...record("snippet", {
            title: "Read the published snippet", body: "printf '<img src=x onerror=alert(1)>'\necho preserved", folder: "",
          }), id: "legacy-snippet-id" },
          record("forwarding", {
            title: "Read the published forwarding", destination: "internal.example:443", configuration: '{"mode":"local","sourcePort":8443,"destination":"internal.example:443"}' ,
          }),
        ],
        tombstones: [],
        vectorClock: {},
      },
      scope,
      policy: [],
      recipientTargets: () => [recipient],
      pinnedTrust: ownTrustRepository,
      root,
      identity,
      deviceID,
      endpoint,
      checkpointKey: crypto.getRandomValues(new Uint8Array(32)),
      persistCheckpoint: async () => {},
      readerPublication: {
        publisherAccountID: accountID,
        publisherKeyVersion: 1,
        custodianDeviceIDs: [deviceID],
        custodianTargets: [recipient],
        verifyIdentityReservations: async () => {},
      },
    });
    const p = out.readerProjection,
      row = p.recipients[0],
      headerHash = row.inventory.payload.headerHash,
      subject = {
        accountID,
        deviceID,
        membershipID: recipient.membershipID,
        membershipEpoch: 1,
      },
      requests = [];
    let session = { endpoint, accountID, deviceID, sessionEpoch: "1" },
      network = false,
      denial = null;
    const transport = {
      header: async () => {
        if (denial) throw Error(denial);
        if (network) throw Error("publication_network_unavailable");
        return structuredClone({
          header: p.header,
          headerHash,
          subject,
          inventory: row.inventory,
        });
      },
      publisher: async () => ({
        headerHash,
        generationID: scope.attemptID,
        accountID,
        deviceID,
        keyVersion: 1,
        rootPublicKey: root.publicKey,
        certificate,
        checkpoint,
      }),
      directory: async () => ({
        headerHash,
        generationID: scope.attemptID,
        inventory: row.inventory,
        descriptors: p.descriptors,
        nextCursor: null,
      }),
      part: async (_s, q) => {
        requests.push(q.part);
        const descriptor = p.descriptors.find(
            (d) =>
              d.payload.resourceID === q.resourceID &&
              d.payload.part === q.part,
          ),
          object = out.objects.find(
            (o) => o.resourceID === q.resourceID && o.part === q.part,
          ),
          proof = row.proofs.find(
            (x) => x.resourceID === q.resourceID && x.part === q.part,
          );
        return {
          headerHash,
          generationID: scope.attemptID,
          descriptor,
          envelope: object.envelope,
          entry: proof.entry,
          proof: proof.proof,
        };
      },
    };
    const repository = createIndexedDBPublicationRepository(),
      cs = {
        endpoint,
        accountID,
        deviceID,
        teamID: scope.teamID,
        vaultID: scope.vaultID,
      },
      options = {
        transport,
        identity: () => session,
        scope,
        privateKey: identity.privateKey,
        publicKey: identity.publicKey,
        ownTrustRepository,
        publisherTrustRepository: repository,
        repository,
      };
    const client = createVaultPublicationClient(options),
      view = await client.load();
    if (requests.includes("SECRET")) throw Error("metadata fetched SECRET");
    const container = document.createElement("div");
    document.body.append(container);
    let accessRef;
    renderPublishedVault({
      documentValue: document,
      container,
      client,
      onAccess: (ref) => {
        accessRef = ref;
      },
    });
    container
      .querySelector("article")
      .dispatchEvent(
        new MouseEvent("contextmenu", { bubbles: true, cancelable: true }),
      );
    if (!view.models.some((m) => m.resourceID === accessRef.resourceID))
      throw Error("contextual reference mismatch");
    [...container.querySelectorAll("button")]
      .find((b) => b.textContent === "Показать секрет")
      .click();
    for (
      let n = 0;
      n < 100 &&
      !document.querySelector('dialog[data-publication-dialog="secret"]');
      n++
    )
      await new Promise((r) => setTimeout(r, 10));
    if (
      document.querySelector('dialog[data-publication-dialog="secret"] pre')
        ?.textContent !== "BROWSER_PRIVATE_SECRET"
    )
      throw Error("actual secret reveal failed");
    document
      .querySelector('dialog[data-publication-dialog="secret"] button')
      .click();
    await repository.savePinIfAbsent(endpoint, scope.teamID, pin);
    if (
      (await repository.loadPin(endpoint, scope.teamID, accountID))
        .rootFingerprint !== root.fingerprint
    )
      throw Error("scoped publisher pin persistence failed");
    const db = await new Promise((r) => {
      const q = indexedDB.open("selective-remote-publication-v1");
      q.onsuccess = () => r(q.result);
    });
    const stored = await new Promise((r) => {
      const q = db.transaction("records").objectStore("records").getAll();
      q.onsuccess = () => r(q.result);
    });
    db.close();
    if (stored.some((v) => v instanceof CryptoKey && v.extractable))
      throw Error("extractable cache key");
    if (JSON.stringify(stored).includes(root.fingerprint))
      throw Error("unprotected publisher pin");
    if (
      JSON.stringify(stored).includes("BROWSER_PRIVATE_SECRET") ||
      JSON.stringify(stored).includes("Actual browser host")
    )
      throw Error("plaintext persistence");
    document.documentElement.lang = "en";
    renderPublishedVault({ documentValue: document, container, client });
    if (
      !container.textContent.includes("read only") ||
      !container.textContent.includes("Reveal secret")
    )
      throw Error("English publication UI unavailable");
    document.documentElement.lang = "ru";
    client.lock();
    const restarted = createVaultPublicationClient(options);
    network = true;
    const stale = await restarted.load();
    if (!stale.stale || stale.models.length !== 5)
      throw Error("offline restart cache failed");
    network = false;
    denial = "publication_repair_required";
    await restarted.load().catch(() => {});
    if (
      restarted.view() !== null ||
      (await repository.load(cs)).payload !== null
    )
      throw Error("authoritative cleanup failed");
    // Actual protected high-water must remain authenticated after payload cleanup.
    const db2 = await new Promise((r) => {
      const q = indexedDB.open("selective-remote-publication-v1");
      q.onsuccess = () => r(q.result);
    });
    await new Promise((r) => {
      const tx = db2.transaction("records", "readwrite"),
        store = tx.objectStore("records"),
        q = store.get(
          "cache:" +
            JSON.stringify([
              endpoint,
              accountID,
              deviceID,
              scope.teamID,
              scope.vaultID,
            ]),
        );
      q.onsuccess = () => {
        const data = q.result;
        data.highWater.sequence = 99;
        store.put(
          data,
          "cache:" +
            JSON.stringify([
              endpoint,
              accountID,
              deviceID,
              scope.teamID,
              scope.vaultID,
            ]),
        );
      };
      tx.oncomplete = r;
    });
    db2.close();
    let highWaterTamperDenied = false;
    try {
      await repository.load(cs);
    } catch {
      highWaterTamperDenied = true;
    }
    if (!highWaterTamperDenied)
      throw Error("unprotected high-water after cleanup");
    // Independent-fingerprint dialog requires entered value; a mismatch keeps it open.
    const pending = requestPublisherVerification(document, {
      fingerprint: root.fingerprint,
      accountID,
      deviceID,
      teamID: scope.teamID,
    });
    let dialog = document.querySelector(
      'dialog[data-publication-dialog="publisher"]',
    );
    dialog.querySelector("input").value = "0".repeat(64);
    dialog.querySelector("button").click();
    if (!dialog.open) throw Error("same-page click pinned publisher");
    dialog.querySelector("input").value = root.fingerprint;
    dialog.querySelector("button").click();
    if ((await pending) !== root.fingerprint)
      throw Error("independent input confirmation");
    // Actual app workspace uses the publication coordinator and blocks legacy writes.
    let appWho = null,
      contextOffline = false,
      contextDenial = null,
      snapshotOffline = false;
    const listeners = new Set();
    const appClient = {
      deviceTrustSnapshot: async () => {
        if (snapshotOffline) throw new TypeError("fetch failed");
        return {
          rootPublicKey: root.publicKey,
          checkpoint,
          certificates: [certificate],
        };
      },
      session: () => ({ id: accountID }),
      deviceID: () => deviceID,
      publicationIdentity: () => ({ ...session, endpoint }),
      subscribePublicationIdentity: (cb) => {
        listeners.add(cb);
        return () => listeners.delete(cb);
      },
      publicationTransport: () => transport,
      accessClient: () => ({
        whoHas: async (s, id) => {
          appWho = { scope: s, id };
          return { rows: [], nextCursor: null };
        },
        getContext: async () => {
          if (contextDenial) throw Error(contextDenial);
          if (contextOffline) throw new TypeError("fetch failed");
          return {
            formatState: "V2_ACTIVE",
            policyMutationAvailable: false,
            groupMutationAvailable: false,
            blockers: ["crypto_publication_required"],
          };
        },
        listVaults: async () => ({ rows: [], nextCursor: null }),
        listGroups: async () => ({ rows: [], nextCursor: null }),
        listMembers: async () => ({ rows: [], nextCursor: null }),
        listResources: async () => ({ rows: [], nextCursor: null }),
      }),
      listDevices: async () => [],
      listPendingTeamInvitations: async () => [],
      listTeamInvitationsForCurrentUser: async () => [],
      listTeams: async () => [
        { id: scope.teamID, name: "Browser Team", role: "viewer" },
      ],
      listTeamMembersPage: async () => ({
        members: [],
        nextCursor: null,
        total: 0,
      }),
      listSharedVaults: async () => [
        { id: scope.vaultID, name: "Published Vault", rotationRequired: false },
      ],
      getTeamDeviceAdmissionPolicy: async () => ({
        automaticDeviceAdmission: true,
        editable: false,
      }),
    };
    // Production endpoint identity is global location; use the fixture HTTPS scope through adapter.
    denial = null;
    const appScope = { ...scope, vaultID: uuid() };
    // Avoid the deliberately damaged cache scope: reset only synthetic storage before app activation.
    await new Promise((r, j) => {
      const q = indexedDB.deleteDatabase("selective-remote-publication-v1");
      q.onsuccess = r;
      q.onerror = j;
    });
    let backgroundTick = null;
    const workspace = initializeTeamWorkspace({
      documentValue: document,
      client: appClient,
      deviceTrustRepository: ownTrustRepository,
      setIntervalValue: callback => {backgroundTick = callback;return {unref(){}};},
      clearIntervalValue: () => {backgroundTick = null;},
      backgroundSyncIntervalMilliseconds: 15000,
      workspaceRefreshIntervalMilliseconds: 0,
    });
    await workspace.activate(identity);
    workspace.setView("hosts");
    for (
      let n = 0;
      n < 100 &&
      !document.querySelector("#team-vault-records [data-publication-state]");
      n++
    )
      await new Promise((r) => setTimeout(r, 10));
    const appRecords =
      document.querySelector("#team-vault-records") ??
      document.querySelector("#team-records");
    if (!appRecords?.textContent.includes("Actual browser host"))
      throw Error(
        "actual workspace did not render verified models: " +
          document.querySelector("#team-vault-status")?.textContent,
      );
    if (!document.querySelector("#team-record-create")?.disabled)
      throw Error("published edit enabled");
    async function readPublishedDetail(kind, expected, stale = false) {
      const model = view.models.find(m => m.kind === kind);
      const card = appRecords.querySelector(`[data-resource-id="${model.resourceID}"]`);
      const button = card?.querySelector('[data-publication-action="detail"]');
      if (!button || button.disabled) throw Error("published " + kind + " body has no read surface: " + JSON.stringify({resource:model.resourceID,cards:[...appRecords.querySelectorAll("article")].map(c=>({id:c.dataset.resourceId,title:c.querySelector("h4")?.textContent,actions:[...c.querySelectorAll("button")].map(b=>({action:b.dataset.publicationAction,disabled:b.disabled}))}))}));
      button.click();
      const detail = document.querySelector('dialog[data-publication-dialog="detail"]');
      if (!detail?.open || detail.querySelector("pre")?.textContent !== expected)
        throw Error("published " + kind + " detail lost verified content");
      if (detail.dataset.resourceId !== model.reference.resourceID || detail.dataset.teamId !== scope.teamID ||
          detail.dataset.vaultId !== scope.vaultID || detail.dataset.generationId !== scope.attemptID)
        throw Error("detail inferred original source ID instead of exact physical reference");
      if (!detail.querySelector(`[data-publication-state="${stale ? "stale" : "verified"}"]`))
        throw Error("detail current/stale label is false");
      if (detail.querySelector("img,input,textarea,[data-publication-action=edit],[data-publication-action=run]"))
        throw Error("read-only content constructed HTML or mutation surface");
      detail.querySelector('[data-publication-action="copy"]').click();
      for(let n=0; n<100 && await navigator.clipboard.readText() !== expected; n++)
        await new Promise(r=>setTimeout(r,10));
      if(await navigator.clipboard.readText() !== expected) throw Error("published " + kind + " copy failed");
      detail.querySelector('[data-publication-action="close"]').click();
      return button;
    }
    const snippetBody = "printf '<img src=x onerror=alert(1)>'\necho preserved";
    await readPublishedDetail("SNIPPET", snippetBody);
    await readPublishedDetail("FORWARDING", '{"mode":"local","sourcePort":8443,"destination":"internal.example:443"}' );
    const contextualID = appRecords.querySelector("article").dataset.resourceId;
    appRecords
      .querySelector("article")
      .dispatchEvent(
        new MouseEvent("contextmenu", { bubbles: true, cancelable: true }),
      );
    for (let n = 0; n < 100 && !appWho; n++)
      await new Promise((r) => setTimeout(r, 10));
    if (
      appWho?.id !== contextualID ||
      appWho?.scope.teamID !== scope.teamID ||
      appWho?.scope.vaultID !== scope.vaultID
    )
      throw Error("actual app contextual Access reference failed");
    workspace.setView("hosts");
    document.querySelector("#team-vault-lock").click();
    contextOffline = true;
    network = true;
    document.querySelector("#team-vault-open").click();
    for (
      let n = 0;
      n < 100 && !appRecords.querySelector('[data-publication-state="stale"]');
      n++
    )
      await new Promise((r) => setTimeout(r, 10));
    if (
      !appRecords.textContent.includes("Actual browser host") ||
      !appRecords.querySelector('[data-publication-state="stale"]')
    )
      throw Error(
        "actual workspace cannot reopen protected prior V2 cache offline",
      );
    if ([...appRecords.querySelectorAll("button:not([data-publication-action=detail])")].some((b) => !b.disabled))
      throw Error("stale SECRET/context Access enabled");
    await readPublishedDetail("SNIPPET", snippetBody, true);
    // A separate online format probe with offline trust-snapshot preflight also uses only the prior protected publication.
    contextOffline = false;
    snapshotOffline = true;
    document.querySelector("#team-vault-open").click();
    for (
      let n = 0;
      n < 100 && !appRecords.querySelector('[data-publication-state="stale"]');
      n++
    )
      await new Promise((r) => setTimeout(r, 10));
    if (!appRecords.querySelector('[data-publication-state="stale"]'))
      throw Error("offline device snapshot prevented protected cache reopen");
    // An authoritative preflight loss must erase the prior payload; a later offline attempt cannot reuse it.
    snapshotOffline = false;
    contextDenial = "publication_access_denied";
    document.querySelector("#team-vault-open").click();
    await new Promise((r) => setTimeout(r, 100));
    if (
      appRecords.querySelector("article") ||
      (await repository.load(cs)).payload !== null
    )
      throw Error(
        "authoritative context denial retained managed cached payload",
      );
    contextDenial = null;
    contextOffline = true;
    document.querySelector("#team-vault-open").click();
    await new Promise((r) => setTimeout(r, 100));
    if (appRecords.querySelector("article"))
      throw Error("offline missing-cache guessed active/V1 mode");
    workspace.deactivate();
    contextOffline = false;
    snapshotOffline = false;
    network = false;
    contextDenial = null;
    const { createAuthenticatedVaultClient } = await import("/vault-sync.js");
    let finishLogout,
      heldRequest = null,
      protectedReads = 0;
    const authenticated = createAuthenticatedVaultClient({
      fetchValue: async (path, options) => {
        if (path === "/v1/auth/login")
          return new Response(
            JSON.stringify({
              user: { id: accountID },
              deviceID,
              token: "t".repeat(43),
            }),
            { status: 200 },
          );
        if (path === "/v1/auth/logout")
          return new Promise((resolve) => {
            finishLogout = () => resolve(new Response("{}", { status: 200 }));
          });
        protectedReads++;
        const url = new URL(path, endpoint),
          query = Object.fromEntries(url.searchParams);
        if (heldRequest?.matches(url)) {
          const request = heldRequest;
          heldRequest = null;
          request.started();
          return new Promise(resolve => {
            request.finish = async () => {
              const match = url.pathname.match(/resources\/([^/]+)\/parts\/([^/]+)$/);
              const value = request.status !== 200 ? { error: request.status === 401 ? "session_revoked" : "publication_access_denied" } :
                match ? await transport.part(scope, { ...query, resourceID: match[1], part: match[2] }) :
                  { formatState: "V2_ACTIVE", policyMutationAvailable: false, groupMutationAvailable: false, blockers: ["crypto_publication_required"] };
              resolve(new Response(JSON.stringify(value), { status: request.status }));
            };
          });
        }
        let value;
        if (url.pathname.endsWith("/access-context"))
          value = {
            formatState: "V2_ACTIVE",
            policyMutationAvailable: false,
            groupMutationAvailable: false,
            blockers: ["crypto_publication_required"],
          };
        else if (url.pathname.endsWith("/publication/header"))
          value = await transport.header(scope);
        else if (url.pathname.endsWith("/publication/publisher"))
          value = await transport.publisher(scope, query);
        else if (url.pathname.endsWith("/publication/directory"))
          value = await transport.directory(scope, query);
        else {
          const match = url.pathname.match(
            /\/publication\/resources\/([^/]+)\/parts\/([^/]+)$/,
          );
          if (!match) throw Error("unexpected lifecycle request");
          value = await transport.part(scope, {
            ...query,
            resourceID: match[1],
            part: match[2],
          });
        }
        return new Response(JSON.stringify(value), { status: 200 });
      },
    });
    await authenticated.login({ deviceID });
    const priorAccess = appClient.accessClient;
    appClient.session = () => authenticated.session();
    appClient.deviceID = () => authenticated.deviceID();
    appClient.publicationIdentity = () =>
      authenticated.publicationIdentity(endpoint);
    appClient.subscribePublicationIdentity = (listener) =>
      authenticated.subscribePublicationIdentity(listener);
    appClient.publicationTransport = () => authenticated.publicationTransport();
    appClient.accessClient = () => ({
      ...priorAccess(),
      getContext: (scope) => authenticated.accessClient().getContext(scope),
    });
    await workspace.activate(identity);
    workspace.setView("hosts");
    for (let n = 0; n < 100 && !appRecords.querySelector("article"); n++)
      await new Promise((r) => setTimeout(r, 10));
    if (!appRecords.querySelector("article"))
      throw Error(
        "authenticated lifecycle fixture did not materialize actual workspace",
      );
    let pendingLogout,
      restoredAfterLogout = 0,
      personalLocked = false;
    document.querySelector("#cloud-logout").addEventListener("click", () => {
      pendingLogout = completeBrowserSessionLogout({
        client: authenticated,
        documentValue: document,
        vault: {
          lock() {
            personalLocked = true;
          },
          async forgetRememberedSession() {},
        },
        clearView() {
          workspace.deactivate();
        },
        restoreView() {
          restoredAfterLogout++;
          workspace.deactivate();
        },
      });
    });
    document.querySelector("#resource-detail-dialog").showModal();
    document.querySelector("#cloud-logout").click();
    if (document.querySelector("#resource-detail-dialog").open)
      throw Error("main logout left a Vault detail dialog open");
    const readsAtLogout = protectedReads;
    if (!personalLocked)
      throw Error("main logout did not lock local controller synchronously");
    if (
      authenticated.publicationIdentity(endpoint) !== null ||
      appRecords.querySelector("article")
    )
      throw Error(
        "actual logout kept identity or managed display while response pending",
      );
    document.querySelector("#team-vault-open").click();
    workspace.setView("hosts");
    await new Promise((r) => setTimeout(r, 100));
    if (protectedReads !== readsAtLogout || appRecords.querySelector("article"))
      throw Error(
        "actual workspace started new reads or redisplayed during pending logout",
      );
    // A new authenticated identity may be installed before the older logout response completes.
    await authenticated.login({ deviceID });
    await workspace.activate(identity);
    workspace.setView("hosts");
    for (let n = 0; n < 100 && !appRecords.querySelector("article"); n++)
      await new Promise((r) => setTimeout(r, 10));
    if (!appRecords.querySelector("article"))
      throw Error(
        "new session did not materialize before old logout completed",
      );
    finishLogout();
    await pendingLogout;
    if (
      restoredAfterLogout !== 0 ||
      !authenticated.publicationIdentity(endpoint) ||
      !appRecords.querySelector("article")
    )
      throw Error("delayed main logout affected newer workspace identity");
    async function waitFor(condition, failure) {
      for (let n=0; n<200 && !condition(); n++) await new Promise(r=>setTimeout(r,10));
      if(!condition()) throw Error(failure);
    }
    // Same authenticated adapter as the app, real WebCrypto and a shared IndexedDB scope.
    const raceCases = [["load",401],["load",403],["SECRET",401],["SECRET",403],["SECRET",200],
      ["preflight",401],["preflight",403],["preflight",200]];
    for (const [operation,status] of raceCases) {
      let started;
      const ready = new Promise(r=>{started=r;});
      const request = { status, started, matches: url =>
        operation === "load" ? url.pathname.endsWith("/publication/header") :
        operation === "SECRET" ? url.pathname.endsWith("/parts/SECRET") : url.pathname.endsWith("/access-context") };
      heldRequest = request;
      if (operation === "SECRET") [...appRecords.querySelectorAll("button")].find(b=>b.textContent === "Показать секрет").click();
      else document.querySelector("#team-vault-open").click();
      await ready;
      document.querySelector("#cloud-logout").click();
      const previousLogout = pendingLogout, previousFinish = finishLogout;
      await authenticated.login({deviceID});
      await workspace.activate(identity); workspace.setView("hosts");
      await waitFor(()=>!!appRecords.querySelector('[data-publication-state="verified"]'), "new session did not materialize during " + operation + status);
      await readPublishedDetail("SNIPPET", snippetBody);
      const snippet = view.models.find(m=>m.kind === "SNIPPET");
      appRecords.querySelector(`[data-resource-id="${snippet.resourceID}"] [data-publication-action="detail"]`).click();
      const dialog = document.querySelector('dialog[data-publication-dialog="detail"]');
      [...appRecords.querySelectorAll("button")].find(b=>b.textContent === "Показать секрет").click();
      await waitFor(()=>!!document.querySelector('dialog[data-publication-dialog="secret"]'), "new secret dialog missing");
      const newSecret = document.querySelector('dialog[data-publication-dialog="secret"]');
      const protectedPayload = await repository.load(cs), newIdentity = authenticated.publicationIdentity(endpoint);
      const statusBefore = document.querySelector("#team-vault-workspace-status").textContent;
      const cardsBefore = appRecords.textContent;
      await request.finish();
      await new Promise(r=>setTimeout(r,80));
      const after = await repository.load(cs);
      if (!after.payload || JSON.stringify(after.payloadReceipt) !== JSON.stringify(protectedPayload.payloadReceipt) ||
          JSON.stringify(after.payload) !== JSON.stringify(protectedPayload.payload)) throw Error("old " + operation + status + " erased newer protected payload");
      if (JSON.stringify(authenticated.publicationIdentity(endpoint)) !== JSON.stringify(newIdentity)) throw Error("old response erased new authentication");
      if (cardsBefore !== appRecords.textContent || !dialog.isConnected || !dialog.open ||
          !newSecret.isConnected || !newSecret.open || newSecret.querySelector("pre").textContent !== "BROWSER_PRIVATE_SECRET" ||
          statusBefore !== document.querySelector("#team-vault-workspace-status").textContent)
        throw Error("old " + operation + status + " affected newer DOM/dialog/status owner");
      dialog.querySelector('[data-publication-action="close"]').click(); newSecret.querySelector("button").click();
      previousFinish(); await previousLogout;
    }
    // Selection changes without relogin must also reject a late preflight denial.
    let selectedStarted;
    const selectionReady = new Promise(r=>{selectedStarted=r;});
    const selectedRequest = { status:403, started:selectedStarted, matches:url=>url.pathname.endsWith("/access-context") };
    heldRequest = selectedRequest;
    document.querySelector("#team-vault-open").click(); await selectionReady;
    document.querySelector("#team-vault-open").click();
    await waitFor(()=>!!appRecords.querySelector('[data-publication-state="verified"]'), "new selection did not materialize");
    const selectionCache = await repository.load(cs), selectionStatus = document.querySelector("#team-vault-workspace-status").textContent;
    await selectedRequest.finish(); await new Promise(r=>setTimeout(r,80));
    if (JSON.stringify((await repository.load(cs)).payload) !== JSON.stringify(selectionCache.payload) ||
        document.querySelector("#team-vault-workspace-status").textContent !== selectionStatus || !appRecords.querySelector("article"))
      throw Error("old selected preflight denied newer selection");
    // A content dialog cannot retain a confirmed-current label after a network fallback.
    const transitionSnippet = view.models.find(m=>m.kind === "SNIPPET");
    appRecords.querySelector(`[data-resource-id="${transitionSnippet.resourceID}"] [data-publication-action="detail"]`).click();
    const onlineDetail = document.querySelector('dialog[data-publication-dialog="detail"]');
    network = true; backgroundTick();
    await waitFor(()=>!!appRecords.querySelector('[data-publication-state="stale"]'), "same-client network fallback was not stale");
    if(onlineDetail.isConnected || onlineDetail.querySelector("pre").textContent) throw Error("offline fallback retained falsely-current content dialog");
    await readPublishedDetail("SNIPPET", snippetBody, true);
    appRecords.querySelector(`[data-resource-id="${transitionSnippet.resourceID}"] [data-publication-action="detail"]`).click();
    const staleDetail = document.querySelector('dialog[data-publication-dialog="detail"]');
    network = false; backgroundTick();
    await waitFor(()=>!!appRecords.querySelector('[data-publication-state="verified"]'), "online recheck was not current");
    if(staleDetail.isConnected || staleDetail.querySelector("pre").textContent) throw Error("online refresh retained old stale dialog");
    // A real current 401 must still remove managed payload after its synchronous identity event.
    let currentStarted;
    const currentReady = new Promise(r=>{currentStarted=r;});
    const currentRequest = { status:401, started:currentStarted, matches:url=>url.pathname.endsWith("/publication/header") };
    appRecords.querySelector(`[data-resource-id="${transitionSnippet.resourceID}"] [data-publication-action="detail"]`).click();
    const deniedDetail = document.querySelector('dialog[data-publication-dialog="detail"]');
    [...appRecords.querySelectorAll("button")].find(b=>b.textContent === "Показать секрет").click();
    await waitFor(()=>!!document.querySelector('dialog[data-publication-dialog="secret"]'), "current denied view lacked secret dialog");
    const deniedSecret = document.querySelector('dialog[data-publication-dialog="secret"]');
    heldRequest = currentRequest;
    backgroundTick(); await currentReady;
    await currentRequest.finish();
    await waitFor(()=>authenticated.publicationIdentity(endpoint) === null, "current401 kept identity");
    await waitFor(()=>!appRecords.querySelector("article"), "current401 kept DOM");
    await waitFor(()=>!document.querySelector('dialog[data-publication-dialog]'), "current401 kept dialog");
    for(let n=0;n<100 && (await repository.load(cs)).payload;n++) await new Promise(r=>setTimeout(r,10));
    const retired = await repository.load(cs);
    if(deniedDetail.isConnected || deniedDetail.querySelector("pre").textContent || deniedSecret.isConnected || deniedSecret.querySelector("pre").textContent)
      throw Error("current401 failed to scrub existing owned ordinary/SECRET dialogs");
    if(retired.payload !== null || retired.highWater.sequence !== 1 || retired.highWater.hash !== headerHash)
      throw Error("current401 lost payload retirement or protected high-water");
    await authenticated.login({deviceID}); await workspace.activate(identity); workspace.setView("hosts");
    await waitFor(()=>!!appRecords.querySelector("article"), "post-denial session failed to restore");
    // Race a real IndexedDB cleanup against another same-session client's completed persistence.
    const cleanupReader = createVaultPublicationClient({...options, transport:authenticated.publicationTransport(),
      identity:()=>authenticated.publicationIdentity(endpoint), subscribeIdentityChange:cb=>authenticated.subscribePublicationIdentity(cb)});
    await cleanupReader.load();
    const clearPayload = repository.clearPayload;
    let cleanupEntered, resumeCleanup;
    const cleanupReady = new Promise(r=>{cleanupEntered=r;});
    repository.clearPayload = async (...args)=>{cleanupEntered();await new Promise(r=>{resumeCleanup=r;});return clearPayload(...args);};
    let casStarted;
    const casReady = new Promise(r=>{casStarted=r;});
    const casRequest = {status:403,started:casStarted,matches:url=>url.pathname.endsWith("/publication/header")};
    heldRequest = casRequest;
    const pendingCleanup = cleanupReader.load().catch(e=>e);
    await casReady; await casRequest.finish(); await cleanupReady;
    const replacement = createVaultPublicationClient({...options, transport:authenticated.publicationTransport(),
      identity:()=>authenticated.publicationIdentity(endpoint)});
    await replacement.load();
    const replacementCache = await repository.load(cs);
    resumeCleanup();
    if((await pendingCleanup).message !== "publication_access_denied") throw Error("CAS race did not reach authenticated403");
    if(JSON.stringify((await repository.load(cs)).payload) !== JSON.stringify(replacementCache.payload)) throw Error("atomic durable cleanup erased replacement");
    repository.clearPayload = clearPayload; cleanupReader.dispose(); replacement.dispose();
    // Actual logout closes and scrubs the read-only ordinary content dialog too.
    const currentSnippet = view.models.find(m=>m.kind === "SNIPPET");
    appRecords.querySelector(`[data-resource-id="${currentSnippet.resourceID}"] [data-publication-action="detail"]`).click();
    const logoutDetail = document.querySelector('dialog[data-publication-dialog="detail"]');
    document.querySelector("#cloud-logout").click();
    if(logoutDetail.isConnected || logoutDetail.querySelector("pre")?.textContent || appRecords.querySelector("article"))
      throw Error("actual logout retained ordinary plaintext display");
    finishLogout(); await pendingLogout;
    workspace.deactivate();
    return {
      models: view.models.length,
      requests,
      highWaterTamperDenied,
      actualApp: true,
      publishedSnippetReadCopy: true,
      publishedForwardingReadCopy: true,
      delayedAuthenticatedRaces: raceCases.length,
      sameSessionSelectionRace: true,
      protectedCleanupCAS: true,
      current401PayloadRetirement: true,
      ordinaryDialogLogoutCleanup: true,
      actualContextReference: true,
      actualOfflineReopen: true,
      actualPendingLogoutBlocked: true,
      offlineDenialAndMissingCache: true,
    };
  });
  assert.equal(result.models, 5);
  assert.equal(result.highWaterTamperDenied, true);
  assert.deepEqual(errors, []);
  console.log("PUBLICATION_BROWSER " + JSON.stringify(result));
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}

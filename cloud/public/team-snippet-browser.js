// Browser-only projection of the existing encrypted Team Snippet { title, body, folder } data.
// Folder names, search terms and expansion state must never be persisted outside the Vault.
const compareNames = (a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }) || a.localeCompare(b);

export function normalizeTeamSnippetFolder(value) {
  if (typeof value !== "string") throw new Error("invalid_snippet_folder");
  const folder = value.trim();
  if ([...folder].length > 120 || /[\p{Cc}\p{Zl}\p{Zp}]/u.test(value)
    || folder.startsWith("/") || folder.endsWith("/") || folder.includes("//")) {
    throw new Error("invalid_snippet_folder");
  }
  return folder;
}

export function teamSnippetFolder(record) {
  try { return normalizeTeamSnippetFolder(record?.data?.folder ?? ""); }
  catch { return ""; } // A malformed imported label must not hide the record or crash the catalog.
}

export function teamSnippetRecordData({ title, body, folder = "" }, baseData = {}) {
  const name = String(title ?? "").trim();
  if (!name || [...name].length > 120 || /[\r\n\u0085\u2028\u2029]/u.test(name)) throw new Error("invalid_snippet_title");
  if (typeof body !== "string" || !body || [...body].length > 32768
    || /[^\P{Cc}\t\r\n]/u.test(body)) throw new Error("invalid_snippet_body");
  // Preserve extension fields from existing clients; never reconstruct an edited record from a list summary.
  return { ...baseData, title: name, body, folder: normalizeTeamSnippetFolder(folder) };
}

export function teamSnippetFolderPaths(records) {
  const paths = new Set();
  for (const record of records) {
    if (record.type !== "snippet") continue;
    const path = teamSnippetFolder(record);
    if (!path) continue;
    const parts = path.split("/");
    for (let depth = 1; depth <= parts.length; depth += 1) paths.add(parts.slice(0, depth).join("/"));
  }
  return [...paths].sort(compareNames);
}

export function filterTeamSnippets(records, { query = "", folder = "all", sort = "title-asc" } = {}) {
  const search = String(query).trim().toLocaleLowerCase();
  const path = folder.startsWith("folder:") ? folder.slice(7) : null;
  const result = records.filter((record) => {
    if (record.type !== "snippet") return false;
    const recordFolder = teamSnippetFolder(record);
    if (folder === "none" && recordFolder !== "") return false;
    if (path !== null && recordFolder !== path && !recordFolder.startsWith(`${path}/`)) return false;
    return !search || [record.data?.title, record.data?.body, recordFolder]
      .some((value) => String(value ?? "").toLocaleLowerCase().includes(search));
  });
  return result.sort((a, b) => (sort === "modified-desc" ? ((Date.parse(b.modifiedAt) || 0) - (Date.parse(a.modifiedAt) || 0)) : 0)
    || compareNames(String(a.data?.title ?? ""), String(b.data?.title ?? ""))
    || String(a.id).localeCompare(String(b.id)));
}

export function teamSnippetTree(records) {
  const root = { path: "", name: "", records: [], children: [], count: 0 };
  const nodes = new Map([["", root]]);
  for (const record of records) {
    if (record.type !== "snippet") continue;
    let node = root;
    node.count += 1;
    const folder = teamSnippetFolder(record);
    if (folder) {
      let path = "";
      for (const name of folder.split("/")) {
        path = path ? `${path}/${name}` : name;
        if (!nodes.has(path)) {
          const child = { path, name, records: [], children: [], count: 0 };
          nodes.set(path, child);
          node.children.push(child);
        }
        node = nodes.get(path);
        node.count += 1;
      }
    }
    node.records.push(record);
  }
  for (const node of nodes.values()) node.children.sort((a, b) => compareNames(a.name, b.name));
  return root;
}

export function visibleTeamSnippetIDs(tree, collapsed) {
  const ids = collapsed.has("") ? [] : tree.records.map((record) => record.id);
  const visit = (node) => {
    if (collapsed.has(node.path)) return;
    ids.push(...node.records.map((record) => record.id));
    node.children.forEach(visit);
  };
  tree.children.forEach(visit);
  return ids;
}

export function renderTeamSnippetTree({ documentValue, container, records, collapsed, editable, onToggle, onCreateGroup, idPrefix = "team-snippet-folder-content" }) {
  const tree = teamSnippetTree(records);
  const containers = new Map();
  let sequence = 0;
  const append = (node, parent, depth = 0) => {
    const group = documentValue.createElement("section");
    const row = documentValue.createElement("div");
    const heading = documentValue.createElement("button");
    const name = documentValue.createElement("span");
    const count = documentValue.createElement("span");
    const content = documentValue.createElement("div");
    group.className = "vault-folder-group snippet-folder-group";
    group.dataset.snippetFolder = node.path;
    row.className = "snippet-folder-toolbar";
    heading.type = "button";
    heading.className = "secondary vault-folder-heading";
    name.className = "snippet-folder-name";
    name.textContent = node.path ? node.name : "Без папки";
    // Folder labels are user data, not translation keys.
    if (node.path) name.setAttribute("translate", "no");
    count.className = "snippet-folder-count";
    count.textContent = String(node.count);
    content.id = `${idPrefix}-${++sequence}`;
    content.className = "vault-folder-content snippet-folder-content";
    content.hidden = collapsed.has(node.path);
    heading.setAttribute("aria-controls", content.id);
    heading.setAttribute("aria-expanded", String(!content.hidden));
    heading.append(name, count);
    heading.addEventListener("click", () => {
      content.hidden = !content.hidden;
      heading.setAttribute("aria-expanded", String(!content.hidden));
      if (content.hidden) collapsed.add(node.path); else collapsed.delete(node.path);
      onToggle(visibleTeamSnippetIDs(tree, collapsed));
    });
    row.append(heading);
    if (node.path) {
      const create = documentValue.createElement("button");
      create.type = "button";
      create.className = "secondary snippet-folder-add";
      create.dataset.snippetCreateChild = node.path;
      create.textContent = "+";
      create.setAttribute("aria-label", "Новая вложенная группа");
      create.disabled = !editable;
      create.addEventListener("click", () => onCreateGroup(node.path));
      row.append(create);
    }
    // Cap indentation on narrow screens; the logical tree still retains every ancestor.
    if (depth > 0 && depth <= 3) group.classList.add("snippet-folder-nested");
    group.append(row, content);
    parent.append(group);
    for (const record of node.records) containers.set(record.id, content);
    // Records are appended by the existing card renderer before these child groups.
    node.children.forEach((child) => append(child, content, depth + 1));
  };
  if (tree.records.length) append({ ...tree, children: [], count: tree.records.length }, container);
  tree.children.forEach((node) => append(node, container));
  return { containers, visibleIDs: visibleTeamSnippetIDs(tree, collapsed) };
}

// Preparation-only identity model. Do not persist paths outside encrypted client state.
const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const classes = new Set(["folder", "secret", "general"]);

function checkedID(value, pattern, code) {
  if (typeof value !== "string" || !pattern.test(value)) throw new Error(code);
  return value;
}

export function createResourceIdentity({ teamID, vaultID, policyClass, parentFolderID = null },
  randomUUID = () => globalThis.crypto.randomUUID()) {
  checkedID(teamID, uuid, "invalid_team_id");
  checkedID(vaultID, uuid, "invalid_vault_id");
  if (!classes.has(policyClass)) throw new Error("invalid_resource_class");
  if (parentFolderID !== null) checkedID(parentFolderID, uuid, "invalid_resource_parent");
  return Object.freeze({ id: checkedID(randomUUID(), uuidV4, "invalid_resource_id"),
    teamID, vaultID, policyClass, parentFolderID, schemaVersion: 2, resourceVersion: 1 });
}

export function copyResourceIdentity(source, randomUUID = () => globalThis.crypto.randomUUID()) {
  return createResourceIdentity({ teamID: source.teamID, vaultID: source.vaultID,
    policyClass: source.policyClass, parentFolderID: source.parentFolderID }, randomUUID);
}
export function duplicateResourceIdentity(source, randomUUID = () => globalThis.crypto.randomUUID()) {
  return copyResourceIdentity(source, randomUUID);
}
export function importResourceIdentity(source, randomUUID = () => globalThis.crypto.randomUUID()) {
  return copyResourceIdentity(source, randomUUID);
}

export function prepareFolderIdentities({ teamID, vaultID, hostPaths = [], snippetPaths = [],
  existing = [] },
  randomUUID = () => globalThis.crypto.randomUUID()) {
  const result = [...existing];
  const byPath = new Map();
  const seenIDs = new Set();
  for (const entry of existing) {
    if (entry.teamID !== teamID || entry.vaultID !== vaultID
      || !["host", "snippet"].includes(entry.namespace)
      || typeof entry.path !== "string" || seenIDs.has(entry.id)) {
      throw new Error("invalid_staged_folder_map");
    }
    const key = `${entry.namespace}:${entry.path}`;
    if (byPath.has(key)) throw new Error("invalid_staged_folder_map");
    seenIDs.add(entry.id);
    byPath.set(key, entry);
  }
  for (const [namespace, paths] of [["host", hostPaths], ["snippet", snippetPaths]]) {
    for (const fullPath of paths) {
      if (typeof fullPath !== "string" || !fullPath || fullPath.startsWith("/")
        || fullPath.endsWith("/") || fullPath.includes("//")) throw new Error("invalid_folder_path");
      const components = fullPath.split("/");
      for (let depth = 1; depth <= components.length; depth += 1) {
        const path = components.slice(0, depth).join("/");
        const key = `${namespace}:${path}`;
        if (byPath.has(key)) continue;
        const parentPath = components.slice(0, depth - 1).join("/");
        const parentFolderID = parentPath ? byPath.get(`${namespace}:${parentPath}`).id : null;
        const identity = createResourceIdentity({ teamID, vaultID,
          policyClass: "folder", parentFolderID }, randomUUID);
        const entry = { ...identity, namespace, path };
        byPath.set(key, entry);
        result.push(entry);
      }
    }
  }
  return result;
}

export function renameFolderIdentity(folders, folderID, name) {
  if (typeof name !== "string" || !name || name.includes("/")) throw new Error("invalid_folder_name");
  const target = folders.find((folder) => folder.id === folderID);
  if (!target) throw new Error("folder_not_found");
  const prefix = `${target.path}/`;
  const parentPath = target.path.includes("/") ? target.path.slice(0, target.path.lastIndexOf("/")) : "";
  const nextPath = parentPath ? `${parentPath}/${name}` : name;
  if (folders.some((folder) => folder.namespace === target.namespace && folder.id !== folderID
    && folder.path === nextPath)) throw new Error("folder_name_conflict");
  return folders.map((folder) => folder.namespace === target.namespace
    && (folder.path === target.path || folder.path.startsWith(prefix))
    ? { ...folder, path: `${nextPath}${folder.path.slice(target.path.length)}` }
    : folder);
}
export function moveFolderIdentity(folders, folderID, newParentID) {
  const target = folders.find((folder) => folder.id === folderID);
  if (!target) throw new Error("folder_not_found");
  const parent = newParentID === null ? null : folders.find((folder) => folder.id === newParentID);
  if (newParentID !== null && (!parent || parent.namespace !== target.namespace
    || parent.teamID !== target.teamID || parent.vaultID !== target.vaultID)) {
    throw new Error("invalid_folder_parent");
  }
  if (parent && (parent.id === target.id || parent.path.startsWith(`${target.path}/`))) {
    throw new Error("folder_cycle");
  }
  const name = target.path.split("/").at(-1);
  const nextPath = parent ? `${parent.path}/${name}` : name;
  if (folders.some((folder) => folder.namespace === target.namespace
    && folder.id !== target.id && folder.path === nextPath)) throw new Error("folder_name_conflict");
  const prefix = `${target.path}/`;
  return folders.map((folder) => {
    if (folder.namespace !== target.namespace
      || (folder.path !== target.path && !folder.path.startsWith(prefix))) return folder;
    return { ...folder, path: `${nextPath}${folder.path.slice(target.path.length)}`,
      parentFolderID: folder.id === target.id ? newParentID : folder.parentFolderID };
  });
}

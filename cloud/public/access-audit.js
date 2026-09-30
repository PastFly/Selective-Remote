// Safe action-code labels only. Audit metadata, names and contents are never interpolated.
const labels = Object.freeze({
  "group.created": ["создал(а) группу доступа", "created an access group"],
  "group.renamed": ["переименовал(а) группу доступа", "renamed an access group"],
  "group.deleted": ["удалил(а) группу доступа", "deleted an access group"],
  "group.member.added": ["добавил(а) участника в группу доступа", "added an access group member"],
  "group.member.removed": ["удалил(а) участника из группы доступа", "removed an access group member"],
  "grant.created": ["создал(а) разрешение", "created an access grant"],
  "grant.changed": ["изменил(а) разрешение", "changed an access grant"],
  "grant.revoked": ["отозвал(а) разрешение", "revoked an access grant"],
  "bulk_grant.applied": ["применил(а) пакет разрешений", "applied a grant batch"],
  "bulk_revoke.applied": ["применил(а) пакет отзывов", "applied a revoke batch"],
  "resource.move_access_changed": ["изменил(а) родительскую папку ресурса", "changed a resource parent folder"],
});

export function accessAuditActionLabel(action, locale) {
  const value = labels[action];
  return value ? value[locale === "en" ? 1 : 0] : null;
}

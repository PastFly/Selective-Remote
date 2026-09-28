import assert from "node:assert/strict";
import test from "node:test";
import { notificationCopy, visibleNotifications, notificationBadge } from "../public/notification-center.js";

const item = (kind, resolvedAt = null, readAt = null) => ({ kind, resolvedAt, readAt });

test("RU and EN notification copy is semantic and never uses source error text", () => {
  assert.equal(notificationCopy(item("deviceApproval"), "en").title, "Device waiting for approval");
  assert.equal(notificationCopy(item("deviceApproval"), "ru").title, "Устройство ожидает одобрения");
  assert.equal(notificationCopy(item("failClosed"), "en").detail, "Team Vaults remain safely hidden.");
});

test("filters keep unresolved security visible after mark-read", () => {
  const items = [item("deviceApproval", null, "2026-09-28T19:00:00Z"),
    item("syncError"), item("invitation"), item("conflict", "2026-09-28T19:00:00Z")];
  assert.equal(visibleNotifications(items, "needsAction").length, 3);
  assert.deepEqual(visibleNotifications(items, "security").map((value) => value.kind), ["deviceApproval"]);
  assert.deepEqual(visibleNotifications(items, "sync").map((value) => value.kind), ["syncError", "conflict"]);
  assert.equal(notificationBadge(0), "");
  assert.equal(notificationBadge(4), "4");
  assert.equal(notificationBadge(24), "9+");
});

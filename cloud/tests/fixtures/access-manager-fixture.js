// Manual wrapper for the same production index and component used by the browser smoke.
// It carries no session, token, key, endpoint override, or production fixture switch.
if (!["localhost", "127.0.0.1"].includes(location.hostname)) {
  throw new Error("LOCAL_VISUAL_PREVIEW requires localhost");
}
document.documentElement.dataset.testSessionMode = "FRESH_ANONYMOUS";

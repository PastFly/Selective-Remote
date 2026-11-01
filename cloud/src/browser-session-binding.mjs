// The session id is not an authentication credential. It binds each restored
// browser tab to the HttpOnly cookie session it originally authenticated as.
export function browserSessionBinding({ sessionID, bearer, cookie, method, path, supplied }) {
  if (typeof sessionID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sessionID)) {
    return { allowed: false };
  }
  const binding = sessionID.toLowerCase();
  if (bearer || !cookie) return { allowed: true, binding };
  if (method === "GET" && path === "/v1/me" && supplied === undefined) return { allowed: true, binding };
  return { allowed: typeof supplied === "string" && supplied.toLowerCase() === binding, binding };
}

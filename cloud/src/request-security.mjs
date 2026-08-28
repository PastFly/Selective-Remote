import { timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";

function firstHeader(value) {
  return Array.isArray(value) ? value[0] : value;
}

function secretsMatch(actual, expected) {
  const actualBuffer = Buffer.from(String(actual ?? ""));
  const expectedBuffer = Buffer.from(String(expected ?? ""));
  return actualBuffer.length === expectedBuffer.length
    && actualBuffer.length > 0
    && timingSafeEqual(actualBuffer, expectedBuffer);
}

function normalizeIPAddress(value) {
  const candidate = String(value ?? "").trim();
  if (candidate.startsWith("::ffff:") && isIP(candidate.slice(7)) === 4) return candidate.slice(7);
  return isIP(candidate) ? candidate.toLowerCase() : "unknown";
}

export function clientIPAddress(request, proxySharedSecret) {
  const trustedProxy = secretsMatch(
    firstHeader(request.headers?.["x-selective-proxy-secret"]),
    proxySharedSecret,
  );
  if (trustedProxy) {
    return normalizeIPAddress(firstHeader(request.headers?.["x-selective-client-ip"]));
  }
  return normalizeIPAddress(request.socket?.remoteAddress);
}

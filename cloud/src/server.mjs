import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.mjs";
import { createVerificationMailer } from "./mailer.mjs";
import { PostgresStore } from "./postgres-store.mjs";
import { AuthRateLimiter } from "./rate-limiter.mjs";
import { clientIPAddress } from "./request-security.mjs";
import { isUUID, normalizeEmail } from "./security.mjs";
import { CloudService } from "./service.mjs";
import { DeviceTrustStore } from "./device-trust-store.mjs";
import { DeviceTrustService } from "./device-trust-service.mjs";
import { publicOperationError } from "./service-error.mjs";

const config = loadConfig();
const store = new PostgresStore(config.databaseURL);
const mailer = config.smtp ? createVerificationMailer(config) : null;
const service = new CloudService(store, config, mailer);
const deviceTrust = new DeviceTrustService(new DeviceTrustStore(store.pool),
  (session, password) => service.requirePasswordReauthentication(session, password));
const authRateLimiter = new AuthRateLimiter(store, config);
const publicDirectory = fileURLToPath(new URL("../public/", import.meta.url));
const maxBodyBytes = 34 * 1024 * 1024;
const maxTeamBodyBytes = 16 * 1024;
const maxInvitationWrapperBodyBytes = 1024 * 1024;
const browserSessionCookie = "sr_session";

const server = createServer(async (request, response) => {
  const requestID = crypto.randomUUID();
  response.setHeader("X-Request-ID", requestID);
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Referrer-Policy", "no-referrer");
  try {
    await route(request, response);
  } catch (error) {
    const errorCode = /^[A-Za-z0-9_-]{1,40}$/.test(String(error?.code ?? "")) ? error.code : undefined;
    console.error(JSON.stringify({ level: "error", requestID, message: "Unhandled request error", errorCode }));
    sendError(response, 500, "internal_error");
  }
});

async function route(request, response) {
  const url = new URL(request.url, config.publicOrigin);
  const method = request.method ?? "GET";
  if (method === "GET" && url.pathname === "/healthz") return sendJSON(response, 200, { status: "ok" });
  if (method === "GET" && url.pathname === "/readyz") {
    await store.ready();
    return sendJSON(response, 200, { status: "ready" });
  }
  if (method === "GET" && url.pathname === "/v1/meta") {
    return sendJSON(response, 200, { apiVersion: 1, vaultSchemaVersion: 1, registrationEnabled: config.allowRegistration });
  }
  if (method === "GET" && url.pathname === "/v1/auth/username-availability") {
    return handleOperation(response, async () => {
      await authRateLimiter.require(
        "username_availability_ip",
        clientIPAddress(request, config.proxySharedSecret),
      );
      return service.usernameAvailability(null, { username: url.searchParams.get("username") });
    });
  }
  if (method === "POST" && url.pathname === "/v1/auth/register") {
    return handleAuthOperation(request, response, "register_ip", "register_email", service.register.bind(service), 201);
  }
  if (method === "POST" && url.pathname === "/v1/auth/login") {
    return handleAuthOperation(
      request, response, "login_ip", "login_email", service.login.bind(service), 200,
      (result) => setBrowserSessionCookie(response, result.token),
    );
  }
  if (method === "POST" && url.pathname === "/v1/auth/verify-email") {
    return handleAuthOperation(request, response, "verify_email_ip", null, service.verifyEmail.bind(service));
  }
  if (method === "POST" && url.pathname === "/v1/auth/resend-verification") {
    return handleAuthOperation(
      request,
      response,
      "resend_verification_ip",
      "resend_verification_email",
      service.resendEmailVerification.bind(service),
      202,
    );
  }
  if (method === "POST" && url.pathname === "/v1/auth/request-password-reset") {
    return handleAuthOperation(
      request,
      response,
      "request_password_reset_ip",
      "request_password_reset_email",
      service.requestPasswordReset.bind(service),
      202,
    );
  }
  if (method === "POST" && url.pathname === "/v1/auth/reset-password") {
    return handleAuthOperation(request, response, "reset_password_ip", null, service.resetPassword.bind(service));
  }

  if (url.pathname.startsWith("/v1/")) {
    const bearer = bearerToken(request);
    const cookie = bearer ? null : cookieToken(request);
    if (cookie && !["GET", "HEAD"].includes(method) && !hasTrustedOrigin(request)) {
      return sendError(response, 403, "invalid_origin");
    }
    const session = await service.authenticate(bearer ?? cookie);
    if (!session) {
      if (cookie) clearBrowserSessionCookie(response);
      return sendError(response, 401, "unauthorized");
    }
    const publicationRoute=url.pathname.match(/^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/publication\/(header|publisher|directory|resources\/([^/]+)\/parts\/([^/]+))$/u);
    if(publicationRoute&&method==="GET")return handleOperation(response,async()=>{
      const operation=publicationRoute[3].startsWith("resources/")?"part":publicationRoute[3];
      const permitted=new Set(operation==="header"?[]:["generationID","headerHash",...(operation==="directory"?["cursor","limit"]:[])]);
      const input={};
      for(const [key,value]of url.searchParams){if(!permitted.has(key)||Object.hasOwn(input,key))throw Error("invalid_access_request");input[key]=value;}
      if(input.limit!==undefined){if(!/^[1-9][0-9]{0,2}$/.test(input.limit))throw Error("invalid_access_page");input.limit=Number(input.limit);}
      if(operation==="part"){input.resourceID=publicationRoute[4];input.part=publicationRoute[5];}
      return service.getPublication(session,publicationRoute[1],publicationRoute[2],operation,input);
    });
    if (method === "POST" && url.pathname === "/v1/auth/logout") {
      await store.revokeSession(session.session_id);
      clearBrowserSessionCookie(response);
      return empty(response, 204);
    }
    if (method === "GET" && url.pathname === "/v1/me") {
      return sendJSON(response, 200, {
        id: session.user_id,
        email: session.email,
        username: session.username,
        displayName: session.display_name,
        deviceID: session.device_id,
      });
    }
    if (method === "GET" && url.pathname === "/v1/account/username-availability") {
      return handleOperation(response, async () => service.usernameAvailability(session, { username: url.searchParams.get("username") }));
    }
    if (method === "PATCH" && url.pathname === "/v1/account/username") {
      return handleOperation(response, async () => service.updateUsername(session, await readJSON(request, maxTeamBodyBytes)));
    }
    if (method === "PATCH" && url.pathname === "/v1/account/password") {
      return handleOperation(response, async () => service.changePassword(session, await readJSON(request, maxTeamBodyBytes)));
    }
    if (method === "DELETE" && url.pathname === "/v1/me") {
      return handleOperation(
        response,
        async () => {
          const result = await service.deleteAccount(session, await readJSON(request, maxTeamBodyBytes));
          clearBrowserSessionCookie(response);
          return result;
        },
      );
    }
    if (method === "GET" && url.pathname === "/v1/devices") {
      return sendJSON(response, 200, { devices: await store.listDevices(session.user_id) });
    }
    if (url.pathname === "/v1/device-trust") {
      if (method === "GET") return handleOperation(response, () => deviceTrust.snapshot(session));
      if (method === "POST") return handleOperation(response, async () => {
        await requireDeviceTrustRateLimits(request, session);
        const input = await readJSON(request, maxTeamBodyBytes);
        return deviceTrust.publishRoot(session, input, idempotencyKey(request));
      }, 201);
    }
    if (url.pathname === "/v1/device-trust/requests") {
      if (method === "GET") return handleOperation(response, () => deviceTrust.requests(session));
      if (method === "POST") return handleOperation(response, async () => {
        await requireDeviceTrustRateLimits(request, session);
        return deviceTrust.request(session, await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request));
      }, 201);
    }
    const trustRequest = url.pathname.match(
      /^\/v1\/device-trust\/requests\/([^/]+)\/(approve|reject|challenges)$/u);
    if (trustRequest && method === "POST") return handleOperation(response, async () => {
      await requireDeviceTrustRateLimits(request, session);
      if (trustRequest[2] === "approve") return deviceTrust.approve(session, trustRequest[1],
        await readJSON(request, maxTeamBodyBytes), idempotencyKey(request));
      if (trustRequest[2] === "reject") return deviceTrust.reject(session, trustRequest[1],
        idempotencyKey(request));
      return deviceTrust.startChallenge(session, trustRequest[1],
        await readJSON(request, maxTeamBodyBytes), idempotencyKey(request));
    });
    const trustChallenge = url.pathname.match(
      /^\/v1\/device-trust\/requests\/([^/]+)\/challenges\/([^/]+)$/u);
    if (trustChallenge) {
      if (method === "GET") return handleOperation(response, () => deviceTrust.challenge(
        session, trustChallenge[1], trustChallenge[2]));
      if (method === "POST") return handleOperation(response, async () => {
        await requireDeviceTrustRateLimits(request, session);
        return deviceTrust.answerChallenge(session, trustChallenge[1], trustChallenge[2],
          await readJSON(request, maxTeamBodyBytes), idempotencyKey(request));
      });
    }
    const trustedDevice = url.pathname.match(/^\/v1\/device-trust\/devices\/([^/]+)\/revoke$/u);
    if (trustedDevice && method === "POST") return handleOperation(response, async () => {
      await requireDeviceTrustRateLimits(request, session);
      return deviceTrust.revoke(session, trustedDevice[1],
        await readJSON(request, maxTeamBodyBytes), idempotencyKey(request));
    });
    if (method === "POST" && url.pathname === "/v1/devices/bootstrap-key") {
      return handleOperation(
        response,
        async () => {
          await authRateLimiter.require("device_key_bootstrap_user", session.user_id);
          await authRateLimiter.require(
            "device_key_bootstrap_ip",
            clientIPAddress(request, config.proxySharedSecret),
          );
          return service.bootstrapDeviceKey(
            session,
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          );
        },
      );
    }
    const deviceMatch = url.pathname.match(/^\/v1\/devices\/([^/]+)$/i);
    if (deviceMatch && method === "POST") {
      if (!isUUID(deviceMatch[1])) return sendError(response, 400, "invalid_device");
      return handleOperation(
        response,
        async () => service.approveDeviceKey(
          session,
          deviceMatch[1],
          await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request),
        ),
      );
    }
    if (method === "DELETE" && deviceMatch) {
      if (!isUUID(deviceMatch[1])) return sendError(response, 400, "invalid_device");
      try {
        if (await deviceTrust.store.hasSignedIdentity(session.user_id, deviceMatch[1])) {
          return sendError(response, 409, "device_trust_signed_revoke_required");
        }
        const revoked = await store.revokeDevice(session.user_id, deviceMatch[1], session.device_id);
        return revoked ? empty(response, 204) : sendError(response, 404, "device_not_found");
      } catch (error) {
        return handleOperationError(response, error);
      }
    }
    if (method === "GET" && url.pathname === "/v1/vault") {
      return sendJSON(response, 200, await service.getVault(session));
    }
    if (method === "PUT" && url.pathname === "/v1/vault") {
      try {
        const result = await service.putVault(session, await readJSON(request));
        return result.conflict ? sendJSON(response, 409, result) : sendJSON(response, 200, result);
      } catch (error) {
        return handleOperationError(response, error);
      }
    }
    if (method === "GET" && url.pathname === "/v1/teams") {
      return handleOperation(response, () => service.listTeams(session));
    }
    if (method === "POST" && url.pathname === "/v1/teams") {
      return handleOperation(
        response,
        async () => service.createTeam(session, await readJSON(request, maxTeamBodyBytes), idempotencyKey(request)),
        201,
      );
    }
    const teamDeviceAdmissionPolicyMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/device-admission-policy$/i,
    );
    if (teamDeviceAdmissionPolicyMatch) {
      if (!isUUID(teamDeviceAdmissionPolicyMatch[1])) {
        return sendError(response, 404, "team_not_found");
      }
      if (method === "GET") {
        return handleOperation(
          response,
          () => service.getTeamDeviceAdmissionPolicy(session, teamDeviceAdmissionPolicyMatch[1]),
        );
      }
      if (method === "PUT") {
        return handleOperation(
          response,
          async () => service.updateTeamDeviceAdmissionPolicy(
            session,
            teamDeviceAdmissionPolicyMatch[1],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          ),
        );
      }
      return sendError(response, 404, "not_found");
    }
    const teamMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)$/i);
    if (teamMatch) {
      if (!isUUID(teamMatch[1])) return sendError(response, 404, "team_not_found");
      if (method === "PATCH") {
        return handleOperation(
          response,
          async () => service.renameTeam(
            session,
            teamMatch[1],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          ),
        );
      }
      if (method === "DELETE") {
        return handleOperation(response, async () => {
          await requireTeamSensitiveRateLimits(request, session);
          return service.archiveTeam(
            session,
            teamMatch[1],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          );
        });
      }
    }
    const teamOwnershipMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/ownership-transfer$/i);
    if (method === "POST" && teamOwnershipMatch) {
      if (!isUUID(teamOwnershipMatch[1])) return sendError(response, 404, "team_not_found");
      return handleOperation(response, async () => {
        await requireTeamSensitiveRateLimits(request, session);
        return service.transferTeamOwnership(
          session,
          teamOwnershipMatch[1],
          await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request),
        );
      });
    }
    if (method === "POST" && url.pathname === "/v1/team-invitations/accept") {
      return handleOperation(
        response,
        async () => {
          await authRateLimiter.require(
            "team_invitation_accept_ip",
            clientIPAddress(request, config.proxySharedSecret),
          );
          return service.acceptTeamInvitation(
            session,
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          );
        },
      );
    }
    if (method === "GET" && url.pathname === "/v1/team-invitations") {
      return handleOperation(response, () => service.listPendingTeamInvitations(session));
    }
    const teamMembersMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/members$/i);
    if (method === "GET" && teamMembersMatch) {
      if (!isUUID(teamMembersMatch[1])) return sendError(response, 404, "team_not_found");
      const paged = ["search", "role", "limit", "cursor"]
        .some((name) => url.searchParams.has(name));
      return handleOperation(
        response,
        () => service.listTeamMembers(
          session,
          teamMembersMatch[1],
          paged ? {
            search: url.searchParams.get("search"),
            role: url.searchParams.get("role"),
            limit: url.searchParams.get("limit"),
            cursor: url.searchParams.get("cursor"),
          } : null,
        ),
      );
    }
    const teamActivityMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/activity$/i);
    if (method === "GET" && teamActivityMatch) {
      if (!isUUID(teamActivityMatch[1])) return sendError(response, 404, "team_not_found");
      return handleOperation(response, () => service.listTeamAuditEvents(session, teamActivityMatch[1], {
        limit: url.searchParams.get("limit"), cursor: url.searchParams.get("cursor"),
      }));
    }
    const accessVaultsMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/access-vaults$/i);
    if (method === "GET" && accessVaultsMatch) {
      if (!isUUID(accessVaultsMatch[1])) return sendError(response,404,"team_not_found");
      return handleOperation(response,()=>service.listAccessVaults(session,accessVaultsMatch[1],{
        limit:url.searchParams.get("limit") ?? 50,cursor:url.searchParams.get("cursor")}));
    }
    const accessResourceMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/access-resources\/([^/]+)$/i);
    if (method === "GET" && accessResourceMatch) {
      if (!accessResourceMatch.slice(1).every(isUUID)) return sendError(response,404,"team_not_found");
      return handleOperation(response,()=>service.getAccessResource(session,...accessResourceMatch.slice(1)));
    }
    const accessSurfaceMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/(access-context|access-resources|access-devices|access-group-preview|access-group-commit)$/i);
    if (accessSurfaceMatch) {
      const [,teamID,vaultID,operation] = accessSurfaceMatch;
      if (!isUUID(teamID) || !isUUID(vaultID)) return sendError(response,404,"team_not_found");
      const page = {limit:url.searchParams.get("limit") ?? 50,cursor:url.searchParams.get("cursor")};
      if (method === "GET" && operation === "access-context") return handleOperation(response,()=>service.getAccessContext(session,teamID,vaultID));
      if (method === "GET" && operation === "access-resources") return handleOperation(response,()=>service.listAccessResources(session,teamID,vaultID,{...page,kind:url.searchParams.get("kind")}));
      if (method === "GET" && operation === "access-devices") return handleOperation(response,()=>service.listAccessDevices(session,teamID,vaultID,{...page,subjectUserID:url.searchParams.get("subjectUserID")}));
      if (method === "POST" && operation === "access-group-preview") return handleOperation(response,async()=>service.previewAccessGroupChange(session,teamID,vaultID,await readJSON(request,maxTeamBodyBytes)));
      if (method === "POST" && operation === "access-group-commit") return handleOperation(response,async()=>service.commitAccessGroupChange(session,teamID,vaultID,await readJSON(request,maxTeamBodyBytes),idempotencyKey(request)));
    }
    const accessGroupMemberMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/access-groups\/([^/]+)\/members\/([^/]+)$/i,
    );
    if (method === "DELETE" && accessGroupMemberMatch) {
      if (!accessGroupMemberMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, async () => service.removeAccessGroupMember(
        session, accessGroupMemberMatch[1], accessGroupMemberMatch[2],
        accessGroupMemberMatch[3], await readJSON(request, maxTeamBodyBytes),
        idempotencyKey(request),
      ));
    }
    const accessGroupMembersMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/access-groups\/([^/]+)\/members$/i,
    );
    if (method === "GET" && accessGroupMembersMatch) {
      if (!accessGroupMembersMatch.slice(1).every(isUUID)) return sendError(response,404,"team_not_found");
      return handleOperation(response,()=>service.listAccessGroupMembers(session,accessGroupMembersMatch[1],accessGroupMembersMatch[2],{
        limit:url.searchParams.get("limit") ?? 50,cursor:url.searchParams.get("cursor")}));
    }
    if (method === "POST" && accessGroupMembersMatch) {
      if (!accessGroupMembersMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, async () => service.addAccessGroupMember(
        session, accessGroupMembersMatch[1], accessGroupMembersMatch[2],
        await readJSON(request, maxTeamBodyBytes), idempotencyKey(request),
      ), 201);
    }
    const accessGroupMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/access-groups\/([^/]+)$/i,
    );
    if (accessGroupMatch) {
      if (!accessGroupMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      if (method === "PATCH") return handleOperation(response,
        async () => service.renameAccessGroup(session, accessGroupMatch[1],
          accessGroupMatch[2], await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request)));
      if (method === "DELETE") return handleOperation(response,
        async () => service.deleteAccessGroup(session, accessGroupMatch[1],
          accessGroupMatch[2], await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request)));
    }
    const accessGroupsMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/access-groups$/i);
    if (accessGroupsMatch) {
      if (!isUUID(accessGroupsMatch[1])) return sendError(response, 404, "team_not_found");
      if (method === "GET") return handleOperation(response,
        () => service.listAccessGroups(session, accessGroupsMatch[1], {
          limit: url.searchParams.get("limit") ?? 50,
          cursor: url.searchParams.get("cursor"),
          search: url.searchParams.get("search") ?? "",
        }));
      if (method === "POST") return handleOperation(response,
        async () => service.createAccessGroup(session, accessGroupsMatch[1],
          await readJSON(request, maxTeamBodyBytes), idempotencyKey(request)), 201);
    }
    const teamInvitationsMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/invitations$/i);
    if (teamInvitationsMatch) {
      if (!isUUID(teamInvitationsMatch[1])) return sendError(response, 404, "team_not_found");
      if (method === "GET") {
        return handleOperation(
          response,
          () => service.listTeamInvitations(session, teamInvitationsMatch[1]),
        );
      }
      if (method !== "POST") return sendError(response, 404, "not_found");
      return handleOperation(
        response,
        async () => {
          await authRateLimiter.require("team_invitation_create_user", session.user_id);
          return service.createTeamInvitation(
            session,
            teamInvitationsMatch[1],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          );
        },
        201,
      );
    }
    const teamInvitationMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/invitations\/([^/]+)$/i);
    const teamInvitationWrappersMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/invitations\/([^/]+)\/wrappers$/i,
    );
    if (method === "POST" && teamInvitationWrappersMatch) {
      if (!teamInvitationWrappersMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        async () => service.preprovisionTeamInvitationWrappers(
          session,
          teamInvitationWrappersMatch[1],
          teamInvitationWrappersMatch[2],
          await readJSON(request, maxInvitationWrapperBodyBytes),
          idempotencyKey(request),
        ),
      );
    }
    if (method === "DELETE" && teamInvitationMatch) {
      if (!isUUID(teamInvitationMatch[1]) || !isUUID(teamInvitationMatch[2])) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        () => service.cancelTeamInvitation(
          session,
          teamInvitationMatch[1],
          teamInvitationMatch[2],
          idempotencyKey(request),
        ),
      );
    }
    const teamMemberDeviceMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/members\/([^/]+)\/devices\/([^/]+)$/i,
    );
    if (method === "POST" && teamMemberDeviceMatch) {
      if (!teamMemberDeviceMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        async () => service.admitTeamMembershipDevice(
          session,
          teamMemberDeviceMatch[1],
          teamMemberDeviceMatch[2],
          teamMemberDeviceMatch[3],
          await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request),
        ),
      );
    }
    const teamMemberDevicesMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/members\/([^/]+)\/devices$/i,
    );
    if (method === "GET" && teamMemberDevicesMatch) {
      if (!teamMemberDevicesMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        () => service.listTeamMembershipDevices(
          session,
          teamMemberDevicesMatch[1],
          teamMemberDevicesMatch[2],
        ),
      );
    }
    const teamMemberMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/members\/([^/]+)$/i);
    if (teamMemberMatch) {
      if (!isUUID(teamMemberMatch[1]) || !isUUID(teamMemberMatch[2])) {
        return sendError(response, 404, "team_not_found");
      }
      if (method === "PATCH") {
        return handleOperation(
          response,
          async () => service.updateTeamMembershipRole(
            session,
            teamMemberMatch[1],
            teamMemberMatch[2],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          ),
        );
      }
      if (method === "DELETE") {
        return handleOperation(
          response,
          () => service.revokeTeamMembership(
            session,
            teamMemberMatch[1],
            teamMemberMatch[2],
            idempotencyKey(request),
          ),
        );
      }
    }
    const teamVaultsMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/vaults$/i);
    if (teamVaultsMatch) {
      if (!isUUID(teamVaultsMatch[1])) return sendError(response, 404, "team_not_found");
      if (method === "GET") {
        return handleOperation(response, () => service.listSharedVaults(session, teamVaultsMatch[1]));
      }
      if (method === "POST") {
        return handleOperation(
          response,
          async () => service.createSharedVault(
            session,
            teamVaultsMatch[1],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          ),
          201,
        );
      }
    }
    const teamVaultDevicesMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/key-devices$/i,
    );
    if (method === "GET" && teamVaultDevicesMatch) {
      if (!isUUID(teamVaultDevicesMatch[1]) || !isUUID(teamVaultDevicesMatch[2])) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        () => service.listTeamKeyDevices(session, teamVaultDevicesMatch[1], teamVaultDevicesMatch[2]),
      );
    }
    const teamVaultWrappersMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/wrappers$/i,
    );
    if (method === "POST" && teamVaultWrappersMatch) {
      if (!isUUID(teamVaultWrappersMatch[1]) || !isUUID(teamVaultWrappersMatch[2])) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(
        response,
        async () => service.grantSharedVaultWrapper(
          session,
          teamVaultWrappersMatch[1],
          teamVaultWrappersMatch[2],
          await readJSON(request, maxTeamBodyBytes),
          idempotencyKey(request),
        ),
        201,
      );
    }
    const whoHasAccessMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/who-has-access\/([^/]+)$/i,
    );
    if (method === "GET" && whoHasAccessMatch) {
      if (!whoHasAccessMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, () => service.listWhoHasAccess(
        session, whoHasAccessMatch[1], whoHasAccessMatch[2], whoHasAccessMatch[3], {
          limit: url.searchParams.get("limit") ?? 50,
          cursor: url.searchParams.get("cursor"),
        },
      ));
    }
    const resourcesByPrincipalMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/resources-by-principal\/([^/]+)\/([^/]+)$/i,
    );
    if (method === "GET" && resourcesByPrincipalMatch) {
      if (!isUUID(resourcesByPrincipalMatch[1]) || !isUUID(resourcesByPrincipalMatch[2])
        || !isUUID(resourcesByPrincipalMatch[4])) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, () => service.listResourcesByPrincipal(
        session, resourcesByPrincipalMatch[1], resourcesByPrincipalMatch[2],
        resourcesByPrincipalMatch[3].toUpperCase(), resourcesByPrincipalMatch[4], {
          limit: url.searchParams.get("limit") ?? 50,
          cursor: url.searchParams.get("cursor"),
        },
      ));
    }
    const effectiveAccessMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/effective-access\/([^/]+)$/i,
    );
    if (method === "GET" && effectiveAccessMatch) {
      if (!effectiveAccessMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, () => service.getEffectiveAccess(
        session, effectiveAccessMatch[1], effectiveAccessMatch[2],
        effectiveAccessMatch[3], url.searchParams.get("subjectUserID"),
        url.searchParams.get("subjectDeviceID"),
      ));
    }
    const accessGrantsMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/access-grants$/i,
    );
    if (method === "GET" && accessGrantsMatch) {
      if (!accessGrantsMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, () => service.listAccessGrants(
        session, accessGrantsMatch[1], accessGrantsMatch[2], {
          limit: url.searchParams.get("limit") ?? 50,
          cursor: url.searchParams.get("cursor"),
        },
      ));
    }
    const accessPreviewMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/access-preview$/i,
    );
    if (method === "POST" && accessPreviewMatch) {
      if (!accessPreviewMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, async () => service.previewAccessChange(
        session, accessPreviewMatch[1], accessPreviewMatch[2],
        await readJSON(request, maxTeamBodyBytes),
      ));
    }
    const accessCommitMatch = url.pathname.match(
      /^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)\/access-commit$/i,
    );
    if (method === "POST" && accessCommitMatch) {
      if (!accessCommitMatch.slice(1).every(isUUID)) {
        return sendError(response, 404, "team_not_found");
      }
      return handleOperation(response, async () => service.commitAccessChange(
        session, accessCommitMatch[1], accessCommitMatch[2],
        await readJSON(request, maxTeamBodyBytes), idempotencyKey(request),
      ));
    }
    const teamVaultMatch = url.pathname.match(/^\/v1\/teams\/([^/]+)\/vaults\/([^/]+)$/i);
    if (teamVaultMatch) {
      if (!isUUID(teamVaultMatch[1]) || !isUUID(teamVaultMatch[2])) {
        return sendError(response, 404, "team_not_found");
      }
      if (method === "GET") {
        return handleOperation(
          response,
          () => service.getSharedVault(session, teamVaultMatch[1], teamVaultMatch[2]),
        );
      }
      if (method === "PATCH") {
        return handleOperation(
          response,
          async () => service.renameSharedVault(
            session,
            teamVaultMatch[1],
            teamVaultMatch[2],
            await readJSON(request, maxTeamBodyBytes),
            idempotencyKey(request),
          ),
        );
      }
      if (method === "PUT") {
        try {
          const result = await service.putSharedVault(
            session,
            teamVaultMatch[1],
            teamVaultMatch[2],
            await readJSON(request),
            idempotencyKey(request),
          );
          return sendJSON(response, result.conflict ? 409 : 200, result);
        } catch (error) {
          return handleOperationError(response, error);
        }
      }
    }
    return sendError(response, 404, "not_found");
  }

  if (method === "GET" || method === "HEAD") return serveStatic(url.pathname, response, method === "HEAD");
  return sendError(response, 404, "not_found");
}

async function requireTeamSensitiveRateLimits(request, session) {
  await authRateLimiter.require("team_sensitive_user", session.user_id);
  await authRateLimiter.require("team_sensitive_ip", clientIPAddress(request, config.proxySharedSecret));
}

async function requireDeviceTrustRateLimits(request, session) {
  await authRateLimiter.require("device_trust_user", session.user_id);
  await authRateLimiter.require("device_trust_ip", clientIPAddress(request, config.proxySharedSecret));
}

async function handleAuthOperation(request, response, ipScope, emailScope, operation, successStatus = 200, beforeSend = null) {
  return handleOperation(response, async () => {
    await authRateLimiter.require(ipScope, clientIPAddress(request, config.proxySharedSecret));
    const input = await readJSON(request);
    if (emailScope) {
      let email = null;
      try { email = normalizeEmail(input.email); } catch {}
      if (email) await authRateLimiter.require(emailScope, email);
    }
    const result = await operation(input);
    beforeSend?.(result);
    return result;
  }, successStatus);
}

async function handleOperation(response, operation, successStatus = 200) {
  try {
    return sendJSON(response, successStatus, await operation());
  } catch (error) {
    return handleOperationError(response, error);
  }
}

function handleOperationError(response, error) {
  const publicError = publicOperationError(error);
  if (!publicError) throw error;
  if (publicError.code === "rate_limited" && Number.isInteger(error.retryAfterSeconds)) {
    response.setHeader("Retry-After", String(Math.max(1, error.retryAfterSeconds)));
  }
  if (publicError.code === "group_grants_must_be_revoked_first") {
    return sendJSON(response, 409, { error: publicError.code,
      safeCount: error.safeCount === "1001+" ? "1001+" : null });
  }
  return sendError(response, publicError.status, publicError.code);
}

function bearerToken(request) {
  const value = request.headers.authorization ?? "";
  return value.startsWith("Bearer ") ? value.slice(7) : null;
}

function cookieToken(request) {
  const value = request.headers.cookie ?? "";
  for (const part of value.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0 || part.slice(0, separator).trim() !== browserSessionCookie) continue;
    const token = part.slice(separator + 1).trim();
    return token.length >= 32 && token.length <= 256 ? token : null;
  }
  return null;
}

function sessionCookie(value, maximumAge) {
  const secure = new URL(config.publicOrigin).protocol === "https:" ? "; Secure" : "";
  return `${browserSessionCookie}=${value}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maximumAge}${secure}`;
}

function setBrowserSessionCookie(response, token) {
  response.setHeader("Set-Cookie", sessionCookie(token, config.sessionTTLDays * 86_400));
}

function clearBrowserSessionCookie(response) {
  response.setHeader("Set-Cookie", sessionCookie("", 0));
}

function hasTrustedOrigin(request) {
  const origin = Array.isArray(request.headers.origin) ? request.headers.origin[0] : request.headers.origin;
  return origin === config.publicOrigin;
}

function idempotencyKey(request) {
  const value = request.headers["idempotency-key"];
  return Array.isArray(value) ? value[0] : value;
}

async function readJSON(request, maximumBytes = maxBodyBytes) {
  const contentType = request.headers["content-type"] ?? "";
  const mediaType = contentType.split(";", 1)[0].trim().toLowerCase();
  if (mediaType !== "application/json" && !/^application\/[a-z0-9.+-]+\+json$/.test(mediaType)) {
    throw new Error("invalid_content_type");
  }
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maximumBytes) throw new Error("request_too_large");
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new Error("invalid_json"); }
}

async function serveStatic(pathname, response, head) {
  const relative = ["/", "/login"].includes(pathname) || /^\/app(?:\/[^/]+)?$/u.test(pathname)
    ? "index.html"
    : pathname.slice(1);
  if (!/^[a-zA-Z0-9._/-]+$/.test(relative) || relative.includes("..")) return sendError(response, 404, "not_found");
  try {
    const data = await readFile(join(publicDirectory, relative));
    const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml" };
    response.writeHead(200, {
      "Content-Type": types[extname(relative)] ?? "application/octet-stream",
      "Cache-Control": [".html", ".js", ".css"].includes(extname(relative)) ? "no-store" : "public, max-age=3600",
      "Content-Security-Policy": "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    });
    response.end(head ? undefined : data);
  } catch { sendError(response, 404, "not_found"); }
}

function sendJSON(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

function sendError(response, status, code) { sendJSON(response, status, { error: code }); }
function empty(response, status) { response.writeHead(status); response.end(); }

async function start() {
  if (config.allowRegistration) {
    try {
      await mailer.verifyConnection();
    } catch {
      console.error(JSON.stringify({ level: "error", message: "SMTP preflight failed" }));
      await store.close();
      process.exit(1);
    }
  }
  server.listen(config.port, config.host, () => {
    console.log(JSON.stringify({ level: "info", message: "Selective Remote Cloud listening", host: config.host, port: config.port }));
  });
  scheduleOutboxPump();
}

let outboxPumpRunning = false;
let outboxTimer = null;

await start();

outboxTimer = mailer ? setInterval(scheduleOutboxPump, 5_000) : null;
outboxTimer?.unref();

function scheduleOutboxPump() {
  if (!mailer || outboxPumpRunning) return;
  outboxPumpRunning = true;
  service.queueTeamInvitationOutboxDispatch()
    .catch(() => console.error(JSON.stringify({ level: "error", message: "Team outbox dispatch failed" })))
    .finally(() => { outboxPumpRunning = false; });
}

async function shutdown(signal) {
  console.log(JSON.stringify({ level: "info", message: "Shutting down", signal }));
  if (outboxTimer) clearInterval(outboxTimer);
  server.close(async () => {
    await service.waitForBackgroundTasks();
    await store.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

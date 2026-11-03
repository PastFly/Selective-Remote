# Temporary Team security stop

The retained V1 history currently commits Vault ciphertext, envelope metadata and
Team wrappers, but does not commit Team membership, roles, device revocation or
admission state. Restoring an older PostgreSQL snapshot can therefore restore a
revoked member and its already-retained key wrapper without changing the journal
or the independent anchor. This is a confirmed P0; a matching anchor is not
proof of a current access-control state.

Until an independently retained Team security baseline and every relevant
transition have been designed, implemented and independently verified, the
HTTP server denies all `/v1/teams` and `/v1/team-invitations` routes. It also
denies mutating `/v1/devices` and `/v1/device-trust` routes. Existing V1 PUT
stop and legacy-client rejection remain in force. The stop is intentionally
unconditional and does not activate V2. These denials mean Team sync, Team
invitation, Team creation and Device Approval are unavailable; they must not
be reported as passing or production-ready.

The current candidate advertises `teamSafetyStopVersion: 1`. The retained,
root-protected controller settings must include the same value, and the
controller rejects any candidate without this capability before opening
traffic. The installer only prepares settings for a candidate with that
capability. Old settings deliberately fail closed and require a reviewed,
closed-ingress update; never silently default or remove this field to recover
availability. The controller binary and protected settings remain within the
trusted operational boundary: restoring an older controller and its settings
along with the database is outside this guard and requires independent ingress
fencing. Do not deploy or remove the stop until that boundary and real
recovery have been proven.

The stop is an HTTP boundary, not a retained membership baseline. Direct store
calls, SQL access and clients with previously obtained keys are not protected
by it. Removing the stop also requires covering indirect account/device changes,
ownership, Team archive, group/grant policies, role changes and removal, as
well as in-flight operations, old-server/controller downgrade and restoration
of snapshots taken before and after the baseline. Staging proof and security
review must use synthetic principals and preserve all production data.

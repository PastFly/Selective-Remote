# V1 fence high-water trust boundary

Status: implementation in progress. The HTTP V1 write stop remains mandatory;
this document and the anchor library are not deployment acceptance.

The anchor is an independently administered PostgreSQL primary that persists a
monotonic pair `(position, digest)` per deployment. Its storage, credentials,
backups, failover and administrative authority must be outside the application
PostgreSQL, controller journal, controller state and their rollback domain. A
separate database or volume in the same host snapshot does not satisfy this
requirement. The anchor primary must not lose acknowledged transactions on
restart or promotion; asynchronous standby promotion without preserving these
commits is not acceptable. Availability is deliberately sacrificed: missing,
unreachable, malformed or standby anchor state must close the gate.

The anchor administrator provisions the schema and deployment identity once,
retains exclusive ownership and grants the service identity only schema USAGE
and EXECUTE on the read/advance functions. The runtime identity must not own the
schema, functions or table and must have no ability to alter, delete, restore,
truncate or provision anchor rows. The administrator and the anchor service's
storage are trusted: compromise, rollback, or dishonest re-provisioning of the
anchor itself is outside this model. Compromise of a runtime writer can deny
service by raising the anchor, but cannot lower it through these functions.

The logical history hash is SHA-256 chained over validated events and ordinal,
not the on-disk active segment layout. A checkpoint must retain the entire
validated event sequence and leave the position and digest unchanged. Every
append must durably write the local event and advance the external anchor before
it can acknowledge completion or allow a corresponding database commit. A
missing or different high-water value must never be silently initialized from a
restored local journal. The installed independent controller must validate the
anchor before opening traffic and must enforce a non-downgradable capability
floor; installing a library only in the candidate server does not satisfy this
requirement.

A crash between local fsync and the anchor acknowledgement can leave a retained
lock and uncertain state. No automatic unlock is authorized without draining
all writers, establishing whether the anchor advanced, verifying the complete
retained history and proving any database outcome needed for recovery. An
ambiguous COMMIT is not proof of abort. Recovery and archive retention must be
verified using the installed controller before the V1 write stop is removed.

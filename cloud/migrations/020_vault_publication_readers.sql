-- Permanent identities are independent of preparation attempts. No runtime activation.
DROP TRIGGER release_discarded_migration_identity ON vault_migration_resources;
DROP TRIGGER migration_resource_identity_gate ON vault_migration_resources;
DROP TRIGGER registry_migration_identity_gate ON vault_resource_registry;
ALTER TABLE vault_resource_registry DROP CONSTRAINT registry_identity_reservation;
ALTER TABLE vault_migration_resources DROP CONSTRAINT migration_identity_reservation;

-- Discarded attempts retain the signed source graph even after old reservations were released.
CREATE TEMP TABLE reconciled_resource_identities ON COMMIT DROP AS
 SELECT id,team_id,vault_id,COALESCE(policy_kind,CASE policy_class WHEN 'folder' THEN 'FOLDER' WHEN 'secret' THEN 'CREDENTIAL' ELSE 'UNCLASSIFIED_GENERAL' END) AS kind,deleted_at
 FROM vault_resource_registry
 UNION ALL
 SELECT (r->>'id')::uuid,a.team_id,a.vault_id,r->>'kind',NULL::timestamptz
 FROM vault_migration_attempts a CROSS JOIN LATERAL jsonb_array_elements(a.resources) r;
DO $$ BEGIN
 IF EXISTS(SELECT id FROM reconciled_resource_identities GROUP BY id HAVING count(DISTINCT (team_id,vault_id,kind))<>1)
 THEN RAISE EXCEPTION 'historical_resource_id_collision'; END IF;
 IF EXISTS(SELECT 1 FROM vault_resource_identity_reservations old WHERE NOT EXISTS(
  SELECT 1 FROM reconciled_resource_identities r WHERE (r.id,r.team_id,r.vault_id)=(old.id,old.team_id,old.vault_id)))
 THEN RAISE EXCEPTION 'historical_resource_identity_unresolved'; END IF;
END $$;
DROP TABLE vault_resource_identity_reservations;
CREATE TABLE vault_resource_identity_reservations (
 id uuid PRIMARY KEY,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('HOST','CREDENTIAL','SNIPPET','FORWARDING','FOLDER','UNCLASSIFIED_GENERAL')),
 deleted_at timestamptz,
 UNIQUE(id,team_id,vault_id,kind),
 FOREIGN KEY(vault_id,team_id) REFERENCES shared_vaults(id,team_id)
);
INSERT INTO vault_resource_identity_reservations(id,team_id,vault_id,kind,deleted_at)
 SELECT id,team_id,vault_id,kind,max(deleted_at) FROM reconciled_resource_identities GROUP BY id,team_id,vault_id,kind;
ALTER TABLE vault_resource_registry DROP COLUMN identity_generation;
ALTER TABLE vault_resource_registry ADD COLUMN identity_kind text GENERATED ALWAYS AS
 (COALESCE(policy_kind,CASE policy_class WHEN 'folder' THEN 'FOLDER' WHEN 'secret' THEN 'CREDENTIAL' ELSE 'UNCLASSIFIED_GENERAL' END)) STORED;
ALTER TABLE vault_resource_registry ADD CONSTRAINT registry_identity_reservation
 FOREIGN KEY(id,team_id,vault_id,identity_kind) REFERENCES vault_resource_identity_reservations(id,team_id,vault_id,kind);
ALTER TABLE vault_migration_resources DROP CONSTRAINT vault_migration_resources_pkey;
ALTER TABLE vault_migration_resources ADD PRIMARY KEY(attempt_id,id);
ALTER TABLE vault_migration_resources ADD CONSTRAINT migration_identity_reservation
 FOREIGN KEY(id,team_id,vault_id,kind) REFERENCES vault_resource_identity_reservations(id,team_id,vault_id,kind);
CREATE OR REPLACE FUNCTION guard_resource_identity_reservation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' OR (NEW.id,NEW.team_id,NEW.vault_id,NEW.kind) IS DISTINCT FROM (OLD.id,OLD.team_id,OLD.vault_id,OLD.kind)
 OR OLD.deleted_at IS NOT NULL OR NEW.deleted_at IS NULL THEN RAISE EXCEPTION 'immutable_resource_identity_reservation'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_resource_identity_reservation BEFORE UPDATE OR DELETE ON vault_resource_identity_reservations
 FOR EACH ROW EXECUTE FUNCTION guard_resource_identity_reservation();
CREATE OR REPLACE FUNCTION migration_resource_identity_gate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE resource_kind text; reserved vault_resource_identity_reservations%ROWTYPE;
BEGIN
 resource_kind:=CASE WHEN TG_TABLE_NAME='vault_migration_resources' THEN to_jsonb(NEW)->>'kind'
 ELSE COALESCE(to_jsonb(NEW)->>'policy_kind',CASE to_jsonb(NEW)->>'policy_class' WHEN 'folder' THEN 'FOLDER' WHEN 'secret' THEN 'CREDENTIAL' ELSE 'UNCLASSIFIED_GENERAL' END) END;
 -- Physical uniqueness arbitrates old RR snapshots and INSERT order; row lock serializes tombstones.
 INSERT INTO vault_resource_identity_reservations(id,team_id,vault_id,kind)
 VALUES(NEW.id,NEW.team_id,NEW.vault_id,resource_kind) ON CONFLICT(id) DO NOTHING;
 SELECT * INTO reserved FROM vault_resource_identity_reservations WHERE id=NEW.id FOR UPDATE;
 IF NOT FOUND OR (reserved.team_id,reserved.vault_id,reserved.kind) IS DISTINCT FROM (NEW.team_id,NEW.vault_id,resource_kind)
 THEN RAISE EXCEPTION 'resource_id_collision'; END IF;
 IF reserved.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'tombstoned_resource_identity'; END IF;
 IF TG_TABLE_NAME='vault_resource_registry' AND to_jsonb(NEW)->>'deleted_at' IS NOT NULL THEN
  UPDATE vault_resource_identity_reservations SET deleted_at=(to_jsonb(NEW)->>'deleted_at')::timestamptz WHERE id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER migration_resource_identity_gate BEFORE INSERT ON vault_migration_resources
 FOR EACH ROW EXECUTE FUNCTION migration_resource_identity_gate();
CREATE TRIGGER registry_migration_identity_gate BEFORE INSERT OR UPDATE ON vault_resource_registry
 FOR EACH ROW EXECUTE FUNCTION migration_resource_identity_gate();
ALTER TABLE vault_migration_attempts DROP CONSTRAINT vault_migration_attempts_resources_check;
ALTER TABLE vault_migration_attempts ADD CHECK(jsonb_array_length(resources) BETWEEN 0 AND 1000);

CREATE TABLE vault_publication_projections (
 attempt_id uuid PRIMARY KEY,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 projection jsonb NOT NULL CHECK(octet_length(projection::text)<=67108864),
 administrative_sidecar jsonb NOT NULL CHECK(octet_length(administrative_sidecar::text)<=1048576),
 header_hash text NOT NULL CHECK(header_hash ~ '^[a-f0-9]{64}$'),
 UNIQUE(attempt_id,team_id,vault_id),
 FOREIGN KEY(attempt_id,team_id,vault_id) REFERENCES vault_migration_attempts(id,team_id,vault_id)
);
CREATE TRIGGER guard_publication_projection BEFORE INSERT OR UPDATE OR DELETE ON vault_publication_projections
 FOR EACH ROW EXECUTE FUNCTION guard_migration_object();

-- Staging-only publication generation. No Vault state changes in this migration.
CREATE TABLE vault_migration_attempts (
 id uuid PRIMARY KEY,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 actor_user_id uuid NOT NULL REFERENCES users(id),
 actor_device_id uuid NOT NULL REFERENCES devices(id),
 state text NOT NULL DEFAULT 'V2_PREPARING' CHECK(state IN ('V2_PREPARING','V2_READY','V2_ACTIVE','FAILED_PRE_ACTIVATION','DISCARDED')),
 source_revision bigint NOT NULL CHECK(source_revision>0),
 source_hash text NOT NULL,
 snapshot_hash text NOT NULL CHECK(snapshot_hash ~ '^[a-f0-9]{64}$'),
 snapshot jsonb NOT NULL,
 policy jsonb NOT NULL,
 resources jsonb NOT NULL CHECK(jsonb_array_length(resources) BETWEEN 1 AND 1000),
 scope jsonb NOT NULL,
 checkpoint jsonb,
 manifest jsonb,
 manifest_hash text CHECK(manifest_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,team_id,vault_id),
 FOREIGN KEY(vault_id,team_id) REFERENCES shared_vaults(id,team_id),
 CHECK(state NOT IN ('V2_READY','V2_ACTIVE') OR (manifest IS NOT NULL AND manifest_hash IS NOT NULL))
);
CREATE INDEX vault_migration_attempts_scope ON vault_migration_attempts(team_id,vault_id,created_at);
CREATE TABLE vault_migration_resources (
 id uuid PRIMARY KEY,
 attempt_id uuid NOT NULL,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('HOST','CREDENTIAL','SNIPPET','FORWARDING','FOLDER')),
 parent_folder_id uuid,
 source_ordinal integer NOT NULL CHECK(source_ordinal>=0),
 UNIQUE(attempt_id,id),
 UNIQUE(attempt_id,source_ordinal),
 FOREIGN KEY(attempt_id,team_id,vault_id) REFERENCES vault_migration_attempts(id,team_id,vault_id),
 FOREIGN KEY(attempt_id,parent_folder_id) REFERENCES vault_migration_resources(attempt_id,id) DEFERRABLE INITIALLY DEFERRED,
 CHECK(parent_folder_id IS NULL OR parent_folder_id<>id)
);
CREATE TABLE vault_migration_parts (
 attempt_id uuid NOT NULL,
 resource_id uuid NOT NULL,
 part text NOT NULL CHECK(part IN ('GENERAL','METADATA','SECRET')),
 object jsonb NOT NULL CHECK(octet_length(object::text)<=33554432),
 sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
 PRIMARY KEY(attempt_id,resource_id,part),
 FOREIGN KEY(attempt_id,resource_id) REFERENCES vault_migration_resources(attempt_id,id)
);
ALTER TABLE shared_vaults ADD COLUMN active_publication_attempt_id uuid;
ALTER TABLE shared_vaults ADD CONSTRAINT vault_active_publication_scope
 FOREIGN KEY(active_publication_attempt_id,team_id,id) REFERENCES vault_migration_attempts(id,team_id,vault_id);
ALTER TABLE shared_vaults DROP CONSTRAINT shared_vault_payload_complete;
ALTER TABLE shared_vaults ADD CONSTRAINT shared_vault_payload_complete CHECK (
 (active_publication_attempt_id IS NOT NULL AND format_state='V2_ACTIVE' AND envelope_version IS NULL AND ciphertext IS NULL AND nonce IS NULL AND auth_tag IS NULL AND content_hash IS NULL AND updated_by_device_id IS NULL)
 OR (active_publication_attempt_id IS NULL AND ((revision=0 AND envelope_version IS NULL AND ciphertext IS NULL AND nonce IS NULL AND auth_tag IS NULL AND content_hash IS NULL AND updated_by_device_id IS NULL)
 OR (revision>0 AND envelope_version=1 AND ciphertext IS NOT NULL AND nonce IS NOT NULL AND auth_tag IS NOT NULL AND content_hash IS NOT NULL)))
);
CREATE FUNCTION guard_migration_attempt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'migration_attempt_retained'; END IF;
 IF OLD.state IN ('V2_ACTIVE','DISCARDED') THEN RAISE EXCEPTION 'immutable_migration_attempt'; END IF;
 IF (NEW.id,NEW.team_id,NEW.vault_id,NEW.actor_user_id,NEW.actor_device_id,NEW.source_revision,NEW.source_hash,NEW.snapshot_hash,NEW.snapshot,NEW.policy,NEW.resources,NEW.scope,NEW.created_at)
 IS DISTINCT FROM (OLD.id,OLD.team_id,OLD.vault_id,OLD.actor_user_id,OLD.actor_device_id,OLD.source_revision,OLD.source_hash,OLD.snapshot_hash,OLD.snapshot,OLD.policy,OLD.resources,OLD.scope,OLD.created_at) THEN RAISE EXCEPTION 'immutable_migration_snapshot'; END IF;
 IF OLD.state='V2_READY' AND (NEW.state NOT IN ('V2_ACTIVE','DISCARDED') OR (NEW.manifest,NEW.manifest_hash,NEW.checkpoint) IS DISTINCT FROM (OLD.manifest,OLD.manifest_hash,OLD.checkpoint)) THEN RAISE EXCEPTION 'immutable_ready_migration'; END IF;
 IF NEW.state='V2_ACTIVE' AND OLD.state<>'V2_READY' THEN RAISE EXCEPTION 'migration_not_ready'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_migration_attempt BEFORE UPDATE OR DELETE ON vault_migration_attempts FOR EACH ROW EXECUTE FUNCTION guard_migration_attempt();
CREATE FUNCTION guard_migration_object() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE attempt uuid; status text;
BEGIN
 attempt:=CASE WHEN TG_OP='DELETE' THEN OLD.attempt_id ELSE NEW.attempt_id END;
 SELECT state INTO status FROM vault_migration_attempts WHERE id=attempt FOR UPDATE;
 IF TG_OP='UPDATE' OR (TG_OP='INSERT' AND status<>'V2_PREPARING') OR (TG_OP='DELETE' AND status<>'DISCARDED') THEN RAISE EXCEPTION 'immutable_migration_object'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_migration_resource BEFORE INSERT OR UPDATE OR DELETE ON vault_migration_resources FOR EACH ROW EXECUTE FUNCTION guard_migration_object();
CREATE TRIGGER guard_migration_part BEFORE INSERT OR UPDATE OR DELETE ON vault_migration_parts FOR EACH ROW EXECUTE FUNCTION guard_migration_object();
-- Serialize identity reservation across both generations, including direct SQL.
CREATE FUNCTION migration_resource_identity_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.id::text,19));
 IF TG_TABLE_NAME='vault_migration_resources' AND EXISTS(SELECT 1 FROM vault_resource_registry WHERE id=NEW.id)
 OR TG_TABLE_NAME='vault_resource_registry' AND EXISTS(SELECT 1 FROM vault_migration_resources WHERE id=NEW.id) THEN RAISE EXCEPTION 'resource_id_collision'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER migration_resource_identity_gate BEFORE INSERT ON vault_migration_resources FOR EACH ROW EXECUTE FUNCTION migration_resource_identity_gate();
CREATE TRIGGER registry_migration_identity_gate BEFORE INSERT ON vault_resource_registry FOR EACH ROW EXECUTE FUNCTION migration_resource_identity_gate();
CREATE FUNCTION guard_active_migration_publication() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.active_publication_attempt_id IS NOT NULL AND (NEW.active_publication_attempt_id IS DISTINCT FROM OLD.active_publication_attempt_id OR NEW.format_state<>'V2_ACTIVE' OR NEW.format_schema_version<>2 OR NEW.revision<>OLD.revision OR NEW.key_generation<>OLD.key_generation OR NEW.ciphertext IS NOT NULL) THEN RAISE EXCEPTION 'irreversible_v2_publication'; END IF;
 IF NEW.active_publication_attempt_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM vault_migration_attempts WHERE id=NEW.active_publication_attempt_id AND team_id=NEW.team_id AND vault_id=NEW.id AND state='V2_ACTIVE') THEN RAISE EXCEPTION 'migration_not_active'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_active_migration_publication BEFORE UPDATE ON shared_vaults FOR EACH ROW EXECUTE FUNCTION guard_active_migration_publication();
CREATE VIEW active_vault_migration_parts AS
 SELECT p.*,a.team_id,a.vault_id,a.manifest_hash FROM vault_migration_parts p
 JOIN vault_migration_attempts a ON a.id=p.attempt_id AND a.state='V2_ACTIVE'
 JOIN shared_vaults v ON v.id=a.vault_id AND v.team_id=a.team_id AND v.format_state='V2_ACTIVE' AND v.active_publication_attempt_id=a.id;

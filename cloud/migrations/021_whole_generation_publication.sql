-- Dormant whole-Team publication foundation. No Vault activation or deployment.
CREATE TABLE team_publication_operations (
 id uuid PRIMARY KEY,
 team_id uuid NOT NULL REFERENCES teams(id),
 actor_user_id uuid NOT NULL REFERENCES users(id),
 actor_device_id uuid NOT NULL REFERENCES devices(id),
 session_id uuid NOT NULL,
 actor_key_version bigint NOT NULL CHECK(actor_key_version>0),
 state text NOT NULL DEFAULT 'PREPARING' CHECK(state IN('PREPARING','READY','COMMITTED','DISCARDED')),
 request_hash text NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
 request jsonb NOT NULL CHECK(jsonb_typeof(request)='object' AND octet_length(request::text)<=67108864),
 prepared jsonb NOT NULL CHECK(jsonb_typeof(prepared)='object' AND octet_length(prepared::text)<=67108864),
 counts jsonb NOT NULL CHECK(jsonb_typeof(counts)='object' AND counts ?& ARRAY['vaults','resources','parts','wrappers']
   AND counts-ARRAY['vaults','resources','parts','wrappers']='{}'::jsonb
   AND jsonb_typeof(counts->'vaults')='number' AND jsonb_typeof(counts->'resources')='number'
   AND jsonb_typeof(counts->'parts')='number' AND jsonb_typeof(counts->'wrappers')='number'
   AND (counts->>'vaults')::integer BETWEEN 1 AND 10 AND (counts->>'resources')::integer BETWEEN 0 AND 1000
   AND (counts->>'parts')::integer BETWEEN 1 AND 2010 AND (counts->>'wrappers')::integer BETWEEN 1 AND 10000),
 effective_at timestamptz NOT NULL,
 checkpoint jsonb CHECK(octet_length(checkpoint::text)<=67108864),
 committed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,team_id),
 CHECK((state='COMMITTED')=(committed_at IS NOT NULL)),
 CHECK(request ?& ARRAY['version','teamID','operationID','vaults'] AND request->>'version'='1'
   AND request->>'teamID'=team_id::text AND request->>'operationID'=id::text
   AND jsonb_typeof(request->'vaults')='array' AND jsonb_array_length(request->'vaults')=(counts->>'vaults')::integer)
);
CREATE INDEX team_publication_operation_scope ON team_publication_operations(team_id,actor_user_id,actor_device_id,created_at);

CREATE TABLE team_publication_generations (
 operation_id uuid NOT NULL,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 attempt_id uuid NOT NULL UNIQUE,
 predecessor_id uuid NOT NULL,
 predecessor_hash text NOT NULL CHECK(predecessor_hash ~ '^[a-f0-9]{64}$'),
 sequence bigint NOT NULL CHECK(sequence>1),
 policy_version bigint NOT NULL CHECK(policy_version>0),
 PRIMARY KEY(operation_id,vault_id),
 FOREIGN KEY(operation_id,team_id) REFERENCES team_publication_operations(id,team_id),
 FOREIGN KEY(attempt_id,team_id,vault_id) REFERENCES vault_migration_attempts(id,team_id,vault_id),
 FOREIGN KEY(predecessor_id,team_id,vault_id) REFERENCES vault_migration_attempts(id,team_id,vault_id),
 CHECK(attempt_id<>predecessor_id)
);
CREATE INDEX team_publication_generation_predecessor ON team_publication_generations(team_id,vault_id,predecessor_id);

CREATE TABLE team_publication_receipts (
 operation_id uuid PRIMARY KEY,
 team_id uuid NOT NULL,
 body jsonb NOT NULL CHECK(jsonb_typeof(body)='object' AND octet_length(body::text)<=65536),
 FOREIGN KEY(operation_id,team_id) REFERENCES team_publication_operations(id,team_id)
);
CREATE TABLE team_publication_outbox (
 id bigserial PRIMARY KEY,
 operation_id uuid NOT NULL,
 team_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 resource_id uuid NOT NULL,
 membership_id uuid NOT NULL,
 user_id uuid NOT NULL,
 membership_epoch bigint NOT NULL CHECK(membership_epoch>0),
 before_mask integer NOT NULL CHECK(before_mask BETWEEN 0 AND 63),
 after_mask integer NOT NULL CHECK(after_mask BETWEEN 0 AND 63),
 delivered_at timestamptz,
 claimed_at timestamptz,
 claim_owner uuid,
 available_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(operation_id,vault_id,resource_id,membership_id),
 FOREIGN KEY(operation_id,team_id) REFERENCES team_publication_operations(id,team_id),
 FOREIGN KEY(vault_id,team_id) REFERENCES shared_vaults(id,team_id),
 CHECK(before_mask<>after_mask),
 CHECK((claimed_at IS NULL)=(claim_owner IS NULL))
);
CREATE INDEX team_publication_outbox_pending ON team_publication_outbox(available_at,id) WHERE delivered_at IS NULL;

CREATE FUNCTION guard_team_publication_operation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE linked integer;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_publication_operation'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.state<>'PREPARING' OR NOT EXISTS(SELECT 1 FROM devices WHERE id=NEW.actor_device_id AND user_id=NEW.actor_user_id)
   THEN RAISE EXCEPTION 'publication_scope_mismatch'; END IF;
  RETURN NEW;
 END IF;
 IF OLD.state IN('COMMITTED','DISCARDED') OR
 (to_jsonb(NEW)-ARRAY['state','checkpoint','committed_at']) IS DISTINCT FROM
 (to_jsonb(OLD)-ARRAY['state','checkpoint','committed_at']) THEN RAISE EXCEPTION 'immutable_publication_operation'; END IF;
 IF OLD.state='READY' AND (NEW.state NOT IN('READY','COMMITTED','DISCARDED') OR NEW.checkpoint IS DISTINCT FROM OLD.checkpoint)
  THEN RAISE EXCEPTION 'immutable_ready_publication'; END IF;
 IF NEW.state='COMMITTED' AND OLD.state<>'READY' THEN RAISE EXCEPTION 'publication_not_ready'; END IF;
 IF NEW.committed_at IS DISTINCT FROM OLD.committed_at AND NOT(OLD.state='READY' AND NEW.state='COMMITTED' AND NEW.committed_at IS NOT NULL)
  THEN RAISE EXCEPTION 'immutable_publication_operation'; END IF;
 IF NEW.state='READY' THEN
  SELECT count(*) INTO linked FROM team_publication_generations g JOIN vault_migration_attempts a ON a.id=g.attempt_id
    WHERE g.operation_id=NEW.id AND a.state='V2_READY';
  IF linked<>(NEW.counts->>'vaults')::integer OR EXISTS(SELECT 1 FROM shared_vaults v WHERE v.team_id=NEW.team_id
    AND v.archived_at IS NULL AND v.format_state='V2_ACTIVE' AND NOT EXISTS(SELECT 1 FROM team_publication_generations g
      WHERE g.operation_id=NEW.id AND g.vault_id=v.id AND g.predecessor_id=v.active_publication_attempt_id))
   THEN RAISE EXCEPTION 'publication_generations_incomplete'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_team_publication_operation BEFORE INSERT OR UPDATE OR DELETE ON team_publication_operations
 FOR EACH ROW EXECUTE FUNCTION guard_team_publication_operation();

CREATE FUNCTION guard_team_publication_generation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE operation team_publication_operations%ROWTYPE; candidate vault_migration_attempts%ROWTYPE;
 predecessor vault_publication_projections%ROWTYPE;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'immutable_publication_generation'; END IF;
 SELECT * INTO operation FROM team_publication_operations WHERE id=NEW.operation_id FOR UPDATE;
 SELECT * INTO candidate FROM vault_migration_attempts WHERE id=NEW.attempt_id;
 SELECT * INTO predecessor FROM vault_publication_projections WHERE attempt_id=NEW.predecessor_id;
 IF operation.state<>'PREPARING' OR operation.team_id IS DISTINCT FROM NEW.team_id
  OR (candidate.team_id,candidate.vault_id,candidate.actor_user_id,candidate.actor_device_id)
    IS DISTINCT FROM(NEW.team_id,NEW.vault_id,operation.actor_user_id,operation.actor_device_id)
  OR candidate.state<>'V2_PREPARING' OR (candidate.scope->>'policyVersion')::bigint IS DISTINCT FROM NEW.policy_version
  OR predecessor.team_id IS DISTINCT FROM NEW.team_id OR predecessor.vault_id IS DISTINCT FROM NEW.vault_id
  OR predecessor.header_hash IS DISTINCT FROM NEW.predecessor_hash
  OR (predecessor.projection->'header'->'payload'->>'sequence')::bigint+1 IS DISTINCT FROM NEW.sequence
  OR NOT EXISTS(SELECT 1 FROM shared_vaults v WHERE v.id=NEW.vault_id AND v.team_id=NEW.team_id
   AND v.format_state='V2_ACTIVE' AND v.active_publication_attempt_id=NEW.predecessor_id AND v.access_policy_version+1=NEW.policy_version)
  THEN RAISE EXCEPTION 'publication_scope_mismatch'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_team_publication_generation BEFORE INSERT OR UPDATE OR DELETE ON team_publication_generations
 FOR EACH ROW EXECUTE FUNCTION guard_team_publication_generation();

CREATE FUNCTION guard_team_publication_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE operation team_publication_operations%ROWTYPE;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'immutable_publication_receipt'; END IF;
 SELECT * INTO operation FROM team_publication_operations WHERE id=NEW.operation_id;
 IF operation.state IS DISTINCT FROM 'COMMITTED' THEN RAISE EXCEPTION 'publication_not_committed'; END IF;
 IF operation.team_id IS DISTINCT FROM NEW.team_id OR NEW.body->>'operationID' IS DISTINCT FROM operation.id::text
  OR NEW.body->>'teamID' IS DISTINCT FROM operation.team_id::text OR NEW.body->>'requestHash' IS DISTINCT FROM operation.request_hash
  OR NEW.body->>'actorAccountID' IS DISTINCT FROM operation.actor_user_id::text OR NEW.body->>'actorDeviceID' IS DISTINCT FROM operation.actor_device_id::text
  OR (NEW.body->>'committedAt')::timestamptz IS DISTINCT FROM operation.committed_at
  THEN RAISE EXCEPTION 'publication_receipt_scope_mismatch'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_team_publication_receipt BEFORE INSERT OR UPDATE OR DELETE ON team_publication_receipts
 FOR EACH ROW EXECUTE FUNCTION guard_team_publication_receipt();

CREATE FUNCTION guard_team_publication_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_publication_outbox'; END IF;
 IF TG_OP='INSERT' THEN
  IF NOT EXISTS(SELECT 1 FROM team_publication_operations WHERE id=NEW.operation_id AND team_id=NEW.team_id AND state='COMMITTED')
   THEN RAISE EXCEPTION 'publication_not_committed'; END IF;
 ELSE
  IF (to_jsonb(NEW)-ARRAY['delivered_at','claimed_at','claim_owner','available_at']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['delivered_at','claimed_at','claim_owner','available_at']) OR
     (OLD.delivered_at IS NOT NULL AND NEW.delivered_at IS DISTINCT FROM OLD.delivered_at)
   THEN RAISE EXCEPTION 'immutable_publication_outbox'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_team_publication_outbox BEFORE INSERT OR UPDATE OR DELETE ON team_publication_outbox
 FOR EACH ROW EXECUTE FUNCTION guard_team_publication_outbox();

-- Permit only a linked successor pointer; the deferred constraint below requires
-- every participant and its durable receipt in the same committed transaction.
CREATE OR REPLACE FUNCTION guard_active_migration_publication() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.active_publication_attempt_id IS NOT NULL THEN
  IF NEW.format_state<>'V2_ACTIVE' OR NEW.format_schema_version<>2 OR NEW.revision<>OLD.revision
    OR NEW.key_generation<>OLD.key_generation OR NEW.ciphertext IS NOT NULL THEN RAISE EXCEPTION 'irreversible_v2_publication'; END IF;
  IF NEW.active_publication_attempt_id IS DISTINCT FROM OLD.active_publication_attempt_id AND NOT EXISTS(
    SELECT 1 FROM team_publication_generations g JOIN team_publication_operations o ON o.id=g.operation_id
    WHERE g.attempt_id=NEW.active_publication_attempt_id AND g.predecessor_id=OLD.active_publication_attempt_id
      AND g.team_id=NEW.team_id AND g.vault_id=NEW.id AND g.policy_version=NEW.access_policy_version AND o.state IN('READY','COMMITTED'))
   THEN RAISE EXCEPTION 'irreversible_v2_publication'; END IF;
 END IF;
 IF NEW.active_publication_attempt_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM vault_migration_attempts
  WHERE id=NEW.active_publication_attempt_id AND team_id=NEW.team_id AND vault_id=NEW.id AND state='V2_ACTIVE')
  THEN RAISE EXCEPTION 'migration_not_active'; END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION check_whole_publication_commit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE operation_id_value uuid; operation team_publication_operations%ROWTYPE; expected jsonb; receipt jsonb; deltas jsonb;
BEGIN
 IF TG_TABLE_NAME='shared_vaults' THEN
  IF OLD.active_publication_attempt_id IS NULL OR NEW.active_publication_attempt_id IS NOT DISTINCT FROM OLD.active_publication_attempt_id THEN RETURN NULL; END IF;
  SELECT operation_id INTO operation_id_value FROM team_publication_generations WHERE attempt_id=NEW.active_publication_attempt_id;
 ELSE operation_id_value:=CASE WHEN TG_TABLE_NAME='team_publication_operations' THEN NEW.id ELSE NEW.operation_id END; END IF;
 SELECT * INTO operation FROM team_publication_operations WHERE id=operation_id_value;
 IF TG_TABLE_NAME='shared_vaults' AND operation.state IS DISTINCT FROM 'COMMITTED' THEN RAISE EXCEPTION 'publication_atomic_commit_incomplete'; END IF;
 IF operation.state<>'COMMITTED' THEN RETURN NULL; END IF;
 IF (SELECT count(*) FROM team_publication_generations WHERE operation_id=operation.id)<>(operation.counts->>'vaults')::integer
  OR EXISTS(SELECT 1 FROM team_publication_generations g
    JOIN shared_vaults v ON v.id=g.vault_id AND v.team_id=g.team_id JOIN vault_migration_attempts a ON a.id=g.attempt_id
    LEFT JOIN vault_publication_projections p ON p.attempt_id=a.id
    WHERE g.operation_id=operation.id AND (v.active_publication_attempt_id<>g.attempt_id OR a.state<>'V2_ACTIVE'
      OR v.access_policy_version<>g.policy_version OR p.attempt_id IS NULL
      OR (p.projection->'header'->'payload'->>'sequence')::bigint IS DISTINCT FROM g.sequence
      OR p.projection->'header'->'payload'->>'previousHash' IS DISTINCT FROM g.predecessor_hash))
  OR EXISTS(SELECT 1 FROM shared_vaults v WHERE v.team_id=operation.team_id AND v.archived_at IS NULL AND v.format_state='V2_ACTIVE'
    AND NOT EXISTS(SELECT 1 FROM team_publication_generations g WHERE g.operation_id=operation.id AND g.vault_id=v.id AND g.attempt_id=v.active_publication_attempt_id))
  THEN RAISE EXCEPTION 'publication_atomic_commit_incomplete'; END IF;
 SELECT jsonb_agg(jsonb_build_object('vaultID',g.vault_id,'generationID',g.attempt_id,'sequence',g.sequence,'headerHash',p.header_hash) ORDER BY g.vault_id)
  INTO expected FROM team_publication_generations g JOIN vault_publication_projections p ON p.attempt_id=g.attempt_id WHERE g.operation_id=operation.id;
 SELECT body INTO receipt FROM team_publication_receipts WHERE operation_id=operation.id;
 IF receipt IS NULL OR receipt->'vaults' IS DISTINCT FROM expected THEN RAISE EXCEPTION 'publication_atomic_commit_incomplete'; END IF;
 IF NOT EXISTS(SELECT 1 FROM team_audit_events WHERE team_id=operation.team_id AND actor_user_id=operation.actor_user_id
   AND action='vault_publication_committed' AND metadata->>'operationID'=operation.id::text)
  THEN RAISE EXCEPTION 'publication_atomic_commit_incomplete'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('vaultID',vault_id,'resourceID',resource_id,'membershipID',membership_id,
   'accountID',user_id,'membershipEpoch',membership_epoch,'beforeMask',before_mask,'afterMask',after_mask)
   ORDER BY vault_id,membership_id,resource_id),'[]'::jsonb) INTO deltas FROM team_publication_outbox WHERE operation_id=operation.id;
 IF deltas IS DISTINCT FROM operation.prepared->'plan'->'effectiveDeltas' THEN RAISE EXCEPTION 'publication_atomic_commit_incomplete'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER whole_publication_operation_complete AFTER UPDATE ON team_publication_operations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_whole_publication_commit();
CREATE CONSTRAINT TRIGGER whole_publication_pointer_complete AFTER UPDATE ON shared_vaults
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_whole_publication_commit();
CREATE CONSTRAINT TRIGGER whole_publication_receipt_complete AFTER INSERT ON team_publication_receipts
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_whole_publication_commit();

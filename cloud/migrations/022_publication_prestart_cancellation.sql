-- A confirmed discard must also fence a delayed START whose response was lost.
-- No production activation, existing Vault mutation or migration occurs here.
CREATE TABLE team_publication_operation_keys (
 operation_id uuid PRIMARY KEY,
 kind text NOT NULL CHECK(kind IN('OPERATION','CANCELLATION'))
);
INSERT INTO team_publication_operation_keys(operation_id,kind) SELECT id,'OPERATION' FROM team_publication_operations;
CREATE FUNCTION guard_publication_operation_key() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'immutable_publication_operation_key'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER publication_operation_key_immutable BEFORE INSERT OR UPDATE OR DELETE ON team_publication_operation_keys
 FOR EACH ROW EXECUTE FUNCTION guard_publication_operation_key();
CREATE TABLE team_publication_cancellations (
 operation_id uuid PRIMARY KEY REFERENCES team_publication_operation_keys(operation_id),
 team_id uuid NOT NULL REFERENCES teams(id),
 actor_user_id uuid NOT NULL REFERENCES users(id),
 actor_device_id uuid NOT NULL REFERENCES devices(id),
 confirmed_by_session uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION guard_publication_prestart_cancellation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'immutable_publication_cancellation'; END IF;
 -- Physical table locks arbitrate both absent-row insertion orders, including
 -- direct SQL. Deadlocks abort rather than permitting a cancellation bypass.
 LOCK TABLE team_publication_operations,team_publication_cancellations IN SHARE ROW EXCLUSIVE MODE;
 IF TG_TABLE_NAME='team_publication_operations' THEN
  IF EXISTS(SELECT 1 FROM team_publication_cancellations WHERE operation_id=NEW.id)
   THEN RAISE EXCEPTION 'publication_discarded'; END IF;
  -- Unique-key insertion also sees concurrent or newer committed rows that an
  -- old REPEATABLE READ snapshot cannot see. Table locking alone is insufficient.
  INSERT INTO team_publication_operation_keys(operation_id,kind) VALUES(NEW.id,'OPERATION');
 ELSE
  IF NOT EXISTS(SELECT 1 FROM devices WHERE id=NEW.actor_device_id AND user_id=NEW.actor_user_id)
   THEN RAISE EXCEPTION 'publication_scope_mismatch'; END IF;
  IF EXISTS(SELECT 1 FROM team_publication_operations WHERE id=NEW.operation_id)
   THEN RAISE EXCEPTION 'publication_operation_exists'; END IF;
  INSERT INTO team_publication_operation_keys(operation_id,kind) VALUES(NEW.operation_id,'CANCELLATION');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER publication_start_cancellation BEFORE INSERT ON team_publication_operations
 FOR EACH ROW EXECUTE FUNCTION guard_publication_prestart_cancellation();
CREATE TRIGGER publication_cancellation_immutable BEFORE INSERT OR UPDATE OR DELETE ON team_publication_cancellations
 FOR EACH ROW EXECUTE FUNCTION guard_publication_prestart_cancellation();

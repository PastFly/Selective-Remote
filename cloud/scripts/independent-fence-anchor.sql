-- Provision once on a separately administered durable PostgreSQL service.
-- Do not run on the application database or a database in the same rollback domain.
CREATE SCHEMA selective_remote_anchor;
REVOKE ALL ON SCHEMA selective_remote_anchor FROM PUBLIC;
CREATE TABLE selective_remote_anchor.heads (
 deployment_id uuid PRIMARY KEY,
 position bigint NOT NULL CHECK (position >= 0 AND position <= 9007199254740991),
 digest text NOT NULL CHECK (digest ~ '^[a-f0-9]{64}$')
);
REVOKE ALL ON selective_remote_anchor.heads FROM PUBLIC;
CREATE FUNCTION selective_remote_anchor.read_head(p_id uuid)
 RETURNS TABLE("position" bigint,digest text) LANGUAGE sql SECURITY DEFINER
 SET search_path = pg_catalog AS $$
 SELECT h.position,h.digest FROM selective_remote_anchor.heads AS h WHERE h.deployment_id=p_id
$$;
CREATE FUNCTION selective_remote_anchor.advance_head(p_id uuid,p_before bigint,p_before_digest text,p_after bigint,p_after_digest text)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE current_position bigint; current_digest text;
BEGIN
 IF p_id IS NULL OR p_before IS NULL OR p_after IS NULL OR p_before_digest IS NULL OR p_after_digest IS NULL
    OR p_before < 0 OR p_after <> p_before + 1 OR p_after > 9007199254740991
    OR p_before_digest !~ '^[a-f0-9]{64}$' OR p_after_digest !~ '^[a-f0-9]{64}$' THEN
  RAISE EXCEPTION 'invalid_deployment_anchor';
 END IF;
 SELECT h.position,h.digest INTO current_position,current_digest
  FROM selective_remote_anchor.heads AS h WHERE h.deployment_id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'deployment_anchor_unavailable'; END IF;
 IF current_position=p_after AND current_digest=p_after_digest THEN RETURN true; END IF;
 IF current_position<>p_before OR current_digest<>p_before_digest THEN RAISE EXCEPTION 'deployment_anchor_conflict'; END IF;
 PERFORM pg_catalog.set_config('synchronous_commit','on',true);
 UPDATE selective_remote_anchor.heads SET position=p_after,digest=p_after_digest WHERE deployment_id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION selective_remote_anchor.read_head(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION selective_remote_anchor.advance_head(uuid,bigint,text,bigint,text) FROM PUBLIC;

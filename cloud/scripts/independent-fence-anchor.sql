-- Provision once on a separately administered durable PostgreSQL primary.
-- The owner is trusted and must not be the application runtime identity.
CREATE SCHEMA selective_remote_anchor;
REVOKE ALL ON SCHEMA selective_remote_anchor FROM PUBLIC;
CREATE EXTENSION pgcrypto WITH SCHEMA selective_remote_anchor;
CREATE TABLE selective_remote_anchor.heads (
 singleton boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton),
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
CREATE FUNCTION selective_remote_anchor.advance_head(p_id uuid,p_before bigint,p_before_digest text,p_event text)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE current_position bigint; current_digest text; next_digest text; next_position bigint;
BEGIN
 IF p_id IS NULL OR p_before IS NULL OR p_before_digest IS NULL OR p_event IS NULL
    OR p_before < 0 OR p_before >= 9007199254740991 OR p_before_digest !~ '^[a-f0-9]{64}$'
    OR pg_catalog.octet_length(p_event)<2 OR pg_catalog.octet_length(p_event)>4194304
    OR pg_catalog.right(p_event,1) <> E'\n' THEN RAISE EXCEPTION 'invalid_deployment_anchor'; END IF;
 next_position := p_before + 1;
 next_digest := pg_catalog.encode(selective_remote_anchor.digest(
  pg_catalog.convert_to('selective-remote/fence-history/v1','UTF8') || pg_catalog.decode('00','hex') ||
  pg_catalog.decode(p_before_digest,'hex') || pg_catalog.int8send(next_position) || pg_catalog.convert_to(p_event,'UTF8'), 'sha256'),'hex');
 SELECT h.position,h.digest INTO current_position,current_digest
  FROM selective_remote_anchor.heads AS h WHERE h.deployment_id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'deployment_anchor_unavailable'; END IF;
 IF current_position=next_position AND current_digest=next_digest THEN RETURN true; END IF;
 IF current_position<>p_before OR current_digest<>p_before_digest THEN RAISE EXCEPTION 'deployment_anchor_conflict'; END IF;
 PERFORM pg_catalog.set_config('synchronous_commit','on',true);
 UPDATE selective_remote_anchor.heads SET position=next_position,digest=next_digest WHERE deployment_id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION selective_remote_anchor.read_head(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION selective_remote_anchor.advance_head(uuid,bigint,text,text) FROM PUBLIC;

-- Account-scoped approval state. All keys and challenges here are public or one-use proofs.
ALTER TABLE device_trust_certificates_v1 ADD COLUMN serial uuid;
ALTER TABLE device_trust_certificates_v1 ADD COLUMN certificate_json jsonb;
ALTER TABLE device_trust_directories_v1 ADD COLUMN directory_json jsonb;
ALTER TABLE device_trust_certificates_v1
    ADD CONSTRAINT device_trust_certificate_serial_unique UNIQUE (account_id, serial);

CREATE TABLE device_trust_requests_v1 (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES device_trust_roots_v1(account_id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    key_version bigint NOT NULL CHECK (key_version BETWEEN 1 AND 9007199254740991),
    public_key bytea NOT NULL CHECK (octet_length(public_key) = 65),
    public_key_json jsonb NOT NULL,
    key_digest bytea NOT NULL CHECK (octet_length(key_digest) = 32),
    state text NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'challenged', 'answered', 'approved', 'rejected', 'expired', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    decided_at timestamptz,
    approver_device_id uuid,
    certificate_serial uuid,
    FOREIGN KEY (account_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (account_id, approver_device_id) REFERENCES devices(user_id, id),
    UNIQUE (account_id, id),
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '1 day')
);

CREATE UNIQUE INDEX device_trust_one_open_request
    ON device_trust_requests_v1 (account_id, device_id)
    WHERE state IN ('pending', 'challenged', 'answered');
CREATE INDEX device_trust_pending_by_account
    ON device_trust_requests_v1 (account_id, created_at DESC)
    WHERE state IN ('pending', 'challenged', 'answered');

CREATE TABLE device_trust_challenges_v1 (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    request_id uuid NOT NULL,
    challenge_bytes bytea NOT NULL CHECK (octet_length(challenge_bytes) BETWEEN 1 AND 4096),
    challenge_json jsonb NOT NULL,
    proof bytea CHECK (proof IS NULL OR octet_length(proof) = 32),
    state text NOT NULL DEFAULT 'offered' CHECK (state IN ('offered', 'answered', 'consumed', 'expired')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    answered_at timestamptz,
    consumed_at timestamptz,
    FOREIGN KEY (account_id, request_id)
        REFERENCES device_trust_requests_v1(account_id, id) ON DELETE CASCADE,
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);
CREATE UNIQUE INDEX device_trust_one_live_challenge
    ON device_trust_challenges_v1 (account_id, request_id)
    WHERE state IN ('offered', 'answered');

CREATE TABLE device_trust_revocations_v1 (
    account_id uuid NOT NULL REFERENCES device_trust_roots_v1(account_id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    key_version bigint NOT NULL CHECK (key_version BETWEEN 1 AND 9007199254740991),
    checkpoint_version bigint NOT NULL CHECK (checkpoint_version BETWEEN 1 AND 9007199254740991),
    revoked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id, key_version),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);

CREATE TABLE device_trust_account_events_v1 (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    actor_device_id uuid,
    target_device_id uuid NOT NULL,
    action text NOT NULL CHECK (action IN
        ('device.pending', 'device.approved', 'device.rejected',
         'device.revoked', 'device.rekey_requested', 'device.rekey_approved')),
    key_version bigint CHECK (key_version BETWEEN 1 AND 9007199254740991),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX device_trust_account_events_scope
    ON device_trust_account_events_v1 (account_id, id DESC);

CREATE TABLE device_trust_mutation_receipts_v1 (
    account_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation text NOT NULL CHECK (char_length(operation) BETWEEN 1 AND 64),
    idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 1 AND 160),
    response jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, operation, idempotency_key)
);

CREATE TRIGGER immutable_device_trust_revocation_v1
    BEFORE UPDATE ON device_trust_revocations_v1
    FOR EACH ROW EXECUTE FUNCTION reject_device_trust_signed_record_update();
CREATE TRIGGER immutable_device_trust_event_v1
    BEFORE UPDATE ON device_trust_account_events_v1
    FOR EACH ROW EXECUTE FUNCTION reject_device_trust_signed_record_update();

-- Serializes version allocation even for direct SQL writers using the account root row.
CREATE FUNCTION require_next_device_directory_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE next_version bigint;
BEGIN
    PERFORM 1 FROM device_trust_roots_v1 WHERE account_id = NEW.account_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'device_trust_root_missing'; END IF;
    SELECT COALESCE(MAX(version), 0) + 1 INTO next_version
      FROM device_trust_directories_v1 WHERE account_id = NEW.account_id;
    IF NEW.version <> next_version THEN RAISE EXCEPTION 'stale_device_directory'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER device_trust_directory_monotonic_v1
    BEFORE INSERT ON device_trust_directories_v1
    FOR EACH ROW EXECUTE FUNCTION require_next_device_directory_version();

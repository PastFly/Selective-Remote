-- Dormant public signed-record carrier. No HTTP route or production writer uses these tables.
-- The server stores bytes but does not authenticate device keys for clients.
CREATE TABLE device_trust_roots_v1 (
    account_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    root_public_key bytea NOT NULL CHECK (octet_length(root_public_key) = 65),
    fingerprint bytea NOT NULL CHECK (octet_length(fingerprint) = 32),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE device_trust_certificates_v1 (
    account_id uuid NOT NULL,
    device_id uuid NOT NULL,
    key_version bigint NOT NULL CHECK (key_version BETWEEN 1 AND 9007199254740991),
    certificate_bytes bytea NOT NULL CHECK (octet_length(certificate_bytes) BETWEEN 1 AND 4096),
    signature bytea NOT NULL CHECK (octet_length(signature) = 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id, key_version),
    FOREIGN KEY (account_id) REFERENCES device_trust_roots_v1(account_id) ON DELETE CASCADE,
    FOREIGN KEY (account_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);

CREATE TABLE device_trust_directories_v1 (
    account_id uuid NOT NULL REFERENCES device_trust_roots_v1(account_id) ON DELETE CASCADE,
    version bigint NOT NULL CHECK (version BETWEEN 1 AND 9007199254740991),
    directory_bytes bytea NOT NULL CHECK (octet_length(directory_bytes) BETWEEN 1 AND 65535),
    signature bytea NOT NULL CHECK (octet_length(signature) = 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, version)
);

CREATE FUNCTION reject_device_trust_signed_record_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'immutable_device_trust_record';
END;
$$;

CREATE TRIGGER immutable_device_trust_root_v1 BEFORE UPDATE ON device_trust_roots_v1
    FOR EACH ROW EXECUTE FUNCTION reject_device_trust_signed_record_update();
CREATE TRIGGER immutable_device_trust_certificate_v1 BEFORE UPDATE ON device_trust_certificates_v1
    FOR EACH ROW EXECUTE FUNCTION reject_device_trust_signed_record_update();
CREATE TRIGGER immutable_device_trust_directory_v1 BEFORE UPDATE ON device_trust_directories_v1
    FOR EACH ROW EXECUTE FUNCTION reject_device_trust_signed_record_update();

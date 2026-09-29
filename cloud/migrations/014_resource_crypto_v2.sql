-- Dormant per-resource ciphertext and wrapper storage. No public route writes these tables.
-- V1_ACTIVE remains the default for every existing and new Vault.
CREATE TABLE vault_resource_ciphertext_versions (
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    part text NOT NULL CHECK (part IN ('GENERAL', 'METADATA', 'SECRET')),
    key_version bigint NOT NULL CHECK (key_version > 0),
    format_version integer NOT NULL DEFAULT 2 CHECK (format_version = 2),
    algorithm text NOT NULL DEFAULT 'AES-256-GCM' CHECK (algorithm = 'AES-256-GCM'),
    aad_version integer NOT NULL DEFAULT 2 CHECK (aad_version = 2),
    policy_version bigint NOT NULL CHECK (policy_version > 0),
    registry_version bigint NOT NULL CHECK (registry_version > 0),
    resource_version bigint NOT NULL CHECK (resource_version > 0),
    manifest_version bigint NOT NULL CHECK (manifest_version > 0),
    nonce text NOT NULL CHECK (length(nonce) = 16),
    ciphertext text NOT NULL CHECK (length(ciphertext) BETWEEN 0 AND 33554432),
    auth_tag text NOT NULL CHECK (length(auth_tag) = 22),
    lifecycle text NOT NULL DEFAULT 'PREPARED'
        CHECK (lifecycle IN ('PREPARED', 'PUBLISHED', 'OBSOLETE')),
    created_at timestamptz NOT NULL DEFAULT now(),
    obsolete_at timestamptz,
    PRIMARY KEY (team_id, vault_id, resource_id, part, key_version),
    FOREIGN KEY (team_id, vault_id, resource_id)
        REFERENCES vault_resource_registry(team_id, vault_id, id) ON DELETE CASCADE,
    CHECK ((lifecycle = 'OBSOLETE') = (obsolete_at IS NOT NULL))
);

CREATE TABLE vault_resource_key_wrappers_v2 (
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    part text NOT NULL,
    key_version bigint NOT NULL,
    membership_id uuid NOT NULL,
    membership_epoch bigint NOT NULL CHECK (membership_epoch > 0),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    wrapper_version integer NOT NULL DEFAULT 2 CHECK (wrapper_version = 2),
    algorithm text NOT NULL DEFAULT 'P256-ECDH-HKDF-SHA256-AES-256-GCM'
        CHECK (algorithm = 'P256-ECDH-HKDF-SHA256-AES-256-GCM'),
    aad_version integer NOT NULL DEFAULT 2 CHECK (aad_version = 2),
    ephemeral_public_key jsonb NOT NULL,
    nonce text NOT NULL CHECK (length(nonce) = 16),
    ciphertext text NOT NULL CHECK (length(ciphertext) = 43),
    auth_tag text NOT NULL CHECK (length(auth_tag) = 22),
    created_at timestamptz NOT NULL DEFAULT now(),
    obsolete_at timestamptz,
    PRIMARY KEY (team_id, vault_id, resource_id, part, key_version,
                 membership_id, membership_epoch, device_id),
    FOREIGN KEY (team_id, vault_id, resource_id, part, key_version)
        REFERENCES vault_resource_ciphertext_versions
            (team_id, vault_id, resource_id, part, key_version) ON DELETE CASCADE,
    FOREIGN KEY (membership_id, membership_epoch)
        REFERENCES team_memberships(id, epoch) ON DELETE CASCADE
);

CREATE TABLE vault_resource_manifest_pointers_v2 (
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    part text NOT NULL,
    key_version bigint NOT NULL,
    manifest_version bigint NOT NULL CHECK (manifest_version > 0),
    published_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, vault_id, resource_id, part),
    FOREIGN KEY (team_id, vault_id, resource_id, part, key_version)
        REFERENCES vault_resource_ciphertext_versions
            (team_id, vault_id, resource_id, part, key_version) ON DELETE RESTRICT
);

CREATE FUNCTION require_dormant_resource_crypto_v2() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared_vaults AS vault
        JOIN vault_resource_registry AS resource
          ON resource.team_id = vault.team_id AND resource.vault_id = vault.id
         AND resource.id = NEW.resource_id AND resource.deleted_at IS NULL
        WHERE vault.team_id = NEW.team_id AND vault.id = NEW.vault_id
          AND vault.archived_at IS NULL
          AND vault.format_state = 'V2_PREPARING' AND vault.format_schema_version = 2
        FOR UPDATE OF resource FOR SHARE OF vault
    ) THEN
        RAISE EXCEPTION 'resource_v2_preparing_required';
    END IF;
    IF TG_TABLE_NAME = 'vault_resource_key_wrappers_v2' THEN
        -- Revoked recipients must still permit old wrappers to be marked obsolete.
        IF TG_OP = 'INSERT' THEN
            IF NOT EXISTS (
                SELECT 1 FROM team_memberships AS membership
                JOIN devices AS device ON device.id = NEW.device_id
                  AND device.user_id = membership.user_id AND device.revoked_at IS NULL
                JOIN team_membership_device_admissions AS admission
                  ON admission.membership_id = membership.id
                 AND admission.membership_epoch = membership.epoch
                 AND admission.device_id = device.id
                WHERE membership.id = NEW.membership_id
                  AND membership.team_id = NEW.team_id
                  AND membership.epoch = NEW.membership_epoch
                  AND membership.revoked_at IS NULL
                  AND device.public_key IS NOT NULL
                  AND device.public_key_algorithm = 'p256-ecdh-v1'
                FOR SHARE OF membership, device, admission
            ) THEN
                RAISE EXCEPTION 'resource_v2_current_epoch_admission_required';
            END IF;
        ELSE
            IF to_jsonb(NEW) - 'obsolete_at' <> to_jsonb(OLD) - 'obsolete_at'
               OR OLD.obsolete_at IS NOT NULL OR NEW.obsolete_at IS NULL THEN
                RAISE EXCEPTION 'immutable_resource_v2_wrapper';
            END IF;
            IF EXISTS (
                SELECT 1 FROM vault_resource_manifest_pointers_v2 AS pointer
                WHERE pointer.team_id = NEW.team_id AND pointer.vault_id = NEW.vault_id
                  AND pointer.resource_id = NEW.resource_id AND pointer.part = NEW.part
                  AND pointer.key_version = NEW.key_version
            ) AND NOT EXISTS (
                SELECT 1 FROM vault_resource_key_wrappers_v2 AS sibling
                WHERE sibling.team_id = NEW.team_id AND sibling.vault_id = NEW.vault_id
                  AND sibling.resource_id = NEW.resource_id AND sibling.part = NEW.part
                  AND sibling.key_version = NEW.key_version
                  AND sibling.obsolete_at IS NULL
                  AND (sibling.membership_id, sibling.membership_epoch, sibling.device_id)
                    <> (NEW.membership_id, NEW.membership_epoch, NEW.device_id)
            ) THEN
                RAISE EXCEPTION 'resource_v2_last_published_wrapper';
            END IF;
        END IF;
    ELSIF TG_TABLE_NAME = 'vault_resource_ciphertext_versions' THEN
        IF TG_OP = 'UPDATE' THEN
            IF to_jsonb(NEW) - 'lifecycle' - 'obsolete_at'
               <> to_jsonb(OLD) - 'lifecycle' - 'obsolete_at'
               OR NOT ((OLD.lifecycle = 'PREPARED' AND NEW.lifecycle = 'PUBLISHED'
                        AND NEW.obsolete_at IS NULL)
                       OR (OLD.lifecycle = 'PUBLISHED' AND NEW.lifecycle = 'OBSOLETE'
                           AND NEW.obsolete_at IS NOT NULL)) THEN
                RAISE EXCEPTION 'immutable_resource_v2_ciphertext';
            END IF;
            IF NEW.lifecycle = 'OBSOLETE' AND EXISTS (
                SELECT 1 FROM vault_resource_manifest_pointers_v2 AS pointer
                WHERE pointer.team_id = NEW.team_id AND pointer.vault_id = NEW.vault_id
                  AND pointer.resource_id = NEW.resource_id AND pointer.part = NEW.part
                  AND pointer.key_version = NEW.key_version
            ) THEN
                RAISE EXCEPTION 'resource_v2_published_ciphertext_in_use';
            END IF;
        END IF;
    ELSIF TG_TABLE_NAME = 'vault_resource_manifest_pointers_v2' THEN
        IF NOT EXISTS (
            SELECT 1 FROM vault_resource_ciphertext_versions AS ciphertext_version
            JOIN vault_resource_key_wrappers_v2 AS wrapper
              ON wrapper.team_id = ciphertext_version.team_id
             AND wrapper.vault_id = ciphertext_version.vault_id
             AND wrapper.resource_id = ciphertext_version.resource_id
             AND wrapper.part = ciphertext_version.part
             AND wrapper.key_version = ciphertext_version.key_version
             AND wrapper.obsolete_at IS NULL
            WHERE ciphertext_version.team_id = NEW.team_id
              AND ciphertext_version.vault_id = NEW.vault_id
              AND ciphertext_version.resource_id = NEW.resource_id
              AND ciphertext_version.part = NEW.part
              AND ciphertext_version.key_version = NEW.key_version
              AND ciphertext_version.manifest_version = NEW.manifest_version
              AND ciphertext_version.lifecycle = 'PREPARED'
        ) THEN
            RAISE EXCEPTION 'resource_v2_wrapper_required';
        END IF;
        IF TG_OP = 'UPDATE' THEN
            IF NEW.team_id <> OLD.team_id OR NEW.vault_id <> OLD.vault_id
               OR NEW.resource_id <> OLD.resource_id OR NEW.part <> OLD.part
               OR NEW.key_version <> OLD.key_version + 1
               OR NEW.manifest_version <> OLD.manifest_version + 1 THEN
                RAISE EXCEPTION 'invalid_resource_v2_manifest_advance';
            END IF;
        ELSIF NEW.key_version <> 1 OR NEW.manifest_version <> 1 THEN
            RAISE EXCEPTION 'invalid_resource_v2_manifest_initial';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER resource_v2_ciphertext_guard
    BEFORE INSERT OR UPDATE ON vault_resource_ciphertext_versions
    FOR EACH ROW EXECUTE FUNCTION require_dormant_resource_crypto_v2();
CREATE TRIGGER resource_v2_wrapper_guard
    BEFORE INSERT OR UPDATE ON vault_resource_key_wrappers_v2
    FOR EACH ROW EXECUTE FUNCTION require_dormant_resource_crypto_v2();
CREATE TRIGGER resource_v2_manifest_guard
    BEFORE INSERT OR UPDATE ON vault_resource_manifest_pointers_v2
    FOR EACH ROW EXECUTE FUNCTION require_dormant_resource_crypto_v2();

-- Serialize dormant resource mutations, including direct SQL, on the parent Vault row.
-- The existing guards run after these a_* triggers and use fresh READ COMMITTED reads.
-- A direct SQL UPDATE may acquire its target row before the Vault and deadlock with a
-- store transaction. PostgreSQL aborts one transaction; callers must retry the entire
-- operation with fresh version preconditions. No production mutation route exists.
CREATE TABLE vault_resource_mutation_receipts_v2 (
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200),
    operation text NOT NULL CHECK (operation IN
        ('create_identity', 'move_identity', 'tombstone_identity', 'publish_crypto',
         'revoke_wrapper')),
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, vault_id, idempotency_key),
    FOREIGN KEY (vault_id, team_id) REFERENCES shared_vaults(id, team_id) ON DELETE CASCADE
);

CREATE INDEX vault_resource_wrappers_v2_active_version
    ON vault_resource_key_wrappers_v2
       (team_id, vault_id, resource_id, part, key_version,
        membership_id, membership_epoch, device_id)
    WHERE obsolete_at IS NULL;
CREATE INDEX vault_resource_wrappers_v2_active_device
    ON vault_resource_key_wrappers_v2 (device_id, membership_id, membership_epoch)
    WHERE obsolete_at IS NULL;

CREATE FUNCTION serialize_resource_registry_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE scope_row record;
BEGIN
    IF TG_OP = 'DELETE' THEN scope_row := OLD; ELSE scope_row := NEW; END IF;
    PERFORM 1 FROM shared_vaults
     WHERE id = scope_row.vault_id AND team_id = scope_row.team_id FOR UPDATE;
    IF TG_OP = 'DELETE' THEN
        -- Permit FK cascade only after the parent Vault has gone in this transaction.
        IF FOUND THEN RAISE EXCEPTION 'resource_identity_hard_delete_forbidden'; END IF;
        RETURN OLD;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'resource_vault_missing'; END IF;
    IF NOT EXISTS (SELECT 1 FROM shared_vaults
                   WHERE id = scope_row.vault_id AND team_id = scope_row.team_id
                     AND format_state = 'V2_PREPARING' AND format_schema_version = 2) THEN
        RAISE EXCEPTION 'resource_v2_preparing_required';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        -- Every registry UPDATE advances resource_version. A current ciphertext
        -- remains bound to the old version until an atomic rotation replaces it.
        IF EXISTS (SELECT 1 FROM vault_resource_manifest_pointers_v2
                   WHERE team_id = OLD.team_id AND vault_id = OLD.vault_id
                     AND resource_id = OLD.id) THEN
            RAISE EXCEPTION 'resource_v2_published_identity_in_use';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER a_resource_registry_serialization
    BEFORE INSERT OR UPDATE OR DELETE ON vault_resource_registry
    FOR EACH ROW EXECUTE FUNCTION serialize_resource_registry_mutation();

CREATE FUNCTION serialize_resource_crypto_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE scope_row record;
BEGIN
    IF TG_OP = 'DELETE' THEN scope_row := OLD; ELSE scope_row := NEW; END IF;
    PERFORM 1 FROM shared_vaults
     WHERE id = scope_row.vault_id AND team_id = scope_row.team_id FOR UPDATE;
    IF TG_OP = 'DELETE' THEN
        IF FOUND AND TG_TABLE_NAME = 'vault_resource_key_wrappers_v2' THEN
            IF OLD.obsolete_at IS NULL AND EXISTS (
                SELECT 1 FROM vault_resource_manifest_pointers_v2 AS pointer
                 WHERE pointer.team_id = OLD.team_id AND pointer.vault_id = OLD.vault_id
                   AND pointer.resource_id = OLD.resource_id AND pointer.part = OLD.part
                   AND pointer.key_version = OLD.key_version
            ) THEN
                RAISE EXCEPTION 'resource_v2_published_wrapper_delete_forbidden';
            END IF;
        END IF;
        IF FOUND AND TG_TABLE_NAME <> 'vault_resource_key_wrappers_v2' THEN
            -- A Vault returned to legacy V1 can discard its dormant pointer.
            -- Registry tombstones and ciphertext history still cannot be erased.
            IF TG_TABLE_NAME <> 'vault_resource_manifest_pointers_v2'
               OR NOT EXISTS (SELECT 1 FROM shared_vaults
                               WHERE id = OLD.vault_id AND team_id = OLD.team_id
                                 AND format_state = 'V1_ACTIVE'
                                 AND format_schema_version = 1) THEN
                RAISE EXCEPTION 'resource_v2_hard_delete_forbidden';
            END IF;
        END IF;
        RETURN OLD;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'resource_vault_missing'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER a_resource_v2_ciphertext_serialization
    BEFORE INSERT OR UPDATE OR DELETE ON vault_resource_ciphertext_versions
    FOR EACH ROW EXECUTE FUNCTION serialize_resource_crypto_mutation();
CREATE TRIGGER a_resource_v2_wrapper_serialization
    BEFORE INSERT OR UPDATE OR DELETE ON vault_resource_key_wrappers_v2
    FOR EACH ROW EXECUTE FUNCTION serialize_resource_crypto_mutation();
CREATE TRIGGER a_resource_v2_manifest_serialization
    BEFORE INSERT OR UPDATE OR DELETE ON vault_resource_manifest_pointers_v2
    FOR EACH ROW EXECUTE FUNCTION serialize_resource_crypto_mutation();

-- Admission and publication share the Vault lock. Once a pointer exists, a new
-- recipient needs a future atomic wrapper-provisioning API; direct admission fails.
CREATE FUNCTION serialize_resource_device_admission() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE membership_team uuid; vault_row record;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.membership_id, NEW.membership_epoch, NEW.device_id)
           IS DISTINCT FROM (OLD.membership_id, OLD.membership_epoch, OLD.device_id) THEN
            RAISE EXCEPTION 'resource_v2_admission_identity_immutable';
        END IF;
        RETURN NEW;
    END IF;
    SELECT team_id INTO membership_team FROM team_memberships
     WHERE id = NEW.membership_id AND epoch = NEW.membership_epoch;
    FOR vault_row IN SELECT id FROM shared_vaults
      WHERE team_id = membership_team AND format_state = 'V2_PREPARING'
      ORDER BY id LOOP
        PERFORM 1 FROM shared_vaults WHERE id = vault_row.id FOR UPDATE;
        IF EXISTS (SELECT 1 FROM vault_resource_manifest_pointers_v2
                    WHERE vault_id = vault_row.id) THEN
            RAISE EXCEPTION 'resource_v2_admission_requires_rotation';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER a_resource_device_admission_serialization
    BEFORE INSERT OR UPDATE ON team_membership_device_admissions
    FOR EACH ROW EXECUTE FUNCTION serialize_resource_device_admission();

-- Recipient identity and key material cannot be changed while an admitted
-- device has a live wrapper. Key rotation first retires the admission in the
-- same transaction; a later admission after publication requires rotation.
CREATE FUNCTION guard_resource_recipient_state() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'devices' THEN
        IF NEW.id <> OLD.id OR NEW.user_id <> OLD.user_id THEN
            RAISE EXCEPTION 'device_identity_immutable';
        END IF;
        IF (NEW.public_key IS DISTINCT FROM OLD.public_key
            OR NEW.public_key_algorithm IS DISTINCT FROM OLD.public_key_algorithm)
           AND EXISTS (
                SELECT 1 FROM vault_resource_key_wrappers_v2 AS wrapper
                JOIN team_membership_device_admissions AS admission
                  ON admission.membership_id = wrapper.membership_id
                 AND admission.membership_epoch = wrapper.membership_epoch
                 AND admission.device_id = wrapper.device_id
                WHERE wrapper.device_id = OLD.id AND wrapper.obsolete_at IS NULL
           ) THEN
            RAISE EXCEPTION 'resource_v2_device_key_in_use';
        END IF;
    ELSE
        IF (NEW.id, NEW.team_id, NEW.user_id, NEW.epoch)
           IS DISTINCT FROM (OLD.id, OLD.team_id, OLD.user_id, OLD.epoch) THEN
            RAISE EXCEPTION 'membership_identity_immutable';
        END IF;
    END IF;
    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS NULL THEN
        IF TG_TABLE_NAME = 'devices' THEN
            RAISE EXCEPTION 'device_revocation_irreversible';
        END IF;
        RAISE EXCEPTION 'membership_revocation_irreversible';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER a_device_resource_identity_guard
    BEFORE UPDATE OF id, user_id, public_key, public_key_algorithm, revoked_at ON devices
    FOR EACH ROW EXECUTE FUNCTION guard_resource_recipient_state();
CREATE TRIGGER a_membership_resource_identity_guard
    BEFORE UPDATE OF id, team_id, user_id, epoch, revoked_at ON team_memberships
    FOR EACH ROW EXECUTE FUNCTION guard_resource_recipient_state();

-- Publication can only point at a fully promoted ciphertext. The store promotes
-- inside the same transaction before moving the pointer, preserving atomicity.
CREATE OR REPLACE FUNCTION require_dormant_resource_crypto_v2() RETURNS trigger LANGUAGE plpgsql AS $$
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
                JOIN team_memberships AS membership ON membership.id = OLD.membership_id
                  AND membership.epoch = OLD.membership_epoch AND membership.revoked_at IS NULL
                JOIN devices AS device ON device.id = OLD.device_id
                  AND device.user_id = membership.user_id AND device.revoked_at IS NULL
                JOIN team_membership_device_admissions AS admission
                  ON admission.membership_id = membership.id
                 AND admission.membership_epoch = membership.epoch
                 AND admission.device_id = device.id
                WHERE pointer.team_id = OLD.team_id AND pointer.vault_id = OLD.vault_id
                  AND pointer.resource_id = OLD.resource_id AND pointer.part = OLD.part
                  AND pointer.key_version = OLD.key_version
            ) THEN
                RAISE EXCEPTION 'resource_v2_published_wrapper_coverage';
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
            JOIN vault_resource_registry AS current_resource
              ON current_resource.team_id = ciphertext_version.team_id
             AND current_resource.vault_id = ciphertext_version.vault_id
             AND current_resource.id = ciphertext_version.resource_id
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
              AND ciphertext_version.lifecycle = 'PUBLISHED'
              AND ciphertext_version.registry_version = current_resource.resource_version
        ) THEN
            RAISE EXCEPTION 'resource_v2_published_ciphertext_required';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM vault_resource_key_wrappers_v2 AS wrapper
            JOIN team_memberships AS membership
              ON membership.id = wrapper.membership_id
             AND membership.team_id = wrapper.team_id
             AND membership.epoch = wrapper.membership_epoch
             AND membership.revoked_at IS NULL
            JOIN devices AS device ON device.id = wrapper.device_id
             AND device.user_id = membership.user_id
             AND device.revoked_at IS NULL
             AND device.public_key IS NOT NULL
             AND device.public_key_algorithm = 'p256-ecdh-v1'
            JOIN team_membership_device_admissions AS admission
              ON admission.membership_id = membership.id
             AND admission.membership_epoch = membership.epoch
             AND admission.device_id = device.id
            WHERE wrapper.team_id = NEW.team_id AND wrapper.vault_id = NEW.vault_id
              AND wrapper.resource_id = NEW.resource_id AND wrapper.part = NEW.part
              AND wrapper.key_version = NEW.key_version AND wrapper.obsolete_at IS NULL
            FOR SHARE OF membership, device, admission
        ) THEN
            RAISE EXCEPTION 'resource_v2_eligible_wrapper_required';
        END IF;
        IF EXISTS (
            SELECT 1 FROM team_memberships AS membership
            JOIN team_membership_device_admissions AS admission
              ON admission.membership_id = membership.id
             AND admission.membership_epoch = membership.epoch
            JOIN devices AS device ON device.id = admission.device_id
             AND device.user_id = membership.user_id AND device.revoked_at IS NULL
             AND device.public_key IS NOT NULL
             AND device.public_key_algorithm = 'p256-ecdh-v1'
            WHERE membership.team_id = NEW.team_id AND membership.revoked_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM vault_resource_key_wrappers_v2 AS wrapper
                 WHERE wrapper.team_id = NEW.team_id AND wrapper.vault_id = NEW.vault_id
                   AND wrapper.resource_id = NEW.resource_id AND wrapper.part = NEW.part
                   AND wrapper.key_version = NEW.key_version
                   AND wrapper.membership_id = membership.id
                   AND wrapper.membership_epoch = membership.epoch
                   AND wrapper.device_id = device.id AND wrapper.obsolete_at IS NULL
              )
        ) THEN
            RAISE EXCEPTION 'resource_v2_wrapper_coverage_incomplete';
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

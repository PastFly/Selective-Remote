ALTER TABLE devices
    ADD COLUMN public_key_algorithm text,
    ADD COLUMN key_registered_at timestamptz,
    ADD COLUMN key_approved_at timestamptz,
    ADD COLUMN key_approved_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    ADD CONSTRAINT devices_team_key_complete CHECK (
        (public_key IS NULL AND public_key_algorithm IS NULL AND key_registered_at IS NULL
          AND key_approved_at IS NULL AND key_approved_by_device_id IS NULL)
        OR
        (public_key IS NOT NULL AND public_key_algorithm IS NULL AND key_registered_at IS NULL
          AND key_approved_at IS NULL AND key_approved_by_device_id IS NULL)
        OR
        (public_key IS NOT NULL AND public_key_algorithm = 'p256-ecdh-v1'
          AND key_registered_at IS NOT NULL
          AND ((key_approved_at IS NULL AND key_approved_by_device_id IS NULL)
            OR key_approved_at IS NOT NULL))
    );

ALTER TABLE shared_vaults
    ADD COLUMN envelope_version integer,
    ADD COLUMN ciphertext text,
    ADD COLUMN nonce text,
    ADD COLUMN auth_tag text,
    ADD COLUMN content_hash text,
    ADD COLUMN updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    ADD CONSTRAINT shared_vault_payload_complete CHECK (
        (revision = 0 AND envelope_version IS NULL AND ciphertext IS NULL AND nonce IS NULL
          AND auth_tag IS NULL AND content_hash IS NULL AND updated_by_device_id IS NULL)
        OR
        (revision > 0 AND envelope_version = 1 AND ciphertext IS NOT NULL AND nonce IS NOT NULL
          AND auth_tag IS NOT NULL AND content_hash IS NOT NULL AND updated_by_device_id IS NOT NULL)
    );

CREATE TABLE shared_vault_revisions (
    vault_id uuid NOT NULL REFERENCES shared_vaults(id) ON DELETE CASCADE,
    revision bigint NOT NULL CHECK (revision > 0),
    key_generation bigint NOT NULL CHECK (key_generation > 0),
    envelope_version integer NOT NULL CHECK (envelope_version = 1),
    ciphertext text NOT NULL,
    nonce text NOT NULL,
    auth_tag text NOT NULL,
    content_hash text NOT NULL,
    updated_by_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (vault_id, revision)
);

CREATE UNIQUE INDEX team_memberships_id_epoch
    ON team_memberships (id, epoch);

CREATE TABLE shared_vault_key_wrappers (
    vault_id uuid NOT NULL REFERENCES shared_vaults(id) ON DELETE CASCADE,
    key_generation bigint NOT NULL CHECK (key_generation > 0),
    membership_id uuid NOT NULL,
    membership_epoch bigint NOT NULL CHECK (membership_epoch > 0),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    wrapper_version integer NOT NULL CHECK (wrapper_version = 1),
    ephemeral_public_key jsonb NOT NULL,
    ciphertext text NOT NULL,
    nonce text NOT NULL,
    auth_tag text NOT NULL,
    context_hash text NOT NULL,
    created_by_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (vault_id, key_generation, device_id),
    FOREIGN KEY (membership_id, membership_epoch)
        REFERENCES team_memberships(id, epoch) ON DELETE CASCADE,
    CONSTRAINT shared_vault_wrapper_context_hash CHECK (context_hash ~ '^[A-Za-z0-9_-]{43}$'),
    CONSTRAINT shared_vault_wrapper_envelope_shape CHECK (
        jsonb_typeof(ephemeral_public_key) = 'object'
        AND ciphertext ~ '^[A-Za-z0-9_-]{43}$'
        AND nonce ~ '^[A-Za-z0-9_-]{16}$'
        AND auth_tag ~ '^[A-Za-z0-9_-]{22}$'
    )
);

CREATE INDEX shared_vault_key_wrappers_device
    ON shared_vault_key_wrappers (device_id, vault_id, key_generation);

ALTER TABLE shared_vault_rotation_tasks
    ALTER COLUMN removed_membership_id DROP NOT NULL,
    ADD COLUMN removed_device_id uuid REFERENCES devices(id) ON DELETE CASCADE,
    ADD CONSTRAINT shared_vault_rotation_subject CHECK (
        (removed_membership_id IS NOT NULL)::integer + (removed_device_id IS NOT NULL)::integer = 1
    );

CREATE UNIQUE INDEX shared_vault_rotation_tasks_device_unique
    ON shared_vault_rotation_tasks (vault_id, from_generation, removed_device_id)
    WHERE removed_device_id IS NOT NULL;

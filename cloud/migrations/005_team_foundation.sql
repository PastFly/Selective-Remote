CREATE TABLE teams (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    CONSTRAINT teams_name_bounded CHECK (
        name = trim(name) AND char_length(name) BETWEEN 1 AND 120
    )
);

CREATE TABLE team_memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
    epoch bigint NOT NULL DEFAULT 1 CHECK (epoch > 0),
    joined_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    revoked_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    UNIQUE (team_id, user_id, epoch),
    CONSTRAINT team_membership_revocation_complete CHECK (
        (revoked_at IS NULL AND revoked_by_user_id IS NULL)
        OR revoked_at IS NOT NULL
    )
);

CREATE UNIQUE INDEX team_memberships_one_active_user
    ON team_memberships (team_id, user_id) WHERE revoked_at IS NULL;
CREATE INDEX team_memberships_active_user
    ON team_memberships (user_id, team_id) WHERE revoked_at IS NULL;

CREATE TABLE team_invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    email text NOT NULL,
    role text NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
    token_hash text NOT NULL UNIQUE,
    invited_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    accepted_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    cancelled_at timestamptz,
    cancelled_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT team_invitation_email_normalized CHECK (email = lower(trim(email))),
    CONSTRAINT team_invitation_token_hash CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT team_invitation_expiry_order CHECK (expires_at > created_at),
    CONSTRAINT team_invitation_terminal_state CHECK (
        NOT (accepted_at IS NOT NULL AND cancelled_at IS NOT NULL)
        AND ((accepted_at IS NULL AND accepted_by_user_id IS NULL)
          OR (accepted_at IS NOT NULL AND accepted_by_user_id IS NOT NULL))
        AND ((cancelled_at IS NULL AND cancelled_by_user_id IS NULL)
          OR cancelled_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX team_invitations_one_pending_email
    ON team_invitations (team_id, email)
    WHERE accepted_at IS NULL AND cancelled_at IS NULL;
CREATE INDEX team_invitations_pending_expiry
    ON team_invitations (expires_at)
    WHERE accepted_at IS NULL AND cancelled_at IS NULL;

CREATE TABLE team_outbox_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN ('team_invitation_email')),
    aggregate_id uuid NOT NULL REFERENCES team_invitations(id) ON DELETE CASCADE,
    idempotency_key text NOT NULL UNIQUE,
    payload_ciphertext text NOT NULL,
    nonce text NOT NULL,
    auth_tag text NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 25),
    available_at timestamptz NOT NULL DEFAULT now(),
    claimed_at timestamptz,
    claim_owner uuid,
    delivered_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT team_outbox_envelope_shape CHECK (
        payload_ciphertext ~ '^[A-Za-z0-9_-]+$'
        AND nonce ~ '^[A-Za-z0-9_-]{16}$'
        AND auth_tag ~ '^[A-Za-z0-9_-]{22}$'
    ),
    CONSTRAINT team_outbox_claim_complete CHECK (
        (claimed_at IS NULL AND claim_owner IS NULL)
        OR (claimed_at IS NOT NULL AND claim_owner IS NOT NULL)
    )
);

CREATE INDEX team_outbox_jobs_available
    ON team_outbox_jobs (available_at, created_at)
    WHERE delivered_at IS NULL;

CREATE TABLE shared_vaults (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    name text NOT NULL,
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
    key_generation bigint NOT NULL DEFAULT 1 CHECK (key_generation > 0),
    rotation_required boolean NOT NULL DEFAULT false,
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    CONSTRAINT shared_vault_name_bounded CHECK (
        name = trim(name) AND char_length(name) BETWEEN 1 AND 120
    )
);

CREATE UNIQUE INDEX shared_vaults_active_name
    ON shared_vaults (team_id, lower(name)) WHERE archived_at IS NULL;
CREATE INDEX shared_vaults_active_team
    ON shared_vaults (team_id, created_at) WHERE archived_at IS NULL;

CREATE TABLE shared_vault_rotation_tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vault_id uuid NOT NULL REFERENCES shared_vaults(id) ON DELETE CASCADE,
    from_generation bigint NOT NULL CHECK (from_generation > 0),
    removed_membership_id uuid NOT NULL REFERENCES team_memberships(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'cancelled')),
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    UNIQUE (vault_id, from_generation, removed_membership_id),
    CONSTRAINT shared_vault_rotation_completion CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR (status <> 'completed' AND completed_at IS NULL)
    )
);

CREATE INDEX shared_vault_rotation_tasks_pending
    ON shared_vault_rotation_tasks (requested_at, vault_id) WHERE status = 'pending';

CREATE TABLE team_audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    action text NOT NULL CHECK (action ~ '^[a-z][a-z0-9_.-]{0,63}$'),
    target_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    target_membership_id uuid,
    target_vault_id uuid,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT team_audit_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX team_audit_events_team_time
    ON team_audit_events (team_id, created_at DESC, id DESC);

CREATE TABLE team_mutation_receipts (
    actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation text NOT NULL CHECK (operation ~ '^[a-z][a-z0-9_.-]{0,63}$'),
    idempotency_key text NOT NULL,
    response jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (actor_user_id, operation, idempotency_key),
    CONSTRAINT team_mutation_idempotency_key CHECK (
        char_length(idempotency_key) BETWEEN 16 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'
    ),
    CONSTRAINT team_mutation_response_object CHECK (jsonb_typeof(response) = 'object')
);

CREATE INDEX team_mutation_receipts_created
    ON team_mutation_receipts (created_at);

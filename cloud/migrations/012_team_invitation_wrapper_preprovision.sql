ALTER TABLE team_invitations
    ADD COLUMN reserved_membership_id uuid,
    ADD COLUMN reserved_membership_epoch bigint,
    ADD COLUMN wrapper_preprovision_required boolean NOT NULL DEFAULT false,
    ADD COLUMN wrappers_ready_at timestamptz;

UPDATE team_invitations AS invitation
SET reserved_membership_id = gen_random_uuid(),
    reserved_membership_epoch = COALESCE((
        SELECT max(membership.epoch) + 1
        FROM team_memberships AS membership
        WHERE membership.team_id = invitation.team_id
          AND membership.user_id = invitation.target_user_id
    ), 1)
WHERE invitation.invitation_type = 'username';

ALTER TABLE team_invitations
    ADD CONSTRAINT team_invitation_reserved_membership CHECK (
        (invitation_type = 'username'
          AND reserved_membership_id IS NOT NULL
          AND reserved_membership_epoch IS NOT NULL
          AND reserved_membership_epoch > 0)
        OR
        (invitation_type <> 'username'
          AND reserved_membership_id IS NULL
          AND reserved_membership_epoch IS NULL
          AND wrapper_preprovision_required = false
          AND wrappers_ready_at IS NULL)
    ),
    ADD CONSTRAINT team_invitation_wrapper_readiness CHECK (
        wrappers_ready_at IS NULL OR wrapper_preprovision_required = true
    );

CREATE TABLE team_invitation_wrapper_devices (
    invitation_id uuid NOT NULL REFERENCES team_invitations(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    PRIMARY KEY (invitation_id, device_id)
);

CREATE TABLE team_invitation_wrapper_vaults (
    invitation_id uuid NOT NULL REFERENCES team_invitations(id) ON DELETE CASCADE,
    vault_id uuid NOT NULL REFERENCES shared_vaults(id) ON DELETE CASCADE,
    key_generation bigint NOT NULL CHECK (key_generation > 0),
    PRIMARY KEY (invitation_id, vault_id)
);

CREATE TABLE team_invitation_vault_wrappers (
    invitation_id uuid NOT NULL REFERENCES team_invitations(id) ON DELETE CASCADE,
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
    created_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (invitation_id, vault_id, device_id),
    FOREIGN KEY (invitation_id, vault_id)
        REFERENCES team_invitation_wrapper_vaults(invitation_id, vault_id) ON DELETE CASCADE,
    FOREIGN KEY (invitation_id, device_id)
        REFERENCES team_invitation_wrapper_devices(invitation_id, device_id) ON DELETE CASCADE,
    CONSTRAINT team_invitation_wrapper_context_hash CHECK (context_hash ~ '^[A-Za-z0-9_-]{43}$'),
    CONSTRAINT team_invitation_wrapper_envelope_shape CHECK (
        jsonb_typeof(ephemeral_public_key) = 'object'
        AND ciphertext ~ '^[A-Za-z0-9_-]{43}$'
        AND nonce ~ '^[A-Za-z0-9_-]{16}$'
        AND auth_tag ~ '^[A-Za-z0-9_-]{22}$'
    )
);

CREATE INDEX team_invitation_vault_wrappers_device
    ON team_invitation_vault_wrappers (device_id, invitation_id);

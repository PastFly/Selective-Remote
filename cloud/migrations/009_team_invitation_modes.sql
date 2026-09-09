ALTER TABLE team_invitations
    ALTER COLUMN email DROP NOT NULL,
    ADD COLUMN invitation_type text NOT NULL DEFAULT 'email',
    ADD COLUMN target_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    ADD CONSTRAINT team_invitation_type CHECK (
        invitation_type IN ('email', 'username', 'link')
    ),
    ADD CONSTRAINT team_invitation_target CHECK (
        (invitation_type = 'email' AND email IS NOT NULL AND target_user_id IS NULL)
        OR (invitation_type = 'username' AND email IS NULL AND target_user_id IS NOT NULL)
        OR (invitation_type = 'link' AND email IS NULL AND target_user_id IS NULL)
    );

ALTER TABLE team_invitations
    ALTER COLUMN invitation_type DROP DEFAULT;

DROP INDEX team_invitations_one_pending_email;

CREATE UNIQUE INDEX team_invitations_one_pending_email
    ON team_invitations (team_id, email)
    WHERE invitation_type = 'email'
      AND accepted_at IS NULL AND cancelled_at IS NULL;

CREATE UNIQUE INDEX team_invitations_one_pending_user
    ON team_invitations (team_id, target_user_id)
    WHERE invitation_type = 'username'
      AND accepted_at IS NULL AND cancelled_at IS NULL;

CREATE INDEX team_invitations_pending_user
    ON team_invitations (target_user_id, expires_at)
    WHERE invitation_type = 'username'
      AND accepted_at IS NULL AND cancelled_at IS NULL;

CREATE TABLE team_invitation_link_secrets (
    invitation_id uuid PRIMARY KEY REFERENCES team_invitations(id) ON DELETE CASCADE,
    payload_ciphertext text NOT NULL,
    nonce text NOT NULL,
    auth_tag text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT team_invitation_link_secret_envelope CHECK (
        payload_ciphertext ~ '^[A-Za-z0-9_-]+$'
        AND nonce ~ '^[A-Za-z0-9_-]{16}$'
        AND auth_tag ~ '^[A-Za-z0-9_-]{22}$'
    )
);

CREATE TABLE email_verification_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    invalidated_at timestamptz,
    CONSTRAINT email_verification_token_hash_format CHECK (
        token_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT email_verification_token_expiry CHECK (
        expires_at > created_at
    ),
    CONSTRAINT email_verification_token_consumed_after_creation CHECK (
        consumed_at IS NULL OR consumed_at >= created_at
    ),
    CONSTRAINT email_verification_token_invalidated_after_creation CHECK (
        invalidated_at IS NULL OR invalidated_at >= created_at
    ),
    CONSTRAINT email_verification_token_terminal_state CHECK (
        consumed_at IS NULL OR invalidated_at IS NULL
    )
);

CREATE UNIQUE INDEX email_verification_one_active_token_per_user
    ON email_verification_tokens (user_id)
    WHERE consumed_at IS NULL AND invalidated_at IS NULL;

CREATE INDEX email_verification_expiry_cleanup
    ON email_verification_tokens (expires_at)
    WHERE consumed_at IS NULL AND invalidated_at IS NULL;

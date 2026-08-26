BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL,
    display_name text NOT NULL DEFAULT '',
    email_verified_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz,
    CONSTRAINT users_email_normalized CHECK (email = lower(trim(email)))
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_unique ON users (email);

CREATE TABLE IF NOT EXISTS account_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider text NOT NULL CHECK (provider IN ('password', 'google', 'apple', 'microsoft')),
    subject text NOT NULL,
    password_hash text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    UNIQUE (provider, subject),
    CONSTRAINT password_identity_hash CHECK (
        (provider = 'password' AND password_hash IS NOT NULL)
        OR (provider <> 'password' AND password_hash IS NULL)
    )
);

CREATE TABLE IF NOT EXISTS devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name text NOT NULL,
    platform text NOT NULL,
    app_version text NOT NULL DEFAULT '',
    public_key text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    UNIQUE (user_id, id)
);

CREATE TABLE IF NOT EXISTS sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    last_used_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);

CREATE INDEX IF NOT EXISTS sessions_user_active ON sessions (user_id, expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS personal_vaults (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
    envelope_version integer NOT NULL DEFAULT 1,
    wrapped_key jsonb,
    ciphertext text,
    nonce text,
    auth_tag text,
    content_hash text,
    updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vault_revisions (
    vault_id uuid NOT NULL REFERENCES personal_vaults(id) ON DELETE CASCADE,
    revision bigint NOT NULL CHECK (revision > 0),
    envelope_version integer NOT NULL,
    wrapped_key jsonb,
    ciphertext text NOT NULL,
    nonce text NOT NULL,
    auth_tag text NOT NULL,
    content_hash text NOT NULL,
    updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (vault_id, revision)
);

COMMIT;

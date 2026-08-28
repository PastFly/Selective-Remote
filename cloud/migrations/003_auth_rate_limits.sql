CREATE TABLE auth_rate_limits (
    scope text NOT NULL,
    key_hash text NOT NULL,
    window_started_at timestamptz NOT NULL,
    request_count bigint NOT NULL DEFAULT 1,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (scope, key_hash),
    CONSTRAINT auth_rate_limit_scope_format CHECK (
        scope ~ '^[a-z][a-z0-9_-]{0,63}$'
    ),
    CONSTRAINT auth_rate_limit_key_hash_format CHECK (
        key_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT auth_rate_limit_request_count_positive CHECK (
        request_count > 0
    ),
    CONSTRAINT auth_rate_limit_expiry_after_window CHECK (
        expires_at > window_started_at
    )
);

CREATE INDEX auth_rate_limits_expiry_cleanup
    ON auth_rate_limits (expires_at);

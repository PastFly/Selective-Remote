BEGIN;

ALTER TABLE users ADD COLUMN username text;

UPDATE users
SET username = 'user_' || substring(replace(id::text, '-', '') FROM 1 FOR 12)
WHERE username IS NULL;

ALTER TABLE users ALTER COLUMN username SET NOT NULL;
ALTER TABLE users ADD CONSTRAINT users_username_normalized
    CHECK (username = lower(trim(username)));
ALTER TABLE users ADD CONSTRAINT users_username_shape
    CHECK (username ~ '^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$');
CREATE UNIQUE INDEX users_username_unique ON users (username);

COMMIT;

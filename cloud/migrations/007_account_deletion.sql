ALTER TABLE teams
    ALTER COLUMN created_by_user_id DROP NOT NULL,
    DROP CONSTRAINT teams_created_by_user_id_fkey,
    ADD CONSTRAINT teams_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE team_memberships
    ALTER COLUMN user_id DROP NOT NULL,
    DROP CONSTRAINT team_memberships_user_id_fkey,
    ADD CONSTRAINT team_memberships_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE team_invitations
    ALTER COLUMN invited_by_user_id DROP NOT NULL,
    DROP CONSTRAINT team_invitations_invited_by_user_id_fkey,
    ADD CONSTRAINT team_invitations_invited_by_user_id_fkey
        FOREIGN KEY (invited_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE shared_vaults
    ALTER COLUMN created_by_user_id DROP NOT NULL,
    DROP CONSTRAINT shared_vaults_created_by_user_id_fkey,
    ADD CONSTRAINT shared_vaults_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE shared_vaults
    DROP CONSTRAINT shared_vault_payload_complete,
    ADD CONSTRAINT shared_vault_payload_complete CHECK (
        (revision = 0 AND envelope_version IS NULL AND ciphertext IS NULL AND nonce IS NULL
          AND auth_tag IS NULL AND content_hash IS NULL AND updated_by_device_id IS NULL)
        OR
        (revision > 0 AND envelope_version = 1 AND ciphertext IS NOT NULL AND nonce IS NOT NULL
          AND auth_tag IS NOT NULL AND content_hash IS NOT NULL)
    );

ALTER TABLE shared_vault_revisions
    ALTER COLUMN updated_by_device_id DROP NOT NULL,
    DROP CONSTRAINT shared_vault_revisions_updated_by_device_id_fkey,
    ADD CONSTRAINT shared_vault_revisions_updated_by_device_id_fkey
        FOREIGN KEY (updated_by_device_id) REFERENCES devices(id) ON DELETE SET NULL;

ALTER TABLE shared_vault_key_wrappers
    ALTER COLUMN created_by_device_id DROP NOT NULL,
    DROP CONSTRAINT shared_vault_key_wrappers_created_by_device_id_fkey,
    ADD CONSTRAINT shared_vault_key_wrappers_created_by_device_id_fkey
        FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE SET NULL;

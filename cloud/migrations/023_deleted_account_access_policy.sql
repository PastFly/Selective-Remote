-- Erase deleted account references without deleting shared policy or its history.
ALTER TABLE team_access_groups
    ALTER COLUMN created_by_user_id DROP NOT NULL,
    DROP CONSTRAINT team_access_groups_created_by_user_id_fkey,
    ADD CONSTRAINT team_access_groups_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE team_access_group_members
    ALTER COLUMN user_id DROP NOT NULL,
    DROP CONSTRAINT team_access_group_members_user_id_fkey,
    ADD CONSTRAINT team_access_group_members_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE team_access_group_members
    ALTER COLUMN created_by_user_id DROP NOT NULL,
    DROP CONSTRAINT team_access_group_members_created_by_user_id_fkey,
    ADD CONSTRAINT team_access_group_members_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE vault_access_grants
    ALTER COLUMN created_by_user_id DROP NOT NULL,
    DROP CONSTRAINT vault_access_grants_created_by_user_id_fkey,
    ADD CONSTRAINT vault_access_grants_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE team_access_group_members
    ADD CONSTRAINT access_group_active_member_requires_user
        CHECK (user_id IS NOT NULL OR removed_at IS NOT NULL);

-- Retained publication records already bind the actor IDs into immutable
-- history. Keep those IDs after account deletion and verify new references
-- under key-share locks so insertion still serializes with account deletion.
CREATE FUNCTION require_live_publication_actor() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM public.users AS actor
        JOIN public.devices AS device ON device.user_id = actor.id
        WHERE actor.id = NEW.actor_user_id AND device.id = NEW.actor_device_id
        FOR KEY SHARE OF actor, device;
    IF NOT FOUND THEN RAISE EXCEPTION 'publication_scope_mismatch'; END IF;
    RETURN NEW;
END;
$$;

ALTER TABLE vault_migration_attempts
    DROP CONSTRAINT vault_migration_attempts_actor_user_id_fkey,
    DROP CONSTRAINT vault_migration_attempts_actor_device_id_fkey;
CREATE TRIGGER require_live_publication_actor BEFORE INSERT ON vault_migration_attempts
    FOR EACH ROW EXECUTE FUNCTION require_live_publication_actor();

ALTER TABLE team_publication_operations
    DROP CONSTRAINT team_publication_operations_actor_user_id_fkey,
    DROP CONSTRAINT team_publication_operations_actor_device_id_fkey;
CREATE TRIGGER require_live_publication_actor BEFORE INSERT ON team_publication_operations
    FOR EACH ROW EXECUTE FUNCTION require_live_publication_actor();

ALTER TABLE team_publication_cancellations
    DROP CONSTRAINT team_publication_cancellations_actor_user_id_fkey,
    DROP CONSTRAINT team_publication_cancellations_actor_device_id_fkey;
CREATE TRIGGER require_live_publication_actor BEFORE INSERT ON team_publication_cancellations
    FOR EACH ROW EXECUTE FUNCTION require_live_publication_actor();

-- FK actions run after the deleted user row is no longer visible. Only that
-- exact reference can be cleared through this exception to the normal guards.
CREATE FUNCTION deleted_access_account_reference(old_id uuid, new_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
    SELECT old_id IS NOT NULL AND new_id IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.users WHERE id = old_id)
$$;

CREATE OR REPLACE FUNCTION lock_team_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE scope_team uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.created_by_user_id IS NULL THEN
        RAISE EXCEPTION 'access_group_creator_required';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF public.deleted_access_account_reference(OLD.created_by_user_id, NEW.created_by_user_id)
           AND to_jsonb(NEW) - 'created_by_user_id' = to_jsonb(OLD) - 'created_by_user_id' THEN
            RETURN NEW;
        END IF;
        IF TG_TABLE_NAME = 'team_access_group_members' THEN
            IF public.deleted_access_account_reference(OLD.user_id, NEW.user_id)
               AND to_jsonb(NEW) - 'user_id' = to_jsonb(OLD) - 'user_id' THEN
                IF OLD.removed_at IS NULL THEN
                    NEW.removed_at := now();
                    NEW.version := OLD.version + 1;
                END IF;
                RETURN NEW;
            END IF;
        END IF;
        IF NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id THEN
            RAISE EXCEPTION 'access_group_creator_immutable';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN scope_team := OLD.team_id; ELSE scope_team := NEW.team_id; END IF;
    IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM teams WHERE id = scope_team) THEN
        RETURN OLD; -- Team teardown can cascade its Team-scoped policy records.
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'access_group_hard_delete_forbidden';
    END IF;
    INSERT INTO team_policy_revisions (team_id) VALUES (scope_team) ON CONFLICT DO NOTHING;
    PERFORM 1 FROM team_policy_revisions WHERE team_id = scope_team FOR UPDATE;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.team_id <> OLD.team_id OR NEW.id <> OLD.id OR NEW.created_at <> OLD.created_at
            OR NEW.version <> OLD.version + 1 THEN
            RAISE EXCEPTION 'access_group_identity_or_version_invalid';
        END IF;
        IF TG_TABLE_NAME = 'team_access_groups' THEN
            IF OLD.deleted_at IS NOT NULL OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL
                AND (EXISTS (SELECT 1 FROM vault_access_grants
                    WHERE team_id = OLD.team_id AND principal_kind = 'GROUP'
                      AND principal_id = OLD.id AND revoked_at IS NULL)
                 OR EXISTS (SELECT 1 FROM team_access_group_members
                    WHERE team_id = OLD.team_id AND group_id = OLD.id
                      AND removed_at IS NULL))) THEN
                RAISE EXCEPTION 'access_group_active_grants_or_tombstone';
            END IF;
        ELSE
            IF OLD.removed_at IS NOT NULL OR NEW.group_id <> OLD.group_id
                OR NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.membership_id <> OLD.membership_id
                OR NEW.membership_epoch <> OLD.membership_epoch THEN
                RAISE EXCEPTION 'access_group_edge_immutable_or_tombstoned';
            END IF;
        END IF;
    END IF;
    IF TG_TABLE_NAME = 'team_access_group_members' AND TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM team_access_groups
            WHERE id = NEW.group_id AND team_id = NEW.team_id AND deleted_at IS NULL) OR
           NOT EXISTS (SELECT 1 FROM team_memberships
            WHERE id = NEW.membership_id AND team_id = NEW.team_id
              AND user_id = NEW.user_id AND epoch = NEW.membership_epoch
              AND revoked_at IS NULL) THEN
            RAISE EXCEPTION 'access_group_member_scope_or_epoch_invalid';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE OR REPLACE FUNCTION guard_vault_access_grant() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_policy_kind text; allowed_mask integer; current_format text; vault_archived boolean;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM shared_vaults
            WHERE id = OLD.vault_id AND team_id = OLD.team_id) THEN
            RAISE EXCEPTION 'access_grant_hard_delete_forbidden';
        END IF;
        RETURN OLD; -- Vault teardown removes only its Vault-scoped grants.
    END IF;
    IF TG_OP = 'INSERT' AND NEW.created_by_user_id IS NULL THEN
        RAISE EXCEPTION 'access_grant_creator_required';
    END IF;
    IF TG_OP = 'UPDATE'
       AND public.deleted_access_account_reference(OLD.created_by_user_id, NEW.created_by_user_id)
       AND to_jsonb(NEW) - 'created_by_user_id' = to_jsonb(OLD) - 'created_by_user_id' THEN
        RETURN NEW;
    END IF;
    SELECT format_state, archived_at IS NOT NULL INTO current_format, vault_archived
        FROM shared_vaults WHERE id = NEW.vault_id AND team_id = NEW.team_id FOR UPDATE;
    IF NOT FOUND OR (vault_archived AND (TG_OP = 'INSERT' OR NEW.revoked_at IS NULL)) THEN
        RAISE EXCEPTION 'access_v2_preparing_required';
    END IF;
    IF (TG_OP = 'INSERT' OR NEW.revoked_at IS NULL)
       AND current_format <> 'V2_PREPARING' THEN
        RAISE EXCEPTION 'access_v2_preparing_required';
    END IF;
    INSERT INTO team_policy_revisions (team_id) VALUES (NEW.team_id) ON CONFLICT DO NOTHING;
    PERFORM 1 FROM team_policy_revisions WHERE team_id = NEW.team_id FOR UPDATE;
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.id, NEW.team_id, NEW.vault_id, NEW.principal_kind, NEW.principal_id,
            NEW.membership_id, NEW.membership_epoch, NEW.target_kind, NEW.target_id,
            NEW.created_at, NEW.created_by_user_id)
           IS DISTINCT FROM
           (OLD.id, OLD.team_id, OLD.vault_id, OLD.principal_kind, OLD.principal_id,
            OLD.membership_id, OLD.membership_epoch, OLD.target_kind, OLD.target_id,
            OLD.created_at, OLD.created_by_user_id)
           OR NEW.version <> OLD.version + 1 OR OLD.revoked_at IS NOT NULL THEN
            RAISE EXCEPTION 'access_grant_identity_or_version_invalid';
        END IF;
        IF NEW.revoked_at IS NOT NULL THEN
            IF NEW.permission_mask <> OLD.permission_mask THEN
                RAISE EXCEPTION 'access_grant_revoke_mask_changed';
            END IF;
            -- Revocation must remain possible after the principal's epoch expires
            -- or its target is tombstoned. It grants no new rights.
            RETURN NEW;
        END IF;
    END IF;
    IF NEW.principal_kind = 'USER' THEN
        IF NOT EXISTS (SELECT 1 FROM team_memberships WHERE id = NEW.membership_id
            AND team_id = NEW.team_id AND user_id = NEW.principal_id
            AND epoch = NEW.membership_epoch AND revoked_at IS NULL) THEN
            RAISE EXCEPTION 'access_grant_membership_scope_or_epoch_invalid';
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM team_access_groups WHERE id = NEW.principal_id
            AND team_id = NEW.team_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'access_grant_group_scope_invalid';
        END IF;
    END IF;
    IF NEW.target_kind = 'VAULT' THEN
        IF NEW.target_id <> NEW.vault_id THEN RAISE EXCEPTION 'access_grant_target_scope_invalid'; END IF;
        allowed_mask := 29; -- View, Edit, ManageAccess, Create
    ELSE
        SELECT policy_kind INTO target_policy_kind FROM vault_resource_registry
            WHERE id = NEW.target_id AND team_id = NEW.team_id AND vault_id = NEW.vault_id
              AND deleted_at IS NULL;
        IF target_policy_kind IS NULL OR
           (NEW.target_kind = 'FOLDER' AND target_policy_kind <> 'FOLDER') OR
           (NEW.target_kind = 'RESOURCE' AND target_policy_kind = 'FOLDER') THEN
            RAISE EXCEPTION 'access_grant_target_scope_invalid';
        END IF;
        allowed_mask := CASE target_policy_kind
            WHEN 'HOST' THEN 13 WHEN 'CREDENTIAL' THEN 15
            WHEN 'SNIPPET' THEN 13 WHEN 'FORWARDING' THEN 9
            WHEN 'FOLDER' THEN 33 ELSE 0 END;
        IF target_policy_kind = 'CREDENTIAL' AND
            (NEW.permission_mask & 4) <> 0 AND (NEW.permission_mask & 2) = 0 THEN
            RAISE EXCEPTION 'credential_edit_requires_reveal';
        END IF;
    END IF;
    IF (NEW.permission_mask & ~allowed_mask) <> 0 THEN
        RAISE EXCEPTION 'access_grant_permission_invalid';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION advance_team_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Attribution cleanup keeps the effective policy and its version intact.
    IF TG_OP = 'UPDATE' AND NEW.version = OLD.version THEN RETURN NULL; END IF;
    UPDATE team_policy_revisions SET revision = revision + 1
        WHERE team_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.team_id ELSE NEW.team_id END;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION advance_vault_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Attribution cleanup keeps the effective policy and its version intact.
    IF TG_OP = 'UPDATE' AND NEW.version = OLD.version THEN RETURN NULL; END IF;
    UPDATE shared_vaults SET access_policy_version = access_policy_version + 1
        WHERE id = NEW.vault_id AND team_id = NEW.team_id;
    RETURN NULL;
END;
$$;

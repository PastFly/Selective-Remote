-- Dormant, Team-scoped access policy. Existing Vaults remain V1_ACTIVE.
ALTER TABLE shared_vaults
    ADD COLUMN access_policy_version bigint NOT NULL DEFAULT 0 CHECK (access_policy_version >= 0);
ALTER TABLE vault_resource_registry
    ADD COLUMN policy_kind text CHECK (policy_kind IN
        ('HOST', 'CREDENTIAL', 'SNIPPET', 'FORWARDING', 'FOLDER'));

CREATE FUNCTION guard_resource_policy_kind() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.policy_kind IS DISTINCT FROM OLD.policy_kind THEN
        RAISE EXCEPTION 'resource_policy_kind_immutable';
    END IF;
    IF NEW.policy_kind IS NOT NULL AND NOT (
        (NEW.policy_kind = 'FOLDER' AND NEW.policy_class = 'folder') OR
        (NEW.policy_kind = 'CREDENTIAL' AND NEW.policy_class = 'secret') OR
        (NEW.policy_kind IN ('HOST', 'SNIPPET', 'FORWARDING') AND NEW.policy_class = 'general')
    ) THEN
        RAISE EXCEPTION 'resource_policy_kind_class_mismatch';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER b_resource_policy_kind_guard
    BEFORE INSERT OR UPDATE ON vault_resource_registry
    FOR EACH ROW EXECUTE FUNCTION guard_resource_policy_kind();

CREATE TABLE team_policy_revisions (
    team_id uuid PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE,
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0)
);

CREATE TABLE team_access_mutation_receipts (
    actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation text NOT NULL CHECK (operation ~ '^[a-z][a-z0-9_.-]{0,63}$'),
    idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 16 AND 128
        AND idempotency_key ~ '^[A-Za-z0-9._:-]+$'),
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    response jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(response) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (actor_user_id, operation, idempotency_key)
);

CREATE TABLE team_access_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    name text NOT NULL CHECK (name = trim(name) AND char_length(name) BETWEEN 1 AND 120
        AND name !~ '[[:cntrl:]]'),
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at timestamptz,
    UNIQUE (id, team_id)
);
CREATE UNIQUE INDEX team_access_groups_active_name
    ON team_access_groups (team_id, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX team_access_groups_active_page
    ON team_access_groups (team_id, id) WHERE deleted_at IS NULL;

CREATE TABLE team_access_group_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    membership_id uuid NOT NULL REFERENCES team_memberships(id) ON DELETE CASCADE,
    membership_epoch bigint NOT NULL CHECK (membership_epoch > 0),
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    removed_at timestamptz,
    FOREIGN KEY (group_id, team_id) REFERENCES team_access_groups(id, team_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX team_access_group_members_one_active
    ON team_access_group_members (team_id, group_id, user_id) WHERE removed_at IS NULL;
CREATE INDEX team_access_group_members_by_membership
    ON team_access_group_members (team_id, membership_id, membership_epoch)
    WHERE removed_at IS NULL;
CREATE INDEX team_access_group_members_by_group
    ON team_access_group_members (team_id, group_id, id) WHERE removed_at IS NULL;

CREATE TABLE vault_access_grants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    principal_kind text NOT NULL CHECK (principal_kind IN ('USER', 'GROUP')),
    principal_id uuid NOT NULL,
    membership_id uuid REFERENCES team_memberships(id) ON DELETE RESTRICT,
    membership_epoch bigint CHECK (membership_epoch > 0),
    target_kind text NOT NULL CHECK (target_kind IN ('VAULT', 'FOLDER', 'RESOURCE')),
    target_id uuid NOT NULL,
    permission_mask integer NOT NULL CHECK (permission_mask > 0 AND (permission_mask & ~63) = 0),
    created_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    revoked_at timestamptz,
    FOREIGN KEY (vault_id, team_id) REFERENCES shared_vaults(id, team_id) ON DELETE CASCADE,
    CHECK ((principal_kind = 'USER' AND membership_id IS NOT NULL AND membership_epoch IS NOT NULL)
        OR (principal_kind = 'GROUP' AND membership_id IS NULL AND membership_epoch IS NULL))
);
CREATE UNIQUE INDEX vault_access_grants_one_active
    ON vault_access_grants (team_id, vault_id, principal_kind, principal_id, target_kind, target_id)
    WHERE revoked_at IS NULL;
CREATE INDEX vault_access_grants_by_target
    ON vault_access_grants (team_id, vault_id, target_kind, target_id, id)
    WHERE revoked_at IS NULL;
CREATE INDEX vault_access_grants_by_principal
    ON vault_access_grants (team_id, vault_id, principal_kind, principal_id, id)
    WHERE revoked_at IS NULL;

-- Every direct SQL writer locks the policy row and advances the snapshot version.
CREATE FUNCTION lock_team_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE scope_team uuid;
BEGIN
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
                OR NEW.user_id <> OLD.user_id OR NEW.membership_id <> OLD.membership_id
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
CREATE TRIGGER a_access_group_policy_lock
    BEFORE INSERT OR UPDATE OR DELETE ON team_access_groups
    FOR EACH ROW EXECUTE FUNCTION lock_team_access_policy();
CREATE TRIGGER a_access_group_member_policy_lock
    BEFORE INSERT OR UPDATE OR DELETE ON team_access_group_members
    FOR EACH ROW EXECUTE FUNCTION lock_team_access_policy();

CREATE FUNCTION advance_team_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE team_policy_revisions SET revision = revision + 1
        WHERE team_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.team_id ELSE NEW.team_id END;
    RETURN NULL;
END;
$$;
CREATE TRIGGER z_access_group_policy_revision
    AFTER INSERT OR UPDATE OR DELETE ON team_access_groups
    FOR EACH ROW EXECUTE FUNCTION advance_team_access_policy();
CREATE TRIGGER z_access_group_member_policy_revision
    AFTER INSERT OR UPDATE OR DELETE ON team_access_group_members
    FOR EACH ROW EXECUTE FUNCTION advance_team_access_policy();

CREATE FUNCTION guard_vault_access_grant() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_policy_kind text; allowed_mask integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM shared_vaults
            WHERE id = OLD.vault_id AND team_id = OLD.team_id) THEN
            RAISE EXCEPTION 'access_grant_hard_delete_forbidden';
        END IF;
        RETURN OLD; -- Vault teardown removes only its Vault-scoped grants.
    END IF;
    PERFORM 1 FROM shared_vaults WHERE id = NEW.vault_id AND team_id = NEW.team_id
        AND archived_at IS NULL AND format_state = 'V2_PREPARING'
        AND format_schema_version = 2 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'access_v2_preparing_required'; END IF;
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
CREATE TRIGGER a_vault_access_grant_guard
    BEFORE INSERT OR UPDATE OR DELETE ON vault_access_grants
    FOR EACH ROW EXECUTE FUNCTION guard_vault_access_grant();

CREATE FUNCTION advance_vault_access_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE shared_vaults SET access_policy_version = access_policy_version + 1
        WHERE id = NEW.vault_id AND team_id = NEW.team_id;
    RETURN NULL;
END;
$$;
CREATE TRIGGER z_vault_access_grant_revision
    AFTER INSERT OR UPDATE ON vault_access_grants
    FOR EACH ROW EXECUTE FUNCTION advance_vault_access_policy();

-- Dormant Vault v2 identity foundation. Existing Vaults stay V1_ACTIVE.
ALTER TABLE shared_vaults
    ADD COLUMN format_state text NOT NULL DEFAULT 'V1_ACTIVE'
        CHECK (format_state IN ('V1_ACTIVE', 'V2_PREPARING', 'V2_READY', 'V2_ACTIVE')),
    ADD COLUMN format_schema_version integer NOT NULL DEFAULT 1
        CHECK (format_schema_version IN (1, 2));
ALTER TABLE shared_vaults ADD CONSTRAINT shared_vault_format_schema_match CHECK (
    (format_state = 'V1_ACTIVE' AND format_schema_version = 1)
    OR (format_state <> 'V1_ACTIVE' AND format_schema_version = 2)
);

-- A composite reference keeps a registry row inside its claimed Team and Vault.
CREATE UNIQUE INDEX shared_vaults_id_team_unique ON shared_vaults (id, team_id);

CREATE TABLE vault_resource_registry (
    id uuid PRIMARY KEY,
    team_id uuid NOT NULL,
    vault_id uuid NOT NULL,
    policy_class text NOT NULL CHECK (policy_class IN ('folder', 'secret', 'general')),
    parent_folder_id uuid,
    parent_policy_class text NOT NULL DEFAULT 'folder' CHECK (parent_policy_class = 'folder'),
    schema_version integer NOT NULL DEFAULT 2 CHECK (schema_version = 2),
    resource_version bigint NOT NULL DEFAULT 1 CHECK (resource_version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (team_id, vault_id, id),
    UNIQUE (team_id, vault_id, id, policy_class),
    FOREIGN KEY (vault_id, team_id) REFERENCES shared_vaults(id, team_id) ON DELETE CASCADE,
    FOREIGN KEY (team_id, vault_id, parent_folder_id, parent_policy_class)
        REFERENCES vault_resource_registry(team_id, vault_id, id, policy_class),
    CHECK (parent_folder_id IS NULL OR parent_folder_id <> id)
);

CREATE INDEX vault_resource_registry_vault_active
    ON vault_resource_registry (team_id, vault_id, id) WHERE deleted_at IS NULL;
CREATE INDEX vault_resource_registry_parent_active
    ON vault_resource_registry (team_id, vault_id, parent_folder_id)
    WHERE deleted_at IS NULL;

CREATE FUNCTION vault_resource_registry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.id <> OLD.id OR NEW.team_id <> OLD.team_id OR NEW.vault_id <> OLD.vault_id
           OR NEW.policy_class <> OLD.policy_class OR NEW.schema_version <> OLD.schema_version
           OR NEW.created_at <> OLD.created_at THEN
            RAISE EXCEPTION 'immutable_resource_identity';
        END IF;
        IF OLD.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'tombstoned_resource_identity';
        END IF;
        IF NEW.resource_version <> OLD.resource_version + 1 THEN
            RAISE EXCEPTION 'invalid_resource_version';
        END IF;
        IF NEW.deleted_at IS NOT NULL AND EXISTS (
            SELECT 1 FROM vault_resource_registry AS child
            WHERE child.team_id = OLD.team_id AND child.vault_id = OLD.vault_id
              AND child.parent_folder_id = OLD.id AND child.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'active_resource_children';
        END IF;
    END IF;
    IF NEW.parent_folder_id IS NOT NULL THEN
        IF EXISTS (
            WITH RECURSIVE ancestors AS (
                SELECT id, parent_folder_id FROM vault_resource_registry
                WHERE team_id = NEW.team_id AND vault_id = NEW.vault_id
                  AND id = NEW.parent_folder_id AND deleted_at IS NULL
                UNION ALL
                SELECT parent.id, parent.parent_folder_id
                FROM vault_resource_registry AS parent
                JOIN ancestors ON parent.id = ancestors.parent_folder_id
                WHERE parent.team_id = NEW.team_id AND parent.vault_id = NEW.vault_id
                  AND parent.deleted_at IS NULL
            )
            SELECT 1 FROM ancestors WHERE id = NEW.id
        ) THEN
            RAISE EXCEPTION 'cyclic_resource_parent';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM vault_resource_registry AS parent
            WHERE parent.team_id = NEW.team_id AND parent.vault_id = NEW.vault_id
              AND parent.id = NEW.parent_folder_id AND parent.policy_class = 'folder'
              AND parent.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'inactive_resource_parent';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER vault_resource_registry_guard_trigger
    BEFORE INSERT OR UPDATE ON vault_resource_registry
    FOR EACH ROW EXECUTE FUNCTION vault_resource_registry_guard();

-- Defense in depth for preprovisioned invitation wrappers and revision uploads.
-- Future v2 ciphertext and keys must never enter legacy whole-Vault tables.
CREATE FUNCTION require_legacy_vault_payload() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM shared_vaults
        WHERE id = NEW.vault_id AND format_state = 'V1_ACTIVE'
          AND format_schema_version = 1
    ) THEN
        RAISE EXCEPTION 'legacy_vault_format_required';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER shared_vault_wrappers_v1_only
    BEFORE INSERT OR UPDATE ON shared_vault_key_wrappers
    FOR EACH ROW EXECUTE FUNCTION require_legacy_vault_payload();
CREATE TRIGGER invitation_vault_wrappers_v1_only
    BEFORE INSERT OR UPDATE ON team_invitation_vault_wrappers
    FOR EACH ROW EXECUTE FUNCTION require_legacy_vault_payload();
CREATE TRIGGER shared_vault_revisions_v1_only
    BEFORE INSERT OR UPDATE ON shared_vault_revisions
    FOR EACH ROW EXECUTE FUNCTION require_legacy_vault_payload();

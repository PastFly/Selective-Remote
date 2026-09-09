CREATE TABLE team_membership_device_admissions (
    membership_id uuid NOT NULL,
    membership_epoch bigint NOT NULL CHECK (membership_epoch > 0),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    invitation_id uuid REFERENCES team_invitations(id) ON DELETE SET NULL,
    admitted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (membership_id, membership_epoch, device_id),
    FOREIGN KEY (membership_id, membership_epoch)
        REFERENCES team_memberships(id, epoch) ON DELETE CASCADE
);

CREATE INDEX team_membership_device_admissions_device
    ON team_membership_device_admissions (device_id, membership_id, membership_epoch);

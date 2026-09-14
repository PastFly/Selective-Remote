ALTER TABLE teams
    ADD COLUMN automatic_device_admission boolean NOT NULL DEFAULT true;

WITH admitted AS (
    INSERT INTO team_membership_device_admissions
        (membership_id, membership_epoch, device_id)
    SELECT membership.id, membership.epoch, device.id
    FROM team_memberships AS membership
    JOIN teams AS team ON team.id = membership.team_id AND team.archived_at IS NULL
    JOIN devices AS device
      ON device.user_id = membership.user_id
     AND device.revoked_at IS NULL
     AND device.public_key IS NOT NULL
     AND device.public_key_algorithm = 'p256-ecdh-v1'
    WHERE membership.revoked_at IS NULL AND team.automatic_device_admission = true
    ON CONFLICT (membership_id, membership_epoch, device_id) DO NOTHING
    RETURNING membership_id, membership_epoch, device_id
)
INSERT INTO team_audit_events
    (team_id, actor_user_id, action, target_user_id, target_membership_id, metadata)
SELECT membership.team_id, NULL, 'team.device_auto_admission_backfilled',
       membership.user_id, membership.id,
       jsonb_build_object(
         'membershipEpoch', admitted.membership_epoch,
         'deviceID', admitted.device_id,
         'source', 'migration_011'
       )
FROM admitted
JOIN team_memberships AS membership
  ON membership.id = admitted.membership_id
 AND membership.epoch = admitted.membership_epoch;

import assert from "node:assert/strict";
import test from "node:test";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { fileURLToPath } from "node:url";
import { applyMigrations } from "../src/migrations.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import { CloudService } from "../src/service.mjs";
import {
  createPreviewToken,
  verifyPreviewToken,
} from "../src/access-preview.mjs";
const databaseURL = process.env.TEST_DATABASE_URL;
const migrations = fileURLToPath(new URL("../migrations/", import.meta.url));

test(
  "scoped directories and atomic signed group impact workflow",
  { skip: !databaseURL },
  async (t) => {
    const pool = new pg.Pool({ connectionString: databaseURL, max: 5 });
    // Other integration files exercise global migration locks concurrently. A
    // deadlock aborts this entire autocommit fixture statement, so retry it only.
    // Production Store transactions still use their own unmodified retry path.
    async function fixtureQuery(...args) {
      for (let attempt=0;;attempt++) {
        try { return await pool.query(...args); }
        catch(error) {
          if (!['40P01','40001'].includes(error.code) || attempt>=2) throw error;
          await new Promise(resolve=>setTimeout(resolve,20*(attempt+1)));
        }
      }
    }

    try {
      await applyMigrations(pool, migrations, { info() {} });
      const suffix = "surface_" + randomUUID().replaceAll("-", "").slice(0, 16);
      const user = (
        await fixtureQuery(
          `INSERT INTO users(email,username,display_name,email_verified_at) VALUES($1,$2,'Synthetic',now()) RETURNING id`,
          [`${suffix}@example.com`, suffix],
        )
      ).rows[0].id;
      const device = randomUUID();
      await fixtureQuery(
        `INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'Synthetic','web',$3,'p256-ecdh-v1',now(),now())`,
        [
          device,
          user,
          JSON.stringify({
            kty: "EC",
            crv: "P-256",
            x: "A".repeat(43),
            y: "B".repeat(43),
            ext: true,
            key_ops: [],
          }),
        ],
      );
      const team = (
        await fixtureQuery(
          `INSERT INTO teams(name,created_by_user_id) VALUES('Synthetic',$1) RETURNING id`,
          [user],
        )
      ).rows[0].id;
      let membership = (
        await fixtureQuery(
          `INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner') RETURNING id`,
          [team, user],
        )
      ).rows[0].id;
      const vault = (
        await fixtureQuery(
          `INSERT INTO shared_vaults(team_id,name,created_by_user_id,format_state,format_schema_version) VALUES($1,'Synthetic',$2,'V2_PREPARING',2) RETURNING id`,
          [team, user],
        )
      ).rows[0].id;
      const resource = randomUUID();
      await fixtureQuery(
        `INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class,policy_kind) VALUES($1,$2,$3,'general','HOST')`,
        [resource, team, vault],
      );
      const store = new PostgresStore(null, pool);
      const service = new CloudService(store, {
        sessionPepper: "synthetic-secret",
      });
      const session = { user_id: user, device_id: device };
      const input = {
        actorUserID: user,
        actorDeviceID: device,
        teamID: team,
        vaultID: vault,
        sessionSecret: "synthetic-secret",
      };
      const preview = (request) =>
        store.access.previewAccessGroupChange({ ...input, request });
      const commit = (request, p) =>
        store.access.commitAccessGroupChange({
          ...input,
          request,
          token: p.token,
          idempotencyKey: randomUUID(),
        });
      await t.test(
        "directory metadata only, strict scope and resource pagination",
        async () => {
          const page = await service.listAccessVaults(session, team, {
            limit: 1,
          });
          assert.deepEqual(page.rows, [
            {
              id: vault,
              teamID: team,
              name: "Synthetic",
              formatState: "V2_PREPARING",
            },
          ]);
          assert.deepEqual(
            await service.getAccessContext(session, team, vault),
            {
              formatState: "V2_PREPARING",
              legacyWholeVault: false,
              resource_registry_v2: true,
              resource_acl_v2: false,
              policyMutationAvailable: true,
              groupMutationAvailable: true,
              blockers: [],
            },
          );
          const resources = await service.listAccessResources(
            session,
            team,
            vault,
            { limit: 1 },
          );
          assert.deepEqual(resources.rows, [
            {
              id: resource,
              teamID: team,
              vaultID: vault,
              policyKind: "HOST",
              parentFolderID: null,
              resourceVersion: 1,
            },
          ]);
          assert.deepEqual(
            await service.listAccessResources(session, team, vault, {
              kind: "FOLDER",
            }),
            { rows: [], nextCursor: null },
          );
          await assert.rejects(
            service.listAccessVaults(
              { ...session, device_id: randomUUID() },
              team,
            ),
            /team_not_found/,
          );
          await assert.rejects(
            service.listAccessResources(session, randomUUID(), vault),
            /team_not_found/,
          );
          await assert.rejects(
            service.listAccessResources(session, team, vault, { limit: 51 }),
            /invalid_access_page/,
          );
        },
      );
      let group, edge;
      await t.test(
        "create, literal search, rename, members; stable snapshot ID",
        async () => {
          const request = { type: "GROUP_CREATE", name: "Operators_%" };
          const p = await preview(request);
          const p2 = await preview(request);
          assert.equal(p.snapshotID, p2.snapshotID);
          assert.equal(p.snapshotID.length, 64);
          assert.deepEqual(p.counts, {
            pairs: 0,
            widened: 0,
            lost: 0,
            affectedGrants: 0,
          });
          assert.deepEqual(p.affectedGrants, []);
          group = (await commit(request, p)).group;
          assert.equal(
            (await service.listAccessGroups(session, team, { search: "_%" }))
              .rows.length,
            1,
          );
          assert.equal(
            (
              await service.listAccessGroups(session, team, {
                search: "%absent",
              })
            ).rows.length,
            0,
          );
          const rename = {
            type: "GROUP_RENAME",
            groupID: group.id,
            expectedVersion: 1,
            name: "Operators",
          };
          group = (await commit(rename, await preview(rename))).group;
          const add = {
            type: "GROUP_MEMBER_ADD",
            groupID: group.id,
            targetMembershipID: membership,
          };
          edge = (await commit(add, await preview(add))).member;
          assert.deepEqual(
            (await service.listAccessGroupMembers(session, team, group.id))
              .rows,
            [
              {
                id: edge.id,
                groupID: group.id,
                userID: user,
                membershipID: membership,
                membershipEpoch: 1,
                version: 1,
              },
            ],
          );
        },
      );
      await t.test(
        "equivalent direct path yields no notification; stale snapshot rolls back",
        async () => {
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,target_kind,target_id,permission_mask,created_by_user_id) VALUES($1,$2,'GROUP',$3,'RESOURCE',$4,1,$5)`,
            [team, vault, group.id, resource, user],
          );
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,membership_id,membership_epoch,target_kind,target_id,permission_mask,created_by_user_id) VALUES($1,$2,'USER',$3,$4,1,'RESOURCE',$5,1,$3)`,
            [team, vault, user, membership, resource],
          );
          const remove = {
            type: "GROUP_MEMBER_REMOVE",
            groupID: group.id,
            edgeID: edge.id,
            expectedVersion: 1,
          };
          const p = await preview(remove);
          assert.equal(p.details[0].vaultID, vault);
          assert.equal(p.details[0].before.policyEffective.paths.length, 2);
          assert.equal(p.details[0].after.policyEffective.paths.length, 1);
          assert.equal(p.details[0].lostMask, 0);
          await fixtureQuery(
            `UPDATE team_access_groups SET name='Changed',version=version+1 WHERE id=$1`,
            [group.id],
          );
          assert.notEqual((await preview(remove)).snapshotID, p.snapshotID);
          await assert.rejects(commit(remove, p), /access_preview_conflict/);
          assert.equal(
            (
              await fixtureQuery(
                `SELECT removed_at FROM team_access_group_members WHERE id=$1`,
                [edge.id],
              )
            ).rows[0].removed_at,
            null,
          );
          assert.deepEqual(
            (await commit(remove, await preview(remove)))
              .notificationCandidates,
            [],
          );
        },
      );
      await t.test(
        "device picker uses exact subject epoch, bounded pages, no keys",
        async () => {
          const second = randomUUID();
          await fixtureQuery(
            `INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'Unadmitted','web')`,
            [second, user],
          );
          const first = await service.listAccessDevices(session, team, vault, {
            subjectUserID: user,
            limit: 1,
          });
          assert.equal(first.rows.length, 1);
          assert.ok(first.nextCursor);
          const next = await service.listAccessDevices(session, team, vault, {
            subjectUserID: user,
            limit: 1,
            cursor: first.nextCursor,
          });
          assert.equal(next.rows.length, 1);
          assert.equal(next.nextCursor, null);
          assert.ok(
            [...first.rows, ...next.rows].every(
              (row) =>
                Object.keys(row).sort().join(",") ===
                  "admitted,id,name,platform" && row.admitted === false,
            ),
          );
          await assert.rejects(
            service.listAccessDevices(session, team, vault, {
              subjectUserID: randomUUID(),
            }),
            /team_not_found/,
          );
          await assert.rejects(
            service.listAccessDevices(
              { ...session, device_id: randomUUID() },
              team,
              vault,
              { subjectUserID: user },
            ),
            /team_not_found/,
          );
        },
      );
      await t.test(
        "stale role, device, membership and request invalidate without writes",
        async () => {
          const request = { type: "GROUP_CREATE", name: "Stale" };
          const p = await preview(request);
          await assert.rejects(
            commit({ ...request, name: "Changed" }, p),
            /access_preview_conflict/,
          );
          await assert.rejects(
            commit(request, { token: p.token + "a" }),
            /access_preview_conflict/,
          );
          await fixtureQuery(
            `UPDATE team_memberships SET role='admin' WHERE id=$1`,
            [membership],
          );
          await assert.rejects(commit(request, p), /access_preview_conflict/);
          await fixtureQuery(
            `UPDATE team_memberships SET role='viewer' WHERE id=$1`,
            [membership],
          );
          await assert.rejects(
            service.listAccessVaults(session, team),
            /team_access_denied/,
          );
          await fixtureQuery(
            `UPDATE team_memberships SET role='owner' WHERE id=$1`,
            [membership],
          );
          const revokedDevice = randomUUID();
          await fixtureQuery(
            `INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) SELECT $1,user_id,'Revoke test',platform,public_key,public_key_algorithm,key_registered_at,key_approved_at FROM devices WHERE id=$2`,
            [revokedDevice, device],
          );
          const rp = await store.access.previewAccessGroupChange({
            ...input,
            actorDeviceID: revokedDevice,
            request,
          });
          await fixtureQuery(`UPDATE devices SET revoked_at=now() WHERE id=$1`, [
            revokedDevice,
          ]);
          await assert.rejects(
            store.access.commitAccessGroupChange({
              ...input,
              actorDeviceID: revokedDevice,
              request,
              token: rp.token,
              idempotencyKey: randomUUID(),
            }),
            /team_not_found/,
          );
          await fixtureQuery(
            `UPDATE team_memberships SET revoked_at=now(),revoked_by_user_id=$2 WHERE id=$1`,
            [membership, user],
          );
          membership = (
            await fixtureQuery(
              `INSERT INTO team_memberships(team_id,user_id,role,epoch) VALUES($1,$2,'owner',2) RETURNING id`,
              [team, user],
            )
          ).rows[0].id;
          await assert.rejects(commit(request, p), /access_preview_conflict/);
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_access_groups WHERE team_id=$1 AND name='Stale'`,
                [team],
              )
            ).rows[0].count,
            "0",
          );
        },
      );
      await t.test(
        "two concurrent signed commits serialize and one stale request rolls back",
        async () => {
          const request = { type: "GROUP_CREATE", name: "Concurrent" };
          const p = await preview(request);
          const results = await Promise.allSettled([
            commit(request, p),
            commit(request, p),
          ]);
          assert.equal(
            results.filter((r) => r.status === "fulfilled").length,
            1,
          );
          assert.match(
            results.find((r) => r.status === "rejected").reason.message,
            /access_(preview|policy)_conflict/,
          );
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_access_groups WHERE team_id=$1 AND name='Concurrent'`,
                [team],
              )
            ).rows[0].count,
            "1",
          );
        },
      );
      await t.test(
        "token expiry while waiting for publication lock cannot commit",
        async () => {
          const request = { type: "GROUP_CREATE", name: "Expired after lock" };
          const p = await preview(request);
          const { expiresAt, ...binding } = verifyPreviewToken(
            p.token,
            input.sessionSecret,
          );
          const short = {
            token: createPreviewToken(binding, input.sessionSecret, {
              ttlMS: 100,
            }),
          };
          const lock = await pool.connect();
          await lock.query("BEGIN");
          await lock.query(
            "LOCK TABLE team_access_groups IN SHARE ROW EXCLUSIVE MODE",
          );
          const pending = commit(request, short).then(
            (value) => ({ value }),
            (error) => ({ error }),
          );
          await new Promise((resolve) => setTimeout(resolve, 150));
          await lock.query("COMMIT");
          lock.release();
          const result = await pending;
          assert.match(result.error?.message ?? "", /access_preview_conflict/);
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_access_groups WHERE team_id=$1 AND name='Expired after lock'`,
                [team],
              )
            ).rows[0].count,
            "0",
          );
        },
      );
      await t.test(
        "duplicate normalized group name returns safe typed preview conflict",
        async () => {
          await assert.rejects(
            preview({ type: "GROUP_CREATE", name: " concurrent " }),
            /access_policy_conflict/,
          );
        },
      );
      await t.test("expiry during delegated non-actor membership lock rolls back edge audit receipt", async () => {
        const targetUser=(await fixtureQuery(`INSERT INTO users(email,username,display_name,email_verified_at)
          VALUES($1,$2,'Synthetic target',now()) RETURNING id`,["late-"+suffix+"@example.com","late_"+suffix.slice(-12)])).rows[0].id;
        const target=(await fixtureQuery(`INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'editor') RETURNING id`,[team,targetUser])).rows[0].id;
        const create={type:"GROUP_CREATE",name:"Delegated expiry"};
        const group=(await commit(create,await preview(create))).group;
        const request={type:"GROUP_MEMBER_ADD",groupID:group.id,targetMembershipID:target};
        const p=await preview(request);
        const {expiresAt,...binding}=verifyPreviewToken(p.token,input.sessionSecret);
        const locker=await pool.connect();
        await locker.query('BEGIN');
        await locker.query('SELECT id FROM team_memberships WHERE id=$1 FOR SHARE',[target]);
        const token=createPreviewToken(binding,input.sessionSecret,{ttlMS:2000});
        const deadline=verifyPreviewToken(token,input.sessionSecret).expiresAt;
        const idempotencyKey=randomUUID();
        const pending=store.access.commitAccessGroupChange({...input,request,token,idempotencyKey})
          .then(value=>({value}),error=>({error}));
        let waiting=false;
        try {
          for(let n=0;n<100;n++) {
            waiting=(await fixtureQuery(`SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
              AND wait_event_type='Lock' AND query LIKE '%SELECT id, user_id, role, epoch FROM team_memberships%FOR UPDATE%'`)).rowCount>0;
            if(waiting) break;
            await new Promise(resolve=>setTimeout(resolve,10));
          }
          if(waiting) await new Promise(resolve=>setTimeout(resolve,Math.max(0,deadline-Date.now()+30)));
        } finally { await locker.query('ROLLBACK');locker.release(); }
        const result=await pending;
        assert.equal(waiting,true,'commit must reach delegated FOR UPDATE after outer FOR SHARE');
        assert.match(result.error?.message ?? '',/access_preview_conflict/);
        assert.equal(result.value,undefined,'no successful notification result');
        assert.equal((await fixtureQuery('SELECT count(*) FROM team_access_group_members WHERE group_id=$1',[group.id])).rows[0].count,'0');
        assert.equal((await fixtureQuery(`SELECT count(*) FROM team_audit_events WHERE team_id=$1 AND action='group.member.added' AND metadata->>'groupID'=$2`,[team,group.id])).rows[0].count,'0');
        assert.equal((await fixtureQuery(`SELECT count(*) FROM team_access_mutation_receipts WHERE actor_user_id=$1 AND idempotency_key=$2`,[user,idempotencyKey])).rows[0].count,'0');
      });
      await t.test(
        "group add reports effective gain and delete reports committed loss",
        async () => {
          await fixtureQuery(
            `UPDATE vault_access_grants SET permission_mask=5,version=version+1 WHERE principal_id=$1 AND revoked_at IS NULL`,
            [group.id],
          );
          const add = {
            type: "GROUP_MEMBER_ADD",
            groupID: group.id,
            targetMembershipID: membership,
          };
          const p = await preview(add);
          assert.equal(p.details[0].gainedMask, 5); // Old direct grant has stale epoch.
          const result = await commit(add, p);
          assert.deepEqual(result.notificationCandidates, [
            {
              userID: user,
              vaultID: vault,
              resourceID: resource,
              gainedMask: 5,
              lostMask: 0,
            },
          ]);
          const version = Number(
            (
              await fixtureQuery(
                "SELECT version FROM team_access_groups WHERE id=$1",
                [group.id],
              )
            ).rows[0].version,
          );
          const del = {
            type: "GROUP_DELETE",
            groupID: group.id,
            expectedVersion: version,
          };
          const dp = await preview(del);
          assert.equal(dp.details[0].lostMask, 5);
          const deleted = await commit(del, dp);
          assert.equal(deleted.deleted, true);
          assert.equal(deleted.revokedGrants, 1);
          assert.equal(deleted.notificationCandidates[0].lostMask, 5);
        },
      );
      await t.test(
        "grant preview snapshot ID and revoke-only bulk audit remain exact",
        async () => {
          const second = randomUUID();
          await fixtureQuery(
            `INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class,policy_kind) VALUES($1,$2,$3,'general','HOST')`,
            [second, team, vault],
          );
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,membership_id,membership_epoch,target_kind,target_id,permission_mask,created_by_user_id) VALUES($1,$2,'USER',$3,$4,2,'RESOURCE',$5,1,$3)`,
            [team, vault, user, membership, second],
          );
          const grants = (
            await fixtureQuery(
              `SELECT id,version FROM vault_access_grants WHERE team_id=$1 AND vault_id=$2 AND principal_kind='USER' AND revoked_at IS NULL ORDER BY id`,
              [team, vault],
            )
          ).rows;
          const request = {
            changes: grants.map((g) => ({
              type: "GRANT_REVOKE",
              grantID: g.id,
              expectedVersion: Number(g.version),
            })),
          };
          const p = await store.access.previewAccessChange({
            ...input,
            request,
          });
          assert.equal(
            p.snapshotID,
            (await store.access.previewAccessChange({ ...input, request }))
              .snapshotID,
          );
          await fixtureQuery(
            `UPDATE team_policy_revisions SET revision=revision+1 WHERE team_id=$1`,
            [team],
          );
          const fresh = await store.access.previewAccessChange({
            ...input,
            request,
          });
          assert.notEqual(p.snapshotID, fresh.snapshotID);
          const result = await store.access.commitAccessChange({
            ...input,
            request,
            token: fresh.token,
            idempotencyKey: randomUUID(),
          });
          assert.equal(result.applied, 2);
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_audit_events WHERE team_id=$1 AND action='bulk_revoke.applied'`,
                [team],
              )
            ).rows[0].count,
            "1",
          );
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_audit_events WHERE team_id=$1 AND action='bulk_grant.applied'`,
                [team],
              )
            ).rows[0].count,
            "0",
          );
        },
      );
      await t.test(
        "1000 members and 5000 opaque resources stay bounded; delete 1001 overflow writes nothing",
        async () => {
          const big = (
            await commit(
              { type: "GROUP_CREATE", name: "Scale" },
              await preview({ type: "GROUP_CREATE", name: "Scale" }),
            )
          ).group;
          await fixtureQuery(
            `WITH created AS (INSERT INTO users(email,username,display_name,email_verified_at)
     SELECT 'surface-'||$1::text||'-'||n||'@example.com','s_'||$1::text||'_'||n,'Synthetic',now() FROM generate_series(1,1000)n RETURNING id)
     INSERT INTO team_memberships(team_id,user_id,role) SELECT $2,id,'viewer' FROM created`,
            [suffix.slice(-12), team],
          );
          await fixtureQuery(
            `INSERT INTO team_access_group_members(team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id)
     SELECT $1,$2,user_id,id,epoch,$3 FROM team_memberships WHERE team_id=$1 AND role='viewer'`,
            [team, big.id, user],
          );
          await fixtureQuery(
            `INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class,policy_kind)
     SELECT gen_random_uuid(),$1,$2,'general','HOST' FROM generate_series(1,5000)`,
            [team, vault],
          );
          const members = await service.listAccessGroupMembers(
            session,
            team,
            big.id,
            { limit: 50 },
          );
          assert.equal(members.rows.length, 50);
          assert.ok(members.nextCursor);
          const resources = await service.listAccessResources(
            session,
            team,
            vault,
            { limit: 50 },
          );
          assert.equal(resources.rows.length, 50);
          assert.ok(resources.nextCursor);
          const none = await service.listAccessResources(session, team, vault, {
            limit: 50,
            kind: "FOLDER",
            cursor: resources.nextCursor,
          });
          assert.deepEqual(none, { rows: [], nextCursor: null });
          for (const [label, sql, args] of [
            [
              "members",
              `SELECT edge.id,edge.group_id AS "groupID",edge.user_id AS "userID",edge.membership_id AS "membershipID",
        edge.membership_epoch AS "membershipEpoch",edge.version FROM team_access_group_members AS edge
        JOIN team_memberships AS member ON member.id=edge.membership_id AND member.team_id=edge.team_id
          AND member.user_id=edge.user_id AND member.epoch=edge.membership_epoch AND member.revoked_at IS NULL
        WHERE edge.team_id=$1 AND edge.group_id=$2 AND edge.removed_at IS NULL
        AND ($3::uuid IS NULL OR edge.id>$3) ORDER BY edge.id LIMIT $4`,
              [team, big.id, members.nextCursor, 51],
            ],
            [
              "resources",
              `SELECT id,team_id AS "teamID",vault_id AS "vaultID",policy_kind AS "policyKind",
        parent_folder_id AS "parentFolderID",resource_version AS "resourceVersion"
        FROM vault_resource_registry WHERE team_id=$1 AND vault_id=$2 AND deleted_at IS NULL
        AND policy_kind IS NOT NULL AND ($3::uuid IS NULL OR id>$3)
        AND ($4::text IS NULL OR policy_kind=$4) ORDER BY id LIMIT $5`,
              [team, vault, resources.nextCursor, "HOST", 51],
            ],
          ]) {
            const plan = (
              await fixtureQuery(
                "EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + sql,
                args,
              )
            ).rows[0]["QUERY PLAN"][0];
            assert.ok(plan.Plan["Actual Rows"] <= 51);
            assert.ok(plan["Execution Time"] < 1000);
            console.log("surface scale " + label + ": " + JSON.stringify(plan));
          }
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,target_kind,target_id,permission_mask,created_by_user_id)
     SELECT $1,$2,'GROUP',$3,'RESOURCE',id,1,$4 FROM vault_resource_registry WHERE vault_id=$2 ORDER BY id LIMIT 1001`,
            [team, vault, big.id, user],
          );
          const request = {
            type: "GROUP_DELETE",
            groupID: big.id,
            expectedVersion: 1,
          };
          await assert.rejects(
            preview(request),
            (e) =>
              e.message === "group_grants_must_be_revoked_first" &&
              e.safeCount === "1001+",
          );
          assert.equal(
            (
              await fixtureQuery(
                "SELECT deleted_at FROM team_access_groups WHERE id=$1",
                [big.id],
              )
            ).rows[0].deleted_at,
            null,
          );
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM vault_access_grants WHERE principal_id=$1 AND revoked_at IS NULL`,
                [big.id],
              )
            ).rows[0].count,
            "1001",
          );
        },
      );
      await t.test(
        "empty group deletion pages affected grants without fake users",
        async () => {
          const create = { type: "GROUP_CREATE", name: "Empty impact" };
          const empty = (await commit(create, await preview(create))).group;
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,target_kind,target_id,permission_mask,created_by_user_id)
          SELECT $1,$2,'GROUP',$3,'RESOURCE',id,5,$4 FROM vault_resource_registry WHERE vault_id=$2 ORDER BY id LIMIT 51`,
            [team, vault, empty.id, user],
          );
          const request = {
            type: "GROUP_DELETE",
            groupID: empty.id,
            expectedVersion: 1,
          };
          const first = await preview(request);
          assert.deepEqual(first.details, []);
          assert.equal(first.counts.pairs, 0);
          assert.equal(first.counts.affectedGrants, 51);
          assert.equal(first.affectedGrants.length, 50);
          assert.equal(first.nextCursor, "50");
          const second = await store.access.previewAccessGroupChange({
            ...input,
            request,
            cursor: first.nextCursor,
          });
          assert.equal(second.snapshotID, first.snapshotID);
          assert.deepEqual(second.details, []);
          assert.equal(second.affectedGrants.length, 1);
          assert.equal(second.nextCursor, null);
          assert.deepEqual(
            Object.keys(second.affectedGrants[0]).sort(),
            [
              "grantID",
              "permissionMask",
              "targetID",
              "targetKind",
              "vaultID",
              "version",
            ].sort(),
          );
          assert.equal(second.affectedGrants[0].permissionMask, 5);
          assert.equal(second.affectedGrants[0].version, 1);
          const rename = {
            type: "GROUP_RENAME",
            groupID: empty.id,
            expectedVersion: 1,
            name: "Empty renamed",
          };
          const rp = await preview(rename);
          assert.deepEqual(rp.affectedGrants, []);
          assert.equal(rp.counts.affectedGrants, 0);
          const result = await commit(request, second);
          assert.equal(result.revokedGrants, 51);
          assert.deepEqual(result.notificationCandidates, []);
        },
      );
      await t.test(
        "another affected ACTIVE Vault blocks a PREPARING context atomically",
        async () => {
          const other = (
            await fixtureQuery(
              `INSERT INTO shared_vaults(team_id,name,created_by_user_id,format_state,format_schema_version) VALUES($1,'Other',$2,'V2_PREPARING',2) RETURNING id`,
              [team, user],
            )
          ).rows[0].id;
          const request = { type: "GROUP_CREATE", name: "Mixed" };
          const mixed = (await commit(request, await preview(request))).group;
          await fixtureQuery(
            `INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,target_kind,target_id,permission_mask,created_by_user_id) VALUES($1,$2,'GROUP',$3,'VAULT',$2,1,$4)`,
            [team, other, mixed.id, user],
          );
          const add = {
            type: "GROUP_MEMBER_ADD",
            groupID: mixed.id,
            targetMembershipID: membership,
          };
          const p = await preview(add);
          await fixtureQuery(
            `UPDATE shared_vaults SET format_state='V2_ACTIVE' WHERE id=$1`,
            [other],
          );
          await assert.rejects(preview(add), /crypto_publication_required/);
          await assert.rejects(commit(add, p), /crypto_publication_required/);
          assert.equal(
            (
              await fixtureQuery(
                `SELECT count(*) FROM team_access_group_members WHERE group_id=$1`,
                [mixed.id],
              )
            ).rows[0].count,
            "0",
          );
        },
      );
      await t.test(
        "READY and ACTIVE are descriptive contexts with publication blocker",
        async () => {
          // Synthetic fixture only; production migration is never invoked.
          for (const state of ["V2_READY", "V2_ACTIVE"]) {
            await fixtureQuery(
              `UPDATE shared_vaults SET format_state=$2 WHERE id=$1`,
              [vault, state],
            );
            const context = await service.getAccessContext(
              session,
              team,
              vault,
            );
            assert.equal(context.policyMutationAvailable, false);
            assert.ok(context.blockers.includes("crypto_publication_required"));
            await assert.rejects(
              preview({ type: "GROUP_CREATE", name: "Denied" }),
              /crypto_publication_required/,
            );
            await assert.rejects(
              store.access.previewAccessChange({
                ...input,
                request: {
                  changes: [
                    {
                      type: "GRANT_CREATE",
                      principalKind: "USER",
                      principalID: user,
                      targetKind: "RESOURCE",
                      targetID: resource,
                      permissionMask: 1,
                    },
                  ],
                },
              }),
              /crypto_publication_required/,
            );
            await assert.rejects(
              service.listAccessResources(session, team, vault),
              /crypto_publication_required/,
            );
          }
        },
      );
      await t.test(
        "published Team snapshot freezes unrelated create and rename; discarded attempts do not",
        async () => {
          await fixtureQuery(
            `UPDATE shared_vaults SET format_state='V2_PREPARING' WHERE id=$1`,
            [vault],
          );
          const other = (
            await fixtureQuery(
              `INSERT INTO shared_vaults(team_id,name,created_by_user_id,format_state,format_schema_version) VALUES($1,'Published',$2,'V2_PREPARING',2) RETURNING id`,
              [team, user],
            )
          ).rows[0].id;
          const request = { type: "GROUP_CREATE", name: "Unrelated" };
          const group = (await commit(request, await preview(request))).group;
          const makeAttempt = async (state) => {
            const id = randomUUID();
            await fixtureQuery(
              `INSERT INTO vault_migration_attempts(id,team_id,vault_id,actor_user_id,actor_device_id,state,source_revision,source_hash,snapshot_hash,snapshot,policy,resources,scope,manifest,manifest_hash)
      VALUES($1,$2,$3,$4,$5,$6,1,'synthetic',$7,'{}','[]','[{}]','{}','{}',$7)`,
              [id, team, other, user, device, state, "a".repeat(64)],
            );
            return id;
          };
          await makeAttempt("DISCARDED");
          const next = { type: "GROUP_CREATE", name: "Unrelated next" };
          const p = await preview(next);
          const publication = await pool.connect();
          await publication.query("BEGIN");
          await publication.query(
            "LOCK TABLE team_access_groups IN SHARE ROW EXCLUSIVE MODE",
          );
          let settled = false;
          const concurrent = commit(next, p).then(
            (value) => {
              settled = true;
              return { value };
            },
            (error) => {
              settled = true;
              return { error };
            },
          );
          let waiting = false;
          for (let n = 0; n < 100; n++) {
            waiting =
              (
                await fixtureQuery(`SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
      AND wait_event_type='Lock' AND query='LOCK TABLE team_access_groups IN ROW EXCLUSIVE MODE'`)
              ).rowCount > 0;
            if (waiting) break;
            await new Promise((resolve) => setTimeout(resolve, 10));
          }
          assert.equal(waiting, true);
          assert.equal(settled, false);
          const ready = await makeAttempt("V2_READY");
          await publication.query("COMMIT");
          publication.release();
          assert.match(
            (await concurrent).error.message,
            /crypto_publication_required/,
          );
          await assert.rejects(preview(next), /crypto_publication_required/);
          await assert.rejects(commit(next, p), /crypto_publication_required/);
          const context = await service.getAccessContext(session, team, vault);
          assert.equal(context.policyMutationAvailable, true);
          assert.equal(context.groupMutationAvailable, false);
          assert.ok(context.blockers.includes("crypto_publication_required"));
          await fixtureQuery(
            `UPDATE vault_migration_attempts SET state='DISCARDED' WHERE id=$1`,
            [ready],
          );
          await preview(next);
          const active = await makeAttempt("V2_ACTIVE");
          await fixtureQuery(
            `UPDATE shared_vaults SET format_state='V2_ACTIVE',active_publication_attempt_id=$2 WHERE id=$1`,
            [other, active],
          );
          await assert.rejects(preview(next), /crypto_publication_required/);
          await assert.rejects(
            preview({
              type: "GROUP_RENAME",
              groupID: group.id,
              expectedVersion: 1,
              name: "Changed",
            }),
            /crypto_publication_required/,
          );
        },
      );
    } finally {
      await pool.end();
    }
  },
);

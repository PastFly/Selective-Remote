#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
cd "$GITHUB_WORKSPACE"
git merge-base --is-ancestor b31462894beef06677385ecab75740174bc3253f HEAD
source_head=$(git rev-parse HEAD)
[[ "$source_head" == "$GITHUB_SHA" ]]
git diff --exit-code HEAD -- cloud
mkdir -p /tmp/sr-controller-acceptance/results
exec > >(tee /tmp/sr-controller-acceptance/results/acceptance.log) 2>&1
echo "PROTOTYPE_HEAD=$source_head BASE_HEAD=b31462894beef06677385ecab75740174bc3253f"
echo 'ENVIRONMENT=EPHEMERAL_GITHUB_HOSTED_RUNNER'
root=/opt/selective-remote-controller
state=/var/lib/selective-remote-controller
cloud=/opt/selective-remote/cloud
pgmount=/mnt/sr-acceptance-pg
mkdir -p "$cloud" "$state/publication" "$root" "$pgmount" /var/backups/sr-acceptance
chmod 755 /opt /opt/selective-remote
chmod 700 "$root"
cp -a "$GITHUB_WORKSPACE/cloud/." "$cloud/"
chown -R root:root "$cloud"
rm -rf "$cloud/node_modules"
cat > "$cloud/.env" <<'ENV'
POSTGRES_DB=sraccept
POSTGRES_USER=sraccept
POSTGRES_PASSWORD=synthetic-database-password
DATABASE_URL=postgresql://sraccept:synthetic-database-password@postgres:5432/sraccept
SESSION_TOKEN_PEPPER=synthetic-session-pepper-000000000000000000000000
ABUSE_TOKEN_PEPPER=synthetic-abuse-pepper-11111111111111111111111111
PASSWORD_RESET_TOKEN_PEPPER=synthetic-password-pepper-2222222222222222222222
TEAM_INVITATION_TOKEN_PEPPER=synthetic-invitation-pepper-33333333333333333333
TEAM_OUTBOX_ENCRYPTION_KEY=synthetic-outbox-pepper-444444444444444444444444
EMAIL_VERIFICATION_TOKEN_PEPPER=synthetic-email-pepper-555555555555555555555555
PROXY_SHARED_SECRET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CLOUD_PUBLIC_ORIGIN=https://localhost
CLOUD_PUBLIC_HOST=localhost
ACME_EMAIL=test@example.test
ALLOW_REGISTRATION=false
PUBLICATION_ENVIRONMENT=staging
PUBLICATION_READER_ENABLED=false
WHOLE_PUBLICATION_ENABLED=false
ENV
chmod 600 "$cloud/.env"
# Synthetic localhost-only proxy configuration; production files remain untouched.
cat > "$cloud/compose.loopback-test.yaml" <<'LOOP'
services:
  caddy:
    ports: !override
      - "127.0.0.1:443:443"
LOOP
cat > "$cloud/Caddyfile.443-only" <<'CADDY'
https://localhost:443 {
  tls internal
  respond "isolated controller acceptance" 200
}
CADDY
chmod 644 "$cloud/compose.loopback-test.yaml" "$cloud/Caddyfile.443-only"
# Restrict all possible test ingress even if a future regression reaches up.
iptables -I DOCKER-USER -i eth0 -j DROP
iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# The reviewed bind guard requires an actual distinct mounted filesystem.
truncate -s 768M /tmp/sr-controller-acceptance/test-pg.img
mkfs.ext4 -q -F /tmp/sr-controller-acceptance/test-pg.img
mount -o loop /tmp/sr-controller-acceptance/test-pg.img "$pgmount"
source_device=$(findmnt -nr -M "$pgmount" -o SOURCE)
uid=$(docker run --rm --entrypoint id postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef -u postgres)
gid=$(docker run --rm --entrypoint id postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef -g postgres)
install -d -m 0700 -o "$uid" -g "$gid" "$pgmount/data"
docker build --quiet --label "org.opencontainers.image.revision=$source_head" -t sr-acceptance-candidate "$cloud" >/tmp/sr-controller-acceptance/image-build.log
image=$(docker image inspect --format '{{.Id}}' sr-acceptance-candidate)
[[ $image =~ ^sha256:[a-f0-9]{64}$ ]]
docker pull node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b >/dev/null
export POSTGRES_DATA_MOUNT_ROOT="$pgmount" POSTGRES_DATA_HOST_PATH="$pgmount/data" POSTGRES_DATA_EXPECTED_SOURCE="$source_device" POSTGRES_DATA_EXPECTED_FSTYPE=ext4 POSTGRES_DATA_UID="$uid" POSTGRES_DATA_GID="$gid" PUBLICATION_IMAGE_DIGEST="$image" PUBLICATION_FENCE_DIRECTORY="$state/publication"
compose=(docker compose --project-name cloud --project-directory "$cloud" --env-file "$cloud/.env" -f "$cloud/compose.yaml" -f "$cloud/compose.443-only.yaml" -f "$cloud/compose.small-host.yaml" -f "$cloud/compose.publication-fence.yaml" -f "$cloud/compose.loopback-test.yaml" -f "$cloud/compose.postgres-bind.yaml")
# The test starts only PostgreSQL; Cloud and Caddy must remain down throughout.
"${compose[@]}" up -d postgres
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-postgres-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-postgres-1) == healthy ]]
touch "$state/publication/journal"
chmod 644 "$state/publication/journal"
docker run --rm --network cloud_private --env-file "$cloud/.env" --entrypoint node "$image" scripts/migrate.mjs >/tmp/sr-controller-acceptance/migrations.log
docker exec cloud-postgres-1 psql -U sraccept -d sraccept -v ON_ERROR_STOP=1 -c "INSERT INTO users(id,email,username,email_verified_at) VALUES('11111111-1111-4111-8111-111111111111','test@example.test','synthetic_test',now()); INSERT INTO devices(id,user_id,name,platform) VALUES('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','synthetic-device','web'); INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES('11111111-1111-4111-8111-111111111111',1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA');" >/dev/null
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/old.dump
# Arm the real database barrier and independently retained history using candidate source.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {randomUUID} from "node:crypto"; import {installV1CommitFence} from "./src/v1-commit-fence.mjs"; import {readV1VaultState} from "./src/v1-data-fence.mjs"; import {MigrationFence} from "./src/migration-fence.mjs"; const pool=new pg.Pool({connectionString:process.env.DATABASE_URL}); try { await installV1CommitFence(pool); const f=new MigrationFence("/publication-fence/journal"); await f.append({version:2,type:"V1_BASELINE",baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>pool.query(s,v))}); await f.append({version:2,type:"V1_WRITER_FLOOR",writerProtocol:1}); console.log("INDEPENDENT_JOURNAL_ARMED"); } finally {await pool.end();}'
cloudgid=$(docker run --rm --entrypoint id "$image" -g)
chown root:"$cloudgid" "$state/publication" "$state/publication/journal"
chmod 770 "$state/publication"
chmod 660 "$state/publication/journal"
# Install a separate root-owned controller copy and bundled runtime exactly as launcher expects.
id=$(docker create --entrypoint /bin/true "$image")
docker cp "$id:/app/." "$root/"
docker rm "$id" >/dev/null
mkdir -p "$root/runtime/node-v22.18.0-linux-x64/bin"
install -m 0755 "$(readlink -f "$(command -v node)")" "$root/runtime/node-v22.18.0-linux-x64/bin/node"
chmod 755 "$root/scripts" "$root/runtime" "$root/runtime/node-v22.18.0-linux-x64" "$root/runtime/node-v22.18.0-linux-x64/bin"
chmod 755 "$root/scripts/staging-controller.sh"
chmod 644 "$root/scripts/verify-staging-controller.mjs"
(cd "$root"; sha256sum runtime/node-v22.18.0-linux-x64/bin/node > runtime-node.sha256; find . -type f ! -name bundle.sha256 ! -name settings.json -print0 | sort -z | xargs -0 sha256sum | sed 's#  \./#  #' > bundle.sha256)
chmod 600 "$root/runtime-node.sha256" "$root/bundle.sha256"
controller_digest=$(sha256sum "$root/bundle.sha256" | cut -d ' ' -f 1)
composefiles=("$cloud/compose.yaml" "$cloud/compose.443-only.yaml" "$cloud/compose.small-host.yaml" "$cloud/compose.publication-fence.yaml" "$cloud/compose.loopback-test.yaml" "$cloud/compose.postgres-bind.yaml")
composejson=$(for f in "${composefiles[@]}"; do jq -cn --arg path "$f" --arg hash "$(sha256sum "$f"|cut -d ' ' -f 1)" '{path:$path,sha256:$hash}'; done | jq -s .)
jq -n --arg sha "$source_head" --arg image "$image" --arg ctrl "$controller_digest" --arg envhash "$(sha256sum "$cloud/.env"|cut -d ' ' -f 1)" --arg root "$pgmount" --arg src "$source_device" --arg uid "$uid" --arg gid "$gid" --argjson compose "$composejson" '{version:1,sourceSHA:$sha,imageDigest:$image,controllerDigest:$ctrl,cloudDirectory:"/opt/selective-remote/cloud",envPath:"/opt/selective-remote/cloud/.env",envDigest:$envhash,network:"cloud_private",fencePath:"/var/lib/selective-remote-controller/publication/journal",backupDirectory:"/var/backups/sr-acceptance",composeFiles:$compose,storage:{POSTGRES_DATA_MOUNT_ROOT:$root,POSTGRES_DATA_HOST_PATH:($root+"/data"),POSTGRES_DATA_EXPECTED_SOURCE:$src,POSTGRES_DATA_EXPECTED_FSTYPE:"ext4",POSTGRES_DATA_UID:$uid,POSTGRES_DATA_GID:$gid}}' > "$root/settings.json"
chmod 600 "$root/settings.json"
# Positive baseline uses the independently installed checker, same Docker mounts and PG/journal.
docker run --rm --pull=never --network cloud_private --read-only --cap-drop ALL --security-opt no-new-privileges --env-file "$cloud/.env" -e NODE_ENV=production -e PUBLICATION_FENCE_PATH=/publication-fence/journal --mount "type=bind,src=$root,dst=/controller,readonly" --mount "type=bind,src=$state/publication,dst=/publication-fence,readonly" node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b node /controller/scripts/check-deployment-compatibility.mjs --candidate /controller/deployment-compatibility.json > /tmp/sr-controller-acceptance/results/baseline.json
jq -e '.compatible == true and .writerFloor == 1' /tmp/sr-controller-acceptance/results/baseline.json >/dev/null
echo 'INSTALLED_CHECKER_VALID_BASELINE=PASS'
# Provision an isolated test-only session with the real session-token hash.
docker run --rm --network cloud_private --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {hashSessionToken} from "./src/security.mjs"; const p=new pg.Pool({connectionString:process.env.DATABASE_URL}); try{await p.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+make_interval(days=>1))",["33333333-3333-4333-8333-333333333333","11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",hashSessionToken("a".repeat(43),process.env.SESSION_TOKEN_PEPPER)]);}finally{await p.end();}'
docker pull caddy:2.9.1-alpine@sha256:b4e3952384eb9524a887633ce65c752dd7c71314d2c2acf98cd5c715aaa534f0 >/dev/null
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/positive-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/positive-controller.log
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]]
[[ $(docker inspect --format '{{.State.Running}}' cloud-caddy-1) == true ]]
docker exec cloud-cloud-1 node -e 'fetch("http://127.0.0.1:8080/readyz").then(async r=>{if(!r.ok)throw Error("not_ready_"+r.status);console.log("INSTALLED_CONTROLLER_CLOUD_READYZ=PASS")}).catch(e=>{console.error(e.message);process.exit(1)})'
echo 'INSTALLED_CONTROLLER_NORMAL_START=PASS'
# Test-only actual store creation against a protected journal. This is not SMTP
# or public registration acceptance, and must not unlock the HTTP write stop.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg";import {randomUUID} from "node:crypto";import {PostgresStore} from "./src/postgres-store.mjs";import {MigrationFence} from "./src/migration-fence.mjs";const p=new pg.Pool({connectionString:process.env.DATABASE_URL});try{const owner="11111111-1111-4111-8111-111111111111",team=randomUUID();await p.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,$2,$3)",[team,"TEST-ONLY-CODEX",owner]);await p.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,$3)",[team,owner,"owner"]);const f=new MigrationFence("/publication-fence/journal"),store=new PostgresStore(null,p,{v1Fence:f});const user=await store.createUser({email:"prototype-create@example.test",username:"prototype_create",displayName:"Synthetic",passwordHash:"synthetic",device:{id:randomUUID(),name:"Synthetic",platform:"web",appVersion:"test",publicKey:null},verificationHash:"b".repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});const v=await store.createSharedVault({actorUserID:owner,teamID:team,name:"TEST-ONLY-CODEX-VAULT",idempotencyKey:"prototype-create-team-vault"});if(!user.id||!v.vault.id||(await f.snapshot()).v1Pending.length)throw Error("empty_creation_failed");console.log("PROTOTYPE_EMPTY_PERSONAL_AND_TEAM_JOURNALED=PASS")}finally{await p.end()}'
# Retain a genuine post-fence backup, then commit revision 2 through the real store.
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/post-floor.dump
# Write through the actual Cloud HTTP route using the supported framed protocol.
docker exec cloud-cloud-1 node --input-type=module -e 'const headers={Authorization:"Bearer "+"a".repeat(43),"Content-Type":"application/json","x-selective-v1-write-fence":"1"};const envelope={baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:"synthetic"},ciphertext:"bmV3",nonce:"A".repeat(16),authTag:"A".repeat(22),contentHash:"A".repeat(43)};const r=await fetch("http://127.0.0.1:8080/v1/vault",{method:"PUT",headers,body:JSON.stringify({protocol:"framed-v1",envelope})});const b=await r.json();if(r.status!==503||b.error!=="vault_write_temporarily_unavailable")throw Error("expected_write_stop_"+r.status);const legacy=await fetch("http://127.0.0.1:8080/v1/vault",{method:"PUT",headers:{Authorization:headers.Authorization,"Content-Type":"application/json"},body:"{}"});if(legacy.status!==426)throw Error("legacy_reject_failed_"+legacy.status);console.log("HTTP_WRITE_STOP_AND_LEGACY_REJECTION=PASS")'
# Test-only direct store operation in disposable DB, for controller history tests;
# it does not prove or override production HTTP write acceptance.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg";import {PostgresStore} from "./src/postgres-store.mjs";import {MigrationFence} from "./src/migration-fence.mjs";const p=new pg.Pool({connectionString:process.env.DATABASE_URL});try{const s=new PostgresStore(null,p,{v1Fence:new MigrationFence("/publication-fence/journal")});const r=await s.putVault("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",{baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:"synthetic"},ciphertext:"bmV3",nonce:"A".repeat(16),authTag:"A".repeat(22),contentHash:"A".repeat(43)});if(r.revision!==2||r.conflict)throw Error("test_store_write_failed");console.log("TEST_ONLY_DIRECT_STORE_REVISION_2=PASS")}finally{await p.end()}' 
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision||':'||ciphertext FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == '2:bmV3' ]]
cp "$state/publication/journal" /tmp/sr-controller-acceptance/journal-after-http
journal_after_http=$(sha256sum "$state/publication/journal" | cut -d ' ' -f 1)
oldpid=$(docker inspect --format '{{.State.Pid}}' cloud-cloud-1)
docker kill cloud-cloud-1 >/dev/null
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/restart-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/restart-controller.log
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]]
[[ $(docker inspect --format '{{.State.Pid}}' cloud-cloud-1) != "$oldpid" ]]
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision||':'||ciphertext FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == '2:bmV3' ]]
[[ $(sha256sum "$state/publication/journal" | cut -d ' ' -f 1) == "$journal_after_http" ]]
echo 'CLOUD_CRASH_CONTROLLER_RESTART_DATA_PRESERVED=PASS'
# Build an actual pre-fence Cloud binary from the immutable historical commit.
legacy_source=f728db3592886f831cf0f8d7a9119d883d904120
mkdir -p /tmp/sr-controller-acceptance/legacy-source
git archive "$legacy_source" cloud | tar -x -C /tmp/sr-controller-acceptance/legacy-source
docker build --quiet --label "org.opencontainers.image.revision=$legacy_source" -t sr-acceptance-legacy /tmp/sr-controller-acceptance/legacy-source/cloud >/tmp/sr-controller-acceptance/legacy-image-build.log
legacy_image=$(docker image inspect --format '{{.Id}}' sr-acceptance-legacy)
cp "$root/settings.json" /tmp/sr-controller-acceptance/current-settings.json
jq --arg sha "$legacy_source" --arg img "$legacy_image" '.sourceSHA=$sha | .imageDigest=$img' "$root/settings.json" > "$root/settings.next"
chmod 600 "$root/settings.next"
mv "$root/settings.next" "$root/settings.json"
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/old-image-controller.log 2>&1
legacy_status=$?
set -e
install -m 0600 /tmp/sr-controller-acceptance/current-settings.json "$root/settings.next"
mv "$root/settings.next" "$root/settings.json"
[[ $legacy_status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/old-image-controller.log
grep -q '^deployment_code_floor$' /tmp/sr-controller-acceptance/results/old-image-controller.log
! grep -q '"stage":"close-traffic"' /tmp/sr-controller-acceptance/results/old-image-controller.log
[[ $(docker inspect --format '{{.Image}}' cloud-cloud-1) == "$image" ]]
[[ $(docker inspect --format '{{.State.Running}}' cloud-cloud-1) == true ]]
echo 'OLD_CLOUD_IMAGE_REJECTED=PASS'
"${compose[@]}" stop cloud caddy >/dev/null
# Inject a lost COMMIT reply in an otherwise real V1 writer and durable PG transaction.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {PostgresStore} from "./src/postgres-store.mjs"; import {MigrationFence} from "./src/migration-fence.mjs"; const real=new pg.Pool({connectionString:process.env.DATABASE_URL}),f=new MigrationFence("/publication-fence/journal"); let injected=false; const pool={async connect(){const c=await real.connect();return {async query(sql,values){if(sql==="COMMIT"&&!injected){injected=true;await c.query(sql,values);throw Error("synthetic_lost_commit_reply")}return c.query(sql,values)},release(){c.release()}}}}; try{const store=new PostgresStore(null,pool,{v1Fence:f}); try{await store.putVault("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",{baseRevision:2,envelopeVersion:1,wrappedKey:{algorithm:"synthetic"},ciphertext:"cmV2Mw",nonce:"A".repeat(16),authTag:"A".repeat(22),contentHash:"A".repeat(43)});throw Error("missing_injection")}catch(e){if(e.message!=="synthetic_lost_commit_reply")throw e} const row=await real.query("SELECT revision,ciphertext FROM personal_vaults WHERE user_id=$1",["11111111-1111-4111-8111-111111111111"]);if(Number(row.rows[0].revision)!==3||row.rows[0].ciphertext!=="cmV2Mw"||(await f.snapshot()).v1Pending.length!==1)throw Error("ambiguous_not_retained"); console.log("LOST_COMMIT_REPLY_PENDING=PASS")}finally{await real.end()}'
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/ambiguous-controller.log 2>&1
ambiguous_status=$?
set -e
[[ $ambiguous_status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/ambiguous-controller.log
grep -q '^deployment_fence_pending$' /tmp/sr-controller-acceptance/results/ambiguous-controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/ambiguous-controller.log
echo 'CONTROLLER_REJECTS_AMBIGUOUS_COMMIT=PASS'
# Resolve only by independent durable outcome readback in a new process.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {MigrationFence} from "./src/migration-fence.mjs"; import {PublicationFenceCoordinator,readCommittedV1Outcome} from "./src/publication-fence-coordinator.mjs"; const pool=new pg.Pool({connectionString:process.env.DATABASE_URL}),fence=new MigrationFence("/publication-fence/journal"); try{const pending=(await fence.snapshot()).v1Pending;if(pending.length!==1)throw Error("pending_missing");const result=await new PublicationFenceCoordinator({fence}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>pool.query(sql,values),intent})});if(result.status!=="confirmed"||(await fence.snapshot()).v1Pending.length)throw Error("reconciliation_failed"); console.log("AMBIGUOUS_COMMIT_DURABLY_RECONCILED=PASS")}finally{await pool.end()}'
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/reconciled-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/reconciled-controller.log
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]]
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision||':'||ciphertext FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == '3:cmV2Mw' ]]
echo 'CONTROLLER_STARTS_AFTER_DURABLE_RECONCILIATION=PASS'
"${compose[@]}" stop cloud caddy >/dev/null
# Ensure the independent checker accepts the committed state before any restore.
docker run --rm --pull=never --network cloud_private --read-only --cap-drop ALL --security-opt no-new-privileges --env-file "$cloud/.env" -e NODE_ENV=production -e PUBLICATION_FENCE_PATH=/publication-fence/journal --mount "type=bind,src=$root,dst=/controller,readonly" --mount "type=bind,src=$state/publication,dst=/publication-fence,readonly" node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b node /controller/scripts/check-deployment-compatibility.mjs --candidate /controller/deployment-compatibility.json > /tmp/sr-controller-acceptance/results/new-baseline.json
jq -e '.compatible == true and .writerFloor == 1' /tmp/sr-controller-acceptance/results/new-baseline.json >/dev/null
# Restore the post-fence but old revision; the real controller must reject it.
docker exec -i cloud-postgres-1 pg_restore -U sraccept -d sraccept --clean --if-exists --exit-on-error --no-owner --no-acl < /tmp/sr-controller-acceptance/post-floor.dump >/tmp/sr-controller-acceptance/post-floor-restore.log 2>&1
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == 1 ]]
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/post-floor-controller.log 2>&1
post_status=$?
set -e
cat /tmp/sr-controller-acceptance/results/post-floor-controller.log
[[ $post_status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/post-floor-controller.log
grep -q '^deployment_compatibility_failed$' /tmp/sr-controller-acceptance/results/post-floor-controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/post-floor-controller.log
docker run --rm --network cloud_private --read-only --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --mount "type=bind,src=$root,dst=/controller,readonly" --mount "type=bind,src=$state/publication,dst=/publication-fence,readonly" --entrypoint node node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b --input-type=module -e 'try { const {default:pg}=await import("/controller/node_modules/pg/lib/index.js"); const {loadConfig}=await import("/controller/src/config.mjs"); const {MigrationFence}=await import("/controller/src/migration-fence.mjs"); const {currentCapabilities,verifyDeploymentCompatibility}=await import("/controller/src/deployment-compatibility.mjs"); const c=loadConfig(),p=new pg.Pool({connectionString:c.databaseURL,max:1}); try {console.log(await verifyDeploymentCompatibility({query:(q,v)=>p.query(q,v),fence:new MigrationFence(c.deployment.fencePath),candidate:currentCapabilities}));} finally {await p.end();} } catch(e) { console.log("DIAGNOSTIC_NAME="+e.name); console.log("DIAGNOSTIC_CODE="+(e.code??"none")); console.log("DIAGNOSTIC_MESSAGE="+e.message); process.exit(1); }' | tee /tmp/sr-controller-acceptance/results/post-floor-diagnostic.log || true
grep -q '^DIAGNOSTIC_MESSAGE=deployment_v1_data_mismatch$' /tmp/sr-controller-acceptance/results/post-floor-diagnostic.log
echo 'INSTALLED_CONTROLLER_POST_FLOOR_ROLLBACK_REJECTED=PASS'
# A restore from before fence activation must not be served against retained successor journal.
docker exec -i cloud-postgres-1 pg_restore -U sraccept -d sraccept --clean --if-exists --exit-on-error --no-owner --no-acl < /tmp/sr-controller-acceptance/old.dump >/tmp/sr-controller-acceptance/restore.log 2>&1
before=$(sha256sum "$state/publication/journal" | cut -d ' ' -f 1)
for probe in / /opt "$root" "$root/settings.json" "$root/bundle.sha256" "$root/runtime-node.sha256" "$root/scripts" "$root/scripts/staging-controller.sh" "$root/scripts/verify-staging-controller.mjs" "$root/runtime" "$root/runtime/node-v22.18.0-linux-x64" "$root/runtime/node-v22.18.0-linux-x64/bin" "$root/runtime/node-v22.18.0-linux-x64/bin/node" /var /var/lib "$state" "$state/publication" /var/backups /var/backups/sr-acceptance /opt/selective-remote "$cloud" "$cloud/.env" "${composefiles[@]}"; do
  stat -c 'PATH=%n UID=%u MODE=%a' "$probe"
  printf 'REALPATH=%s\n' "$(realpath "$probe")"
done
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/controller.log 2>&1
status=$?
set -e
cat /tmp/sr-controller-acceptance/results/controller.log
if grep -q '^deployment_compatibility_failed$' /tmp/sr-controller-acceptance/results/controller.log; then
  docker run --rm --network cloud_private --read-only --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --mount "type=bind,src=$root,dst=/controller,readonly" --mount "type=bind,src=$state/publication,dst=/publication-fence,readonly" --entrypoint node node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b --input-type=module -e 'try { const {default:pg}=await import("/controller/node_modules/pg/lib/index.js"); const {loadConfig}=await import("/controller/src/config.mjs"); const {MigrationFence}=await import("/controller/src/migration-fence.mjs"); const {currentCapabilities,verifyDeploymentCompatibility}=await import("/controller/src/deployment-compatibility.mjs"); const c=loadConfig(),p=new pg.Pool({connectionString:c.databaseURL,max:1}); try {console.log(await verifyDeploymentCompatibility({query:(q,v)=>p.query(q,v),fence:new MigrationFence(c.deployment.fencePath),candidate:currentCapabilities}));} finally {await p.end();} } catch(e) { console.log("DIAGNOSTIC_NAME="+e.name); console.log("DIAGNOSTIC_CODE="+(e.code??"none")); console.log("DIAGNOSTIC_MESSAGE="+e.message); process.exit(1); }' | tee /tmp/sr-controller-acceptance/results/diagnostic.log || true
fi
[[ $status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/controller.log
grep -q '^deployment_compatibility_failed$' /tmp/sr-controller-acceptance/results/controller.log
grep -q '^DIAGNOSTIC_MESSAGE=v1_writer_fence_missing$' /tmp/sr-controller-acceptance/results/diagnostic.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/controller.log
[[ $(sha256sum "$state/publication/journal" | cut -d ' ' -f 1) == "$before" ]]
[[ $(docker ps --filter label=com.docker.compose.service=cloud --format '{{.ID}}' | wc -l) == 0 ]]
[[ $(docker ps --filter label=com.docker.compose.service=caddy --format '{{.ID}}' | wc -l) == 0 ]]
echo 'INSTALLED_CONTROLLER_OLD_BACKUP_REJECTED=PASS'
echo 'JOURNAL_RETAINED_HASH='$before
echo 'CLOUD_CADDY_STOPPED=PASS'
# Inject oversized journal only in this isolated test, then recover the exact saved bytes.
cp "$state/publication/journal" /tmp/sr-controller-acceptance/journal-before-injection
saved=$(sha256sum /tmp/sr-controller-acceptance/journal-before-injection | cut -d ' ' -f 1)
[[ $saved == "$before" ]]
truncate -s $((4 * 1024 * 1024 + 1)) "$state/publication/journal"
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/oversized-controller.log 2>&1
over_status=$?
set -e
[[ $over_status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/oversized-controller.log
grep -q '^corrupt_deployment_fence$' /tmp/sr-controller-acceptance/results/oversized-controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/oversized-controller.log
install -m 0644 /tmp/sr-controller-acceptance/journal-before-injection "$state/publication/journal.restored"
mv "$state/publication/journal.restored" "$state/publication/journal"
[[ $(sha256sum "$state/publication/journal" | cut -d ' ' -f 1) == "$saved" ]]
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/restored-controller.log 2>&1
restore_status=$?
set -e
[[ $restore_status -ne 0 ]]
grep -q '^deployment_compatibility_failed$' /tmp/sr-controller-acceptance/results/restored-controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/restored-controller.log
echo 'OVERSIZED_JOURNAL_REFUSED=PASS'
echo 'TEST_ONLY_EXACT_SNAPSHOT_RESTORED=PASS'
echo 'JOURNAL_CAPACITY_RECOVERY=NOT_PROVEN'


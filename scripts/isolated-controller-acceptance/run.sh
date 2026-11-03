#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
cd "$GITHUB_WORKSPACE"
git merge-base --is-ancestor d85c0e0 HEAD
source_head=$(git rev-parse HEAD)
[[ "$source_head" == "$GITHUB_SHA" ]]
git diff --exit-code d85c0e0 HEAD -- cloud
mkdir -p /tmp/sr-controller-acceptance/results
exec > >(tee /tmp/sr-controller-acceptance/results/acceptance.log) 2>&1
echo "TEST_HEAD=$source_head EXACT_CLOUD_SOURCE=d85c0e0"
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
# Synthetic TLS anchor uses a distinct PostgreSQL instance and data directory.
# Both instances share this ephemeral VM: this demonstrates protocol behavior,
# not a genuinely independent production failure domain.
anchor_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
anchor_name=sr-anchor-independent-test
anchor_gateway=$(docker network inspect cloud_private --format '{{(index .IPAM.Config 0).Gateway}}')
[[ "$anchor_gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
mkdir -p /tmp/sr-controller-acceptance/anchor-certs
chmod 755 /tmp/sr-controller-acceptance /tmp/sr-controller-acceptance/anchor-certs
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/sr-controller-acceptance/anchor-certs/ca.key -out /tmp/sr-controller-acceptance/anchor-certs/ca.crt -subj '/CN=TEST ONLY ANCHOR CA' -days 1 >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout /tmp/sr-controller-acceptance/anchor-certs/server.key -out /tmp/sr-controller-acceptance/anchor-certs/server.csr -subj '/CN=TEST ONLY ANCHOR' >/dev/null 2>&1
printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$anchor_gateway" > /tmp/sr-controller-acceptance/anchor-certs/extensions
openssl x509 -req -in /tmp/sr-controller-acceptance/anchor-certs/server.csr -CA /tmp/sr-controller-acceptance/anchor-certs/ca.crt -CAkey /tmp/sr-controller-acceptance/anchor-certs/ca.key -CAcreateserial -days 1 -extfile /tmp/sr-controller-acceptance/anchor-certs/extensions -out /tmp/sr-controller-acceptance/anchor-certs/server.crt >/dev/null 2>&1
chown "$uid:$gid" /tmp/sr-controller-acceptance/anchor-certs/server.key
chmod 600 /tmp/sr-controller-acceptance/anchor-certs/server.key
chmod 644 /tmp/sr-controller-acceptance/anchor-certs/server.crt /tmp/sr-controller-acceptance/anchor-certs/ca.crt
docker run -d --name "$anchor_name" --network bridge -p "$anchor_gateway:15432:5432" -e POSTGRES_DB=sranchor -e POSTGRES_USER=sradmin -e POSTGRES_PASSWORD=synthetic-anchor-admin --mount type=bind,src=/tmp/sr-controller-acceptance/anchor-certs,dst=/anchor-certs,readonly postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef -c ssl=on -c ssl_cert_file=/anchor-certs/server.crt -c ssl_key_file=/anchor-certs/server.key >/dev/null
for _ in {1..60}; do if docker exec "$anchor_name" pg_isready -U sradmin -d sranchor >/dev/null 2>&1; then break; fi; sleep 1; done
docker exec "$anchor_name" pg_isready -U sradmin -d sranchor >/dev/null
docker exec -i "$anchor_name" psql -U sradmin -d sranchor -v ON_ERROR_STOP=1 < "$cloud/scripts/independent-fence-anchor.sql" >/dev/null
genesis=$(node --input-type=module -e 'import {fenceHistoryHead} from "./cloud/src/fence-history-head.mjs";console.log(fenceHistoryHead([]).digest)')
docker exec "$anchor_name" psql -U sradmin -d sranchor -v ON_ERROR_STOP=1 -c "CREATE ROLE sr_anchor_runtime LOGIN PASSWORD 'synthetic-anchor-runtime'; GRANT USAGE ON SCHEMA selective_remote_anchor TO sr_anchor_runtime; GRANT EXECUTE ON FUNCTION selective_remote_anchor.read_head(uuid), selective_remote_anchor.advance_head(uuid,bigint,text,text) TO sr_anchor_runtime; INSERT INTO selective_remote_anchor.heads(deployment_id,position,digest) VALUES ('$anchor_id',0,'$genesis');" >/dev/null
printf 'PUBLICATION_FENCE_ANCHOR_URL=postgresql://sr_anchor_runtime:synthetic-anchor-runtime@%s:15432/sranchor\nPUBLICATION_FENCE_ANCHOR_ID=%s\nPUBLICATION_FENCE_ANCHOR_CA_BASE64=%s\n' "$anchor_gateway" "$anchor_id" "$(base64 -w 0 /tmp/sr-controller-acceptance/anchor-certs/ca.crt)" >> "$cloud/.env"
echo 'SYNTHETIC_TLS_ANCHOR_CONFIGURED=YES'
touch "$state/publication/journal"
chmod 644 "$state/publication/journal"
docker run --rm --network cloud_private --env-file "$cloud/.env" --entrypoint node "$image" scripts/migrate.mjs >/tmp/sr-controller-acceptance/migrations.log
docker exec cloud-postgres-1 psql -U sraccept -d sraccept -v ON_ERROR_STOP=1 -c "INSERT INTO users(id,email,username,email_verified_at) VALUES('11111111-1111-4111-8111-111111111111','test@example.test','synthetic_test',now()); INSERT INTO devices(id,user_id,name,platform) VALUES('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','synthetic-device','web'); INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES('11111111-1111-4111-8111-111111111111',1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA');" >/dev/null
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/old.dump
# Arm the real database barrier and independently retained history using candidate source.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {randomUUID} from "node:crypto"; import {installV1CommitFence} from "./src/v1-commit-fence.mjs"; import {readV1VaultState} from "./src/v1-data-fence.mjs"; import {loadConfig} from "./src/config.mjs"; import {createConfiguredMigrationFence} from "./src/configured-migration-fence.mjs"; const cfg=loadConfig(),pool=new pg.Pool({connectionString:cfg.databaseURL}),configured=createConfiguredMigrationFence(cfg.deployment); try { await installV1CommitFence(pool); const f=configured.fence; if(!f?.anchor)throw Error("missing_anchor"); await f.append({version:2,type:"V1_BASELINE",baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>pool.query(s,v))}); await f.append({version:2,type:"V1_WRITER_FLOOR",writerProtocol:1}); console.log("ANCHORED_JOURNAL_ARMED"); } finally {await configured.close();await pool.end();}' 
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --entrypoint node "$image" --input-type=module -e 'import {loadConfig} from "./src/config.mjs";import {createConfiguredMigrationFence} from "./src/configured-migration-fence.mjs";const f=createConfiguredMigrationFence(loadConfig().deployment);try{const h=await f.fence.anchor.read();const result=await f.fence.anchor.queryable.query("SELECT s.ssl,has_table_privilege(current_user,\u0027selective_remote_anchor.heads\u0027,\u0027UPDATE\u0027) AS can_update FROM pg_stat_ssl s WHERE s.pid=pg_backend_pid()");if(h.position<1||result.rows.length!==1||result.rows[0].ssl!==true||result.rows[0].can_update!==false)throw Error("anchor_tls_or_privileges_failed");console.log("ANCHOR_TLS_AND_RESTRICTED_ROLE=PASS")}finally{await f.close()}'
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
jq -n --arg sha "$source_head" --arg image "$image" --arg ctrl "$controller_digest" --arg envhash "$(sha256sum "$cloud/.env"|cut -d ' ' -f 1)" --arg root "$pgmount" --arg src "$source_device" --arg uid "$uid" --arg gid "$gid" --argjson compose "$composejson" --arg anchorID "$anchor_id" '{version:1,anchorProtocol:1,anchorDeploymentID:$anchorID,sourceSHA:$sha,imageDigest:$image,controllerDigest:$ctrl,cloudDirectory:"/opt/selective-remote/cloud",envPath:"/opt/selective-remote/cloud/.env",envDigest:$envhash,network:"cloud_private",fencePath:"/var/lib/selective-remote-controller/publication/journal",backupDirectory:"/var/backups/sr-acceptance",composeFiles:$compose,storage:{POSTGRES_DATA_MOUNT_ROOT:$root,POSTGRES_DATA_HOST_PATH:($root+"/data"),POSTGRES_DATA_EXPECTED_SOURCE:$src,POSTGRES_DATA_EXPECTED_FSTYPE:"ext4",POSTGRES_DATA_UID:$uid,POSTGRES_DATA_GID:$gid}}' > "$root/settings.json"
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
# Check the existing stop before touching any synthetic data.
docker exec cloud-cloud-1 node --input-type=module -e 'const headers={Authorization:"Bearer "+"a".repeat(43),"Content-Type":"application/json","x-selective-v1-write-fence":"1"};const envelope={baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:"synthetic"},ciphertext:"bmV3",nonce:"A".repeat(16),authTag:"A".repeat(22),contentHash:"A".repeat(43)};const r=await fetch("http://127.0.0.1:8080/v1/vault",{method:"PUT",headers,body:JSON.stringify({protocol:"framed-v1",envelope})});const b=await r.json();if(r.status!==503||b.error!=="vault_write_temporarily_unavailable")throw Error("expected_write_stop_"+r.status);console.log("HTTP_WRITE_STOP=PASS")'
# Capture coherent revision 1 plus journal after arming. No production data.
"${compose[@]}" stop cloud caddy >/dev/null
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/before-write.dump
cp "$state/publication/journal" /tmp/sr-controller-acceptance/before-write.journal
anchor_before=$(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'")
[[ "$anchor_before" =~ ^[0-9]+:[a-f0-9]{64}$ ]]
# A real V1 store transaction creates a synthetic newer revision while HTTP stays stopped.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --entrypoint node "$image" --input-type=module -e 'import pg from "pg";import {PostgresStore} from "./src/postgres-store.mjs";import {loadConfig} from "./src/config.mjs";import {createConfiguredMigrationFence} from "./src/configured-migration-fence.mjs";const c=loadConfig(),p=new pg.Pool({connectionString:c.databaseURL}),f=createConfiguredMigrationFence(c.deployment);try{if(!f.fence?.anchor)throw Error("missing_anchor");const s=new PostgresStore(null,p,{v1Fence:f.fence});const r=await s.putVault("11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",{baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:"synthetic"},ciphertext:"bmV3",nonce:"A".repeat(16),authTag:"A".repeat(22),contentHash:"A".repeat(43)});if(r.revision!==2||r.conflict)throw Error("synthetic_store_write_failed");console.log("ANCHORED_DIRECT_STORE_REVISION_2=PASS")}finally{await f.close();await p.end()}'
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision||':'||ciphertext FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == '2:bmV3' ]]
anchor_after=$(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'")
[[ "$anchor_after" =~ ^[0-9]+:[a-f0-9]{64}$ && "$anchor_after" != "$anchor_before" ]]
[[ ${anchor_after%%:*} -gt ${anchor_before%%:*} ]]
# Rotate as the actual application UID, and make the installed checker replay
# the retained archive through its authenticated external high-water anchor.
cloud_uid=$(docker run --rm --entrypoint id "$image" -u)
docker run --rm --network cloud_private --user "$cloud_uid:$cloudgid" --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" -e PUBLICATION_FENCE_PATH=/publication-fence/journal --entrypoint node "$image" --input-type=module -e 'import {loadConfig} from "./src/config.mjs";import {createConfiguredMigrationFence} from "./src/configured-migration-fence.mjs";const f=createConfiguredMigrationFence(loadConfig().deployment);try{const x=await f.fence.compact();if(!x.archiveDigest)throw Error("checkpoint_failed");console.log("ANCHORED_JOURNAL_CHECKPOINT=PASS")}finally{await f.close()}'
[[ $(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'") == "$anchor_after" ]]
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/post-write-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/post-write-controller.log
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]]
echo 'INSTALLED_CONTROLLER_POST_WRITE_START=PASS'
oldpid=$(docker inspect --format '{{.State.Pid}}' cloud-cloud-1)
docker kill cloud-cloud-1 >/dev/null
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/crash-restart-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/crash-restart-controller.log
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-cloud-1) == healthy ]]
[[ $(docker inspect --format '{{.State.Pid}}' cloud-cloud-1) != "$oldpid" ]]
[[ $(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'") == "$anchor_after" ]]
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == 2 ]]
echo 'INSTALLED_CONTROLLER_CRASH_RESTART=PASS'
# Restore matching older primary DB and journal while leaving independent anchor unchanged.
"${compose[@]}" stop cloud caddy >/dev/null
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/after-write.dump
cp "$state/publication/journal" /tmp/sr-controller-acceptance/after-write.journal
docker exec -i cloud-postgres-1 pg_restore -U sraccept -d sraccept --clean --if-exists --exit-on-error --no-owner --no-acl < /tmp/sr-controller-acceptance/before-write.dump >/tmp/sr-controller-acceptance/restore.log 2>&1
cat /tmp/sr-controller-acceptance/before-write.journal > "$state/publication/journal"
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == 1 ]]
[[ $(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'") == "$anchor_after" ]]
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/simultaneous-rollback-controller.log 2>&1
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/simultaneous-rollback-controller.log
grep -q '^deployment_anchor_mismatch$' /tmp/sr-controller-acceptance/results/simultaneous-rollback-controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/simultaneous-rollback-controller.log
[[ -z $("${compose[@]}" ps --status running --services | grep -E '^(cloud|caddy)$' || true) ]]
[[ $(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'") == "$anchor_after" ]]
echo 'MATCHING_DATABASE_AND_JOURNAL_ROLLBACK_REJECTED=PASS'
# Automatic recovery in the disposable test uses the newer independently
# verified snapshot and retained archives, never by lowering the anchor.
docker exec -i cloud-postgres-1 pg_restore -U sraccept -d sraccept --clean --if-exists --exit-on-error --no-owner --no-acl < /tmp/sr-controller-acceptance/after-write.dump >/tmp/sr-controller-acceptance/recovery.log 2>&1
cat /tmp/sr-controller-acceptance/after-write.journal > "$state/publication/journal"
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/recovery-controller.log 2>&1
grep -q '"stage":"complete","trafficOpened":true' /tmp/sr-controller-acceptance/results/recovery-controller.log
[[ $(docker exec cloud-postgres-1 psql -U sraccept -d sraccept -tAc "SELECT revision FROM personal_vaults WHERE user_id='11111111-1111-4111-8111-111111111111'") == 2 ]]
[[ $(docker exec "$anchor_name" psql -U sradmin -d sranchor -tAc "SELECT position||':'||digest FROM selective_remote_anchor.heads WHERE deployment_id='$anchor_id'") == "$anchor_after" ]]
echo 'MATCHING_NEWER_SNAPSHOT_RECOVERY=PASS'
echo 'ANCHOR_FAILURE_DOMAIN=SEPARATE_DATABASE_SAME_EPHEMERAL_VM_NOT_PRODUCTION_ISOLATION'
echo 'V1_HTTP_WRITES=STOPPED'

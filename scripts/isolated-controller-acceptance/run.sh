#!/usr/bin/env bash
set -Eeuo pipefail
cd "$GITHUB_WORKSPACE"
git merge-base --is-ancestor 5fdf36e3bbeff01151bbf6e695b808594e4ba919 HEAD
git diff --exit-code 5fdf36e3bbeff01151bbf6e695b808594e4ba919 HEAD -- cloud
mkdir -p /tmp/sr-controller-acceptance/results
exec > >(tee /tmp/sr-controller-acceptance/results/acceptance.log) 2>&1
echo 'BASE_HEAD=5fdf36e3bbeff01151bbf6e695b808594e4ba919'
echo 'ENVIRONMENT=EPHEMERAL_GITHUB_HOSTED_RUNNER'
root=/opt/selective-remote-controller
state=/var/lib/selective-remote-controller
cloud=/opt/selective-remote/cloud
pgmount=/mnt/sr-acceptance-pg
mkdir -p "$cloud" "$state/publication" "$root" "$pgmount" /var/backups/sr-acceptance
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
docker build --quiet --label org.opencontainers.image.revision=5fdf36e3bbeff01151bbf6e695b808594e4ba919 -t sr-acceptance-candidate "$cloud" >/tmp/sr-controller-acceptance/image-build.log
image=$(docker image inspect --format '{{.Id}}' sr-acceptance-candidate)
[[ $image =~ ^sha256:[a-f0-9]{64}$ ]]
docker pull node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b >/dev/null
export POSTGRES_DATA_MOUNT_ROOT="$pgmount" POSTGRES_DATA_HOST_PATH="$pgmount/data" POSTGRES_DATA_EXPECTED_SOURCE="$source_device" POSTGRES_DATA_EXPECTED_FSTYPE=ext4 POSTGRES_DATA_UID="$uid" POSTGRES_DATA_GID="$gid" PUBLICATION_IMAGE_DIGEST="$image" PUBLICATION_FENCE_DIRECTORY="$state/publication"
compose=(docker compose --project-name cloud --project-directory "$cloud" --env-file "$cloud/.env" -f "$cloud/compose.yaml" -f "$cloud/compose.443-only.yaml" -f "$cloud/compose.small-host.yaml" -f "$cloud/compose.publication-fence.yaml" -f "$cloud/compose.postgres-bind.yaml")
# The test starts only PostgreSQL; Cloud and Caddy must remain down throughout.
"${compose[@]}" up -d postgres
for _ in {1..60}; do [[ $(docker inspect --format '{{.State.Health.Status}}' cloud-postgres-1) == healthy ]] && break; sleep 2; done
[[ $(docker inspect --format '{{.State.Health.Status}}' cloud-postgres-1) == healthy ]]
touch "$state/publication/journal"
chmod 644 "$state/publication/journal"
docker run --rm --network cloud_private --env-file "$cloud/.env" --entrypoint node "$image" scripts/migrate.mjs >/tmp/sr-controller-acceptance/migrations.log
docker exec cloud-postgres-1 psql -U sraccept -d sraccept -v ON_ERROR_STOP=1 -c "INSERT INTO users(id,email,username,email_verified_at) VALUES('11111111-1111-4111-8111-111111111111','test@example.test','synthetic_test',now()); INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES('11111111-1111-4111-8111-111111111111',1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA');" >/dev/null
docker exec cloud-postgres-1 pg_dump -U sraccept -d sraccept --format=custom --no-owner --no-acl > /tmp/sr-controller-acceptance/old.dump
# Arm the real database barrier and independently retained history using candidate source.
docker run --rm --network cloud_private --user root --mount "type=bind,src=$state/publication,dst=/publication-fence" --env-file "$cloud/.env" --entrypoint node "$image" --input-type=module -e 'import pg from "pg"; import {randomUUID} from "node:crypto"; import {installV1CommitFence} from "./src/v1-commit-fence.mjs"; import {readV1VaultState} from "./src/v1-data-fence.mjs"; import {MigrationFence} from "./src/migration-fence.mjs"; const pool=new pg.Pool({connectionString:process.env.DATABASE_URL}); try { await installV1CommitFence(pool); const f=new MigrationFence("/publication-fence/journal"); await f.append({version:2,type:"V1_BASELINE",baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>pool.query(s,v))}); await f.append({version:2,type:"V1_WRITER_FLOOR",writerProtocol:1}); console.log("INDEPENDENT_JOURNAL_ARMED"); } finally {await pool.end();}'
chmod 644 "$state/publication/journal"
# Install a separate root-owned controller copy and bundled runtime exactly as launcher expects.
id=$(docker create --entrypoint /bin/true "$image")
docker cp "$id:/app/." "$root/"
docker rm "$id" >/dev/null
mkdir -p "$root/runtime/node-v22.18.0-linux-x64/bin"
install -m 0755 "$(readlink -f "$(command -v node)")" "$root/runtime/node-v22.18.0-linux-x64/bin/node"
(cd "$root"; sha256sum runtime/node-v22.18.0-linux-x64/bin/node > runtime-node.sha256; find . -type f ! -name bundle.sha256 ! -name settings.json -print0 | sort -z | xargs -0 sha256sum | sed 's#  \./#  #' > bundle.sha256)
controller_digest=$(sha256sum "$root/bundle.sha256" | cut -d ' ' -f 1)
composefiles=("$cloud/compose.yaml" "$cloud/compose.443-only.yaml" "$cloud/compose.small-host.yaml" "$cloud/compose.publication-fence.yaml" "$cloud/compose.postgres-bind.yaml")
composejson=$(for f in "${composefiles[@]}"; do jq -cn --arg path "$f" --arg hash "$(sha256sum "$f"|cut -d ' ' -f 1)" '{path:$path,sha256:$hash}'; done | jq -s .)
jq -n --arg sha 5fdf36e3bbeff01151bbf6e695b808594e4ba919 --arg image "$image" --arg ctrl "$controller_digest" --arg envhash "$(sha256sum "$cloud/.env"|cut -d ' ' -f 1)" --arg root "$pgmount" --arg src "$source_device" --arg uid "$uid" --arg gid "$gid" --argjson compose "$composejson" '{version:1,sourceSHA:$sha,imageDigest:$image,controllerDigest:$ctrl,cloudDirectory:"/opt/selective-remote/cloud",envPath:"/opt/selective-remote/cloud/.env",envDigest:$envhash,network:"cloud_private",fencePath:"/var/lib/selective-remote-controller/publication/journal",backupDirectory:"/var/backups/sr-acceptance",composeFiles:$compose,storage:{POSTGRES_DATA_MOUNT_ROOT:$root,POSTGRES_DATA_HOST_PATH:($root+"/data"),POSTGRES_DATA_EXPECTED_SOURCE:$src,POSTGRES_DATA_EXPECTED_FSTYPE:"ext4",POSTGRES_DATA_UID:$uid,POSTGRES_DATA_GID:$gid}}' > "$root/settings.json"
chmod 600 "$root/settings.json"
# A restore from before fence activation must not be served against retained successor journal.
docker exec -i cloud-postgres-1 pg_restore -U sraccept -d sraccept --clean --if-exists --exit-on-error --no-owner --no-acl < /tmp/sr-controller-acceptance/old.dump >/tmp/sr-controller-acceptance/restore.log 2>&1
before=$(sha256sum "$state/publication/journal" | cut -d ' ' -f 1)
for probe in / /opt "$root" "$root/settings.json" "$root/bundle.sha256" /var /var/lib "$state" "$state/publication" /var/backups /var/backups/sr-acceptance /opt/selective-remote "$cloud" "$cloud/.env" "${composefiles[@]}"; do
  stat -c 'PATH=%n UID=%u MODE=%a' "$probe"
  printf 'REALPATH=%s\n' "$(realpath "$probe")"
done
set +e
bash "$root/scripts/staging-controller.sh" > /tmp/sr-controller-acceptance/results/controller.log 2>&1
status=$?
set -e
cat /tmp/sr-controller-acceptance/results/controller.log
[[ $status -ne 0 ]]
grep -q '"stage":"check"' /tmp/sr-controller-acceptance/results/controller.log
grep -q '^v1_writer_fence_missing$' /tmp/sr-controller-acceptance/results/controller.log
! grep -q '"stage":"open-traffic"' /tmp/sr-controller-acceptance/results/controller.log
[[ $(sha256sum "$state/publication/journal" | cut -d ' ' -f 1) == "$before" ]]
[[ $(docker ps --filter label=com.docker.compose.service=cloud --format '{{.ID}}' | wc -l) == 0 ]]
[[ $(docker ps --filter label=com.docker.compose.service=caddy --format '{{.ID}}' | wc -l) == 0 ]]
echo 'INSTALLED_CONTROLLER_OLD_BACKUP_REJECTED=PASS'
echo 'JOURNAL_RETAINED_HASH='$before
echo 'CLOUD_CADDY_STOPPED=PASS'
echo 'JOURNAL_CAPACITY_RECOVERY=NOT_TESTED'

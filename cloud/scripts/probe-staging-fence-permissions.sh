#!/bin/bash
# Ephemeral Linux Docker probe only. Never mounts deployment or DB storage.
set -euo pipefail
export PATH=/usr/bin:/bin
[[ $EUID == 0 && $# == 1 && $1 =~ ^sha256:[a-f0-9]{64}$ ]] || exit 64
image=$1
scratch=$(mktemp -d /var/tmp/staging-fence-permission-probe.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
chmod 700 "$scratch"
account=$(docker run --rm --pull=never --network none --read-only --cap-drop ALL --security-opt no-new-privileges --entrypoint /bin/sh "$image" -c 'id -u cloud; id -g cloud')
mapfile -t ids <<< "$account"
[[ ${#ids[@]} == 2 && ${ids[0]} =~ ^[0-9]+$ && ${ids[1]} =~ ^[0-9]+$ && ${ids[0]} != 0 ]] || exit 65
mkdir "$scratch/publication" "$scratch/operator"
chown "0:${ids[1]}" "$scratch/publication"
chmod 770 "$scratch/publication"
: > "$scratch/publication/journal"
chown "0:${ids[1]}" "$scratch/publication/journal"
chmod 660 "$scratch/publication/journal"
printf '{"probe":true}' > "$scratch/operator/evidence.json"
chmod 700 "$scratch/operator"
chmod 600 "$scratch/operator/evidence.json"
# Root checker/operator with exactly the deployed capability restrictions.
docker run --rm --pull=never --network none --read-only --user 0:0 --cap-drop ALL --security-opt no-new-privileges --mount "type=bind,src=$scratch/publication,dst=/publication" --mount "type=bind,src=$scratch/operator,dst=/operator,readonly" --entrypoint node "$image" --input-type=module -e 'import {open,readFile} from "node:fs/promises";const f=await open("/publication/journal","r+");await f.sync();await f.close();if(JSON.parse(await readFile("/operator/evidence.json")).probe!==true)throw Error();'
# Actual cloud UID/GID writes/fsyncs the fence and cannot read root evidence.
docker run --rm --pull=never --network none --read-only --user "${ids[0]}:${ids[1]}" --cap-drop ALL --security-opt no-new-privileges --mount "type=bind,src=$scratch/publication,dst=/publication" --mount "type=bind,src=$scratch/operator,dst=/operator,readonly" --entrypoint node "$image" --input-type=module -e 'import {open,mkdir,rmdir,readFile} from "node:fs/promises";await mkdir("/publication/journal.lock",{mode:0o700});const f=await open("/publication/journal","r+");await f.write("probe\n");await f.sync();await f.close();const d=await open("/publication","r");await d.sync();await d.close();await rmdir("/publication/journal.lock");try{await readFile("/operator/evidence.json");throw Error("evidence_leaked");}catch(e){if(e.code!=="EACCES")throw e;}'
printf '{"ephemeralFencePermissionsVerified":true}\n'

#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
fixture="$root/infra/qa-pr255-named-ingress"
sha256sum --check "$fixture/expected.sha256"
caddy_image='caddy:2.9.1-alpine@sha256:b4e3952384eb9524a887633ce65c752dd7c71314d2c2acf98cd5c715aaa534f0'
name='pr255-staging.pastfly.ru'
fixture_secret='local-rehearsal-only'
tmp=$(mktemp -d)
network='sr255-named-fixture'
proxy='sr255-named-proxy'
backend='sr255-named-backend'

cleanup() {
  docker rm -f "$proxy" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  sudo rm -f /usr/local/share/ca-certificates/sr255-rehearsal.crt
  sudo update-ca-certificates --fresh >/dev/null 2>&1
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir "$tmp/named"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=SR255 Hosted Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2>"$tmp/root.log"
openssl req -new -newkey rsa:2048 -sha256 -nodes -subj "/CN=$name" \
  -keyout "$tmp/named/privkey.pem" -out "$tmp/leaf.csr" 2>"$tmp/req.log"
printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' \
  "subjectAltName=DNS:$name" > "$tmp/leaf.ext"
openssl x509 -req -sha256 -days 1 -in "$tmp/leaf.csr" -CA "$tmp/ca.crt" \
  -CAkey "$tmp/ca.key" -CAcreateserial -extfile "$tmp/leaf.ext" \
  -out "$tmp/named/fullchain.pem" 2>"$tmp/sign.log"
openssl verify -purpose sslserver -verify_hostname "$name" -CAfile "$tmp/ca.crt" "$tmp/named/fullchain.pem"
printf '127.0.0.1 %s\n' "$name" | sudo tee -a /etc/hosts >/dev/null

chmod a+r "$tmp/named/fullchain.pem"
cat > "$tmp/backend.Caddyfile" <<'CADDY'
{
    admin off
    auto_https off
}
:8080 {
    @trusted {
        header Host pr255-staging.pastfly.ru:8443
        header X-Selective-Proxy-Secret local-rehearsal-only
        header X-Selective-Client-IP *
    }
    handle @trusted {
        handle /readyz {
            header Content-Type application/json
            respond `{"status":"ready"}` 200
        }
        handle /v1/meta {
            header Content-Type application/json
            header X-Selective-V1-Write-Fence 1
            header X-Selective-V1-Write-Status vault_write_temporarily_unavailable
            respond `{"apiVersion":1,"vaultSchemaVersion":1,"registrationEnabled":false}` 200
        }
        handle / {
            root * /fixture
            file_server
        }
        respond 404
    }
    respond 403
}
CADDY

docker network create "$network" >/dev/null
docker pull "$caddy_image"
docker run --rm \
  -e "PROXY_SHARED_SECRET=$fixture_secret" \
  -v "$fixture/Caddyfile.named:/etc/caddy/Caddyfile:ro" \
  -v "$tmp/named:/tls/named:ro" \
  "$caddy_image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker run -d --name "$backend" --network "$network" --network-alias cloud \
  -v "$tmp/backend.Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$root/cloud/public:/fixture:ro" "$caddy_image" >/dev/null
docker run -d --name "$proxy" --network "$network" -p 127.0.0.1:8443:443 \
  -e "PROXY_SHARED_SECRET=$fixture_secret" \
  -v "$fixture/Caddyfile.named:/etc/caddy/Caddyfile:ro" \
  -v "$tmp/named:/tls/named:ro" "$caddy_image" >/dev/null

curl_request=(curl --disable --silent --show-error --fail --noproxy '*' --connect-timeout 2 --max-time 4)
for _attempt in {1..12}; do
  if "${curl_request[@]}" --cacert "$tmp/ca.crt" "https://$name:8443/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
"${curl_request[@]}" --cacert "$tmp/ca.crt" "https://$name:8443/readyz" >/dev/null
if "${curl_request[@]}" "https://$name:8443/readyz" >/dev/null 2>&1; then
  printf '%s\n' 'Untrusted rehearsal CA was accepted.' >&2
  exit 1
fi
sudo install -m 0644 "$tmp/ca.crt" /usr/local/share/ca-certificates/sr255-rehearsal.crt
sudo update-ca-certificates >/dev/null

bash "$fixture/verify-named-ingress.sh" 127.0.0.1
if "${curl_request[@]}" "https://127.0.0.1:8443/readyz" >/dev/null 2>&1; then
  printf '%s\n' 'Raw IP unexpectedly reached the named endpoint.' >&2
  exit 1
fi
if "${curl_request[@]}" "http://$name:8443/readyz" >/dev/null 2>&1; then
  printf '%s\n' 'Clear HTTP unexpectedly passed.' >&2
  exit 1
fi
code=$("${curl_request[@]/--fail/--no-fail}" --output /dev/null --write-out '%{http_code}' \
  --header 'Host: wrong.invalid:8443' "https://$name:8443/readyz")
test "$code" = 421
printf '%s\n' 'PASS: untrusted CA, raw IPv4, clear HTTP and an SNI/Host mismatch were rejected.'

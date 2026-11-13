#!/bin/sh
# Generate local development credentials, including the Docker hostname "nats".
set -eu
umask 077

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
cert_dir=${1:-"$script_dir/certs"}

# Never replace credentials used by an existing deployment.
if [ -e "$cert_dir" ] && { [ ! -d "$cert_dir" ] || [ -n "$(ls -A "$cert_dir")" ]; }; then
  echo "Certificate directory is not empty: $cert_dir" >&2
  echo "Choose a new directory to generate another set of credentials." >&2
  exit 1
fi
command -v openssl >/dev/null
mkdir -p "$cert_dir/ca" "$cert_dir/server" "$cert_dir/client"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
  -keyout "$cert_dir/ca/ca.key" -out "$cert_dir/ca/ca.crt" \
  -days 30 -subj "/CN=Tazama-local-NATS-CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$cert_dir/server/server.key" -out "$cert_dir/server/server.csr" \
  -subj "/CN=nats"
cat > "$cert_dir/server/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:nats,DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in "$cert_dir/server/server.csr" \
  -CA "$cert_dir/ca/ca.crt" -CAkey "$cert_dir/ca/ca.key" -CAcreateserial \
  -out "$cert_dir/server/server.crt" -days 30 -sha256 \
  -extfile "$cert_dir/server/server.ext"

openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout "$cert_dir/client/client.key" -out "$cert_dir/client/client.csr" \
  -subj "/CN=tazama-local-client"
cat > "$cert_dir/client/client.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in "$cert_dir/client/client.csr" \
  -CA "$cert_dir/ca/ca.crt" -CAkey "$cert_dir/ca/ca.key" -CAcreateserial \
  -out "$cert_dir/client/client.crt" -days 30 -sha256 \
  -extfile "$cert_dir/client/client.ext"

cp "$cert_dir/ca/ca.crt" "$cert_dir/server/ca.crt"
cp "$cert_dir/ca/ca.crt" "$cert_dir/client/ca.crt"
# Non-root containers must read their bind-mounted keys. Keep the host parent
# directory private (0700), and mount only the server/ or client/ subdirectory.
chmod 700 "$cert_dir" "$cert_dir/ca"
chmod 755 "$cert_dir/server" "$cert_dir/client"
chmod 644 "$cert_dir/server/"*.crt "$cert_dir/server/server.key" \
  "$cert_dir/client/"*.crt "$cert_dir/client/client.key"

echo "Local NATS certificates generated in: $cert_dir"
echo "Certificates expire after 30 days. Restart NATS and its clients after rotation."

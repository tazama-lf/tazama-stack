#!/bin/sh
# Shared preflight for the Unix and Windows launchers, run in an OpenSSL container.
set -eu

cert_dir=${1:-/certs}
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)

fail() {
  echo "NATS TLS setup failed: $*" >&2
  exit 1
}

[ "${NATS_AUTHENTICATED:-true}" = true ] || \
  fail "NATS_AUTHENTICATED must be true for the TLS-enabled core broker."
[ "${NATS_CERTIFICATE_AUTHORITY_PATH:-/etc/nats/client/ca.crt}" = /etc/nats/client/ca.crt ] || \
  fail "NATS_CERTIFICATE_AUTHORITY_PATH must be /etc/nats/client/ca.crt."
[ "${NATS_CLIENT_CERT_PATH:-/etc/nats/client/client.crt}" = /etc/nats/client/client.crt ] || \
  fail "NATS_CLIENT_CERT_PATH must be /etc/nats/client/client.crt."
[ "${NATS_CLIENT_KEY_PATH:-/etc/nats/client/client.key}" = /etc/nats/client/client.key ] || \
  fail "NATS_CLIENT_KEY_PATH must be /etc/nats/client/client.key."

if [ ! -e "$cert_dir" ] || { [ -d "$cert_dir" ] && [ -z "$(ls -A "$cert_dir")" ]; }; then
  echo "Generating local NATS TLS certificates..."
  sh "$script_dir/generate-certs.sh" "$cert_dir"
  # Docker creates files as root. Restore host ownership on Unix; on Docker
  # Desktop for Windows the bind mount is managed by Docker Desktop.
  if [ -n "${NATS_TLS_UID:-}" ] && [ -n "${NATS_TLS_GID:-}" ]; then
    chown -R "$NATS_TLS_UID:$NATS_TLS_GID" "$cert_dir"
  fi
fi

for file in server/ca.crt server/server.crt server/server.key client/ca.crt client/client.crt client/client.key; do
  [ -s "$cert_dir/$file" ] || fail "Missing $file in NATS_CERTS_DIR. Existing credentials were preserved."
done

# Verify both directions of trust, expiry, intended use and the Docker hostname.
openssl verify -CAfile "$cert_dir/client/ca.crt" -purpose sslserver \
  -verify_hostname nats "$cert_dir/server/server.crt" || \
  fail "Server certificate is invalid, expired, untrusted, or does not cover nats."
openssl verify -CAfile "$cert_dir/server/ca.crt" -purpose sslclient \
  "$cert_dir/client/client.crt" || fail "Client certificate is invalid, expired, or untrusted."

for role in server client; do
  cert_public=$(openssl x509 -in "$cert_dir/$role/$role.crt" -pubkey -noout) || \
    fail "Cannot read the $role certificate."
  key_public=$(openssl pkey -in "$cert_dir/$role/$role.key" -pubout -passin pass:) || \
    fail "Cannot read the unencrypted $role private key."
  [ "$cert_public" = "$key_public" ] || fail "$role certificate and private key do not match."
done

echo "NATS TLS certificates validated; existing credentials were preserved."

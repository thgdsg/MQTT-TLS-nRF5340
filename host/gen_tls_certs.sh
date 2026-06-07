#!/usr/bin/env bash
set -euo pipefail

HOST_IP="${1:-2001:db8::2}"
HOST_DNS="${2:-localhost}"
CERT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"

mkdir -p "${CERT_DIR}"

openssl ecparam -name prime256v1 -genkey -noout -out "${CERT_DIR}/ca.key"
openssl req -x509 -new -nodes \
    -key "${CERT_DIR}/ca.key" \
    -sha256 \
    -days 3650 \
    -subj "/CN=ipsp-local-ca" \
    -out "${CERT_DIR}/ca.crt"

openssl ecparam -name prime256v1 -genkey -noout -out "${CERT_DIR}/server.key"
openssl req -new \
    -key "${CERT_DIR}/server.key" \
    -subj "/CN=${HOST_DNS}" \
    -out "${CERT_DIR}/server.csr"

cat > "${CERT_DIR}/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${HOST_DNS},IP:${HOST_IP}
EOF

openssl x509 -req \
    -in "${CERT_DIR}/server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/server.crt" \
    -days 825 \
    -sha256 \
    -extfile "${CERT_DIR}/server.ext"

rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/server.ext"

printf 'Generated TLS files in %s\n' "${CERT_DIR}"
printf 'Copy this CA into firmware/src/main.c ca_cert_pem before flashing:\n\n'
sed 's/^/    /' "${CERT_DIR}/ca.crt"

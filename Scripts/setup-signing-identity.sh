#!/usr/bin/env bash
# setup-signing-identity.sh — creates a persistent self-signed code-signing
# identity for exímIABar in the user's login keychain.
#
# WHY: an ad-hoc signature ("codesign --sign -") has a code hash that changes on
# every build. macOS stores keychain ACL entries (the "Always Allow" you click on
# the credential prompt) keyed by the app's *designated requirement*. With ad-hoc,
# that requirement changes each rebuild, so the ACL never persists and you get
# prompted forever. A stable certificate gives a stable requirement → "Always
# Allow" sticks once, across rebuilds.
#
# Idempotent: if the identity already exists, it does nothing.
# Run once per machine. Build with: EXIMIA_SIGN_IDENTITY="eximIA Code Signing" make build
set -euo pipefail

IDENTITY_NAME="eximIA Code Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_NAME}"; then
  echo "✓ Identidade '${IDENTITY_NAME}' já existe e é válida para code signing. Nada a fazer."
  exit 0
fi

echo "==> Gerando certificado self-signed de code signing: '${IDENTITY_NAME}'"

cat > "${WORKDIR}/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = ${IDENTITY_NAME}
O  = eximIA Ventures
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

# Self-signed cert valid 10 years.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORKDIR}/key.pem" \
  -out    "${WORKDIR}/cert.pem" \
  -days 3650 \
  -config "${WORKDIR}/cert.conf" 2>/dev/null

openssl pkcs12 -export \
  -inkey "${WORKDIR}/key.pem" \
  -in    "${WORKDIR}/cert.pem" \
  -out   "${WORKDIR}/identity.p12" \
  -name  "${IDENTITY_NAME}" \
  -passout pass:eximia

echo "==> Importando no login keychain (-T codesign permite assinar sem prompt repetido)"
security import "${WORKDIR}/identity.p12" \
  -k "${KEYCHAIN}" \
  -P eximia \
  -T /usr/bin/codesign -T /usr/bin/security

echo ""
echo "==> O macOS pedirá sua senha 1-2 vezes AGORA para:"
echo "    (a) confiar no certificado para code signing"
echo "    (b) liberar a chave para o codesign usar sem prompts futuros"
echo "    Isto é ÚNICO. Depois disto, o app nunca mais pede senha no uso normal."
echo ""

# Trust the cert for code signing in the user (login) domain.
security add-trusted-cert -r trustRoot -p codeSign \
  -k "${KEYCHAIN}" "${WORKDIR}/cert.pem" 2>/dev/null || \
  echo "  (aviso: add-trusted-cert retornou não-zero; verificando validade abaixo)"

# Allow apple tools (codesign) to use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true

echo "==> Verificando"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_NAME}"; then
  echo "✓ Identidade '${IDENTITY_NAME}' criada e válida para code signing."
  echo "  Agora rode:  EXIMIA_SIGN_IDENTITY=\"${IDENTITY_NAME}\" make build"
else
  echo "✗ A identidade não aparece como válida. Pode ser preciso confiar manualmente"
  echo "  no certificado '${IDENTITY_NAME}' no app Acesso às Chaves (Keychain Access)."
  exit 1
fi

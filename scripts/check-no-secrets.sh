#!/usr/bin/env bash
set -euo pipefail

# Fast local guardrail for accidental commits. This checks tracked files only;
# use a dedicated secret scanner in CI for entropy-based detection.
pattern='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'

if git grep -n -I -E "$pattern" -- .; then
  echo 'Credential-shaped value found in tracked files.' >&2
  exit 1
fi

echo 'No credential-shaped values found in tracked files.'

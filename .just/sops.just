set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

age_key := env('HOME') + '/.age/key.txt'

# Decrypt a SOPS file and print to stdout
cat target:
    SOPS_AGE_KEY_FILE={{age_key}} sops --decrypt "{{target}}"

# Open a SOPS file in your editor (decrypt → edit → re-encrypt)
edit target:
    SOPS_AGE_KEY_FILE={{age_key}} sops "{{target}}"

# Encrypt a SOPS file in-place
encrypt target:
    SOPS_AGE_KEY_FILE={{age_key}} sops --encrypt --in-place "{{target}}"

# Check whether *.sops.yaml files are encrypted (exit 1 if any are plaintext)
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    while IFS= read -r -d '' f; do
        if grep -q '^[[:space:]]*sops:' "$f"; then
            echo "ok   $f"
        else
            echo "FAIL $f (not encrypted)" >&2
            rc=1
        fi
    done < <(find . -type f -name '*.sops.yaml' ! -name '.sops.yaml' -print0)
    exit $rc

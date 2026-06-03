set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

age_key := env('HOME') + '/.age/key.txt'
project_root := absolute_path(justfile_dir())

# Decrypt a SOPS file and print to stdout
cat target:
    #!/usr/bin/env bash
    set -euo pipefail
    PROJECT_ROOT="{{ project_root }}"
    pushd "$PROJECT_ROOT"
    SOPS_AGE_KEY_FILE={{age_key}} sops --decrypt "{{target}}"
    popd

# Open a SOPS file in your editor (decrypt → edit → re-encrypt)
edit target:
    #!/usr/bin/env bash
    set -euo pipefail
    PROJECT_ROOT="{{ project_root }}"
    pushd "$PROJECT_ROOT"
    SOPS_AGE_KEY_FILE={{age_key}} sops "{{target}}"
    popd

# Encrypt a SOPS file in-place
encrypt target:
    #!/usr/bin/env bash
    set -euo pipefail
    PROJECT_ROOT="{{ project_root }}"
    pushd "$PROJECT_ROOT"
    SOPS_AGE_KEY_FILE={{age_key}} sops --encrypt --in-place "{{target}}"
    popd

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

#!/bin/bash
# The inherited source-tree lifecycle verifier is retired.
# Mandatory fixture coverage remains in the canonical CI suite inventory.
set -euo pipefail
printf '%s\n' 'verify-m6: retired entrypoint; use the repository-owned CI suite commands. Live lifecycle qualification requires the signed coordinator and its separate acceptance gates.' >&2
exit 64

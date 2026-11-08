#!/bin/bash
# The source-installer capture/build/cleanup implementation has been removed.
# Signed-lifecycle cleanup, substitution refusal and child-retirement evidence
# remain required; source-installer retirement does not qualify those gates.
set -euo pipefail
printf '%s\n' 'installer-scratch-cleanup-tests: retired entrypoint; source installation is unavailable. Signed-lifecycle cleanup qualification remains required.' >&2
exit 64

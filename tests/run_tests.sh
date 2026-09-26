#!/usr/bin/env bash
# Run every test under the system bash (3.2 on macOS) and, when present, a
# newer bash too. No real agent CLI is called.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
status=0
for shell in /bin/bash "$(command -v bash)"; do
    [[ -x "$shell" ]] || continue
    echo "== $shell ($("$shell" --version | head -1))"
    for t in harness_parse_test.sh runner_integration_test.sh; do
        if "$shell" "$ROOT/tests/$t"; then
            echo "   ok  $t"
        else
            echo "   FAIL $t"
            status=1
        fi
    done
done
exit $status

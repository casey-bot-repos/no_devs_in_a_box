#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "no_devs_in_a_box starting up..."
./scripts/selfcheck.sh
exec ./orchestrator/run_loop.sh

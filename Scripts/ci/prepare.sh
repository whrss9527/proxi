#!/bin/bash
set -eo pipefail
# shellcheck source=Scripts/ci/seed-smoke.sh
source "$(dirname "${BASH_SOURCE[0]}")/seed-smoke.sh"

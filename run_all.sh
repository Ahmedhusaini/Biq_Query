#!/usr/bin/env bash
# Full local run. Seeds go first: staging reads them as *sources* (like real raw
# tables written by a loader), so dbt doesn't know to build them before staging.
set -euo pipefail
TARGET="${1:-dev}"
dbt seed     --target "$TARGET"
dbt build    --target "$TARGET" --exclude resource_type:seed
dbt snapshot --target "$TARGET"
dbt docs generate --target "$TARGET"

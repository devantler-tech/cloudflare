#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

shellcheck scripts/*.sh scripts/tests/*.sh
scripts/tests/test-no-destructive-plan.sh
bash scripts/tests/test-cloudflare-connection.sh
bash scripts/tests/test-dns-snapshot.sh
bash scripts/tests/test-bootstrap-inventory.sh
bash scripts/tests/test-recovery-package.sh
bash scripts/tests/test-state-recovery-package.sh
bash scripts/tests/test-state-capture.sh
bash scripts/tests/test-bootstrap-plan.sh
bash scripts/tests/test-bootstrap-apply-input.sh
bash scripts/tests/test-bootstrap-state-publication.sh
bash scripts/tests/test-bootstrap-apply-lifecycle.sh
bash scripts/tests/test-r2-backend-input.sh
bash scripts/tests/test-native-state-lock.sh
bash scripts/tests/test-native-state-migration.sh
bash scripts/tests/test-state-backend-workflow.sh
bash scripts/check-recovery-package.sh "$repo_root"
tofu fmt -check -recursive
tofu init -backend=false -input=false
tofu validate

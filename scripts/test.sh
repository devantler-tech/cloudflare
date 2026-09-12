#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

shellcheck scripts/*.sh scripts/tests/*.sh
scripts/tests/test-no-destructive-plan.sh
tofu fmt -check -recursive
tofu init -backend=false -input=false
tofu validate

#!/usr/bin/env bash
set -euo pipefail

# Kept as a compatibility entry point for existing build automation. The
# namespace probe now shares the same three-ABI source build and validation as
# the complete standalone bootstrap runtime.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$repo_dir/scripts/build-bootstrap-runtime.sh"

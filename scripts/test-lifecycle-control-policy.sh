#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuBootService.java"

grep -Fq 'lifecycleExecutor = Executors.newSingleThreadExecutor()' "$service"
grep -Fq 'lifecycleFuture.cancel(true)' "$service"
grep -Fq 'urgentControlGeneration.incrementAndGet()' "$service"
grep -Fq 'DEBIAN_LIFECYCLE_PREEMPTED_BY' "$service"
grep -Fq 'DEBIAN_AUTOSTART_SUPPRESSED' "$service"
grep -Fq 'requestLifecycleOperation(DebianLauncher.Operation.START,' "$service"

if grep -Fq 'executor.execute(() -> {' "$service" \
        && grep -A8 -F 'private void requestLifecycleOperation' "$service" \
            | grep -Fq 'executor.execute'; then
    echo "Lifecycle controls must not use the background work queue" >&2
    exit 1
fi

echo "PASS: urgent lifecycle controls preempt health work and bypass the background queue."

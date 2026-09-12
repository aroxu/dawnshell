#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuBootService.java"
receiver="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootReceiver.java"

grep -Fq 'lifecycleExecutor = Executors.newSingleThreadExecutor()' "$service"
grep -Fq 'lifecycleFuture.cancel(true)' "$service"
grep -Fq 'urgentControlGeneration.incrementAndGet()' "$service"
grep -Fq 'DEBIAN_LIFECYCLE_PREEMPTED_BY' "$service"
grep -Fq 'DEBIAN_AUTOSTART_SUPPRESSED' "$service"
grep -Fq 'requestLifecycleOperation(DebianLauncher.Operation.START,' "$service"
grep -Fq '"boot_completed_unlocked"' "$service"
grep -A12 -F 'if (Intent.ACTION_BOOT_COMPLETED.equals(action))' "$receiver" \
    | grep -Fq 'startBfuEnvironment(context)'
if grep -A12 -F 'if (Intent.ACTION_BOOT_COMPLETED.equals(action))' "$receiver" \
        | grep -Fq '&& !unlocked'; then
    echo "BOOT_COMPLETED must start enabled Debian even when Android is unlocked" >&2
    exit 1
fi

if grep -Fq 'executor.execute(() -> {' "$service" \
        && grep -A8 -F 'private void requestLifecycleOperation' "$service" \
            | grep -Fq 'executor.execute'; then
    echo "Lifecycle controls must not use the background work queue" >&2
    exit 1
fi

echo "PASS: urgent lifecycle controls preempt health work and bypass the background queue."

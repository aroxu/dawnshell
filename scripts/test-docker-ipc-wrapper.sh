#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_script="$repo_dir/app/src/main/assets/bfu/configure-docker-network.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

sed -n '/^#!\/bin\/bash$/,/^EOF_DOCKER_WRAPPER$/p' "$policy_script" \
    | sed '$d; s#^real_docker=/usr/bin/docker$#real_docker="${DAWNSHELL_FAKE_DOCKER:?}"#' \
    > "$temporary_dir/docker"
chmod +x "$temporary_dir/docker"

cat > "$temporary_dir/fake-docker" <<'EOF_FAKE_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DAWNSHELL_DOCKER_ARGUMENTS:?}"
EOF_FAKE_DOCKER
chmod +x "$temporary_dir/fake-docker"

run_wrapper() {
    DAWNSHELL_FAKE_DOCKER="$temporary_dir/fake-docker" \
    DAWNSHELL_DOCKER_ARGUMENTS="$temporary_dir/arguments" \
        "$temporary_dir/docker" "$@"
}

assert_arguments() {
    printf '%s\n' "$@" > "$temporary_dir/expected"
    cmp "$temporary_dir/expected" "$temporary_dir/arguments"
}

run_wrapper run --rm hello-world
assert_arguments run --ipc=host --rm hello-world

run_wrapper create --ipc=private alpine true
assert_arguments create --ipc=private alpine true

run_wrapper container run --name demo alpine true
assert_arguments container run --ipc=host --name demo alpine true

run_wrapper info
assert_arguments info

echo "Docker host IPC wrapper argument tests passed"

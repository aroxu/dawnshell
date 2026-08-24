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
# Compose project queries are answered from fixtures so the wrapper can build
# its override; every other invocation records its arguments.
if [[ "${1:-}" == compose && "${*: -1}" == --services ]]; then
    cat "${DAWNSHELL_FAKE_SERVICES:-/dev/null}"
    exit 0
fi
if [[ "${1:-}" == compose && "${*: -1}" == json ]]; then
    printf '{"ComposeFiles":["docker-compose.yml"]}\n'
    exit 0
fi
if [[ "${1:-}" == compose && "${*: -1}" == config ]]; then
    cat "${DAWNSHELL_FAKE_CONFIG:-/dev/null}"
    exit 0
fi
printf '%s\n' "$@" > "${DAWNSHELL_DOCKER_ARGUMENTS:?}"
EOF_FAKE_DOCKER
chmod +x "$temporary_dir/fake-docker"

run_wrapper() {
    DAWNSHELL_FAKE_DOCKER="$temporary_dir/fake-docker" \
    DAWNSHELL_DOCKER_ARGUMENTS="$temporary_dir/arguments" \
    DAWNSHELL_FAKE_SERVICES="$temporary_dir/services" \
    DAWNSHELL_FAKE_CONFIG="$temporary_dir/config" \
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

# Compose declares IPC in YAML, so the wrapper must inject an override file
# instead of a flag. The base project stays first so the override applies last.
compose_project="$temporary_dir/project"
mkdir -p "$compose_project"
printf 'services:\n  speedtest:\n    image: demo\n' \
    > "$compose_project/docker-compose.yml"
printf 'speedtest\nworker\n' > "$temporary_dir/services"
printf 'services:\n  speedtest:\n    image: demo\n  worker:\n    ipc: private\n' \
    > "$temporary_dir/config"
(cd "$compose_project" && run_wrapper compose up -d)
[[ "$(sed -n '1p' "$temporary_dir/arguments")" == compose ]]
[[ "$(sed -n '2p' "$temporary_dir/arguments")" == -f ]]
[[ "$(sed -n '3p' "$temporary_dir/arguments")" == docker-compose.yml ]]
[[ "$(sed -n '4p' "$temporary_dir/arguments")" == -f ]]
override="$(sed -n '5p' "$temporary_dir/arguments")"
[[ "$override" == /tmp/dawnshell-compose-ipc.* ]]
[[ "$(sed -n '6p' "$temporary_dir/arguments")" == up ]]
[[ "$(sed -n '7p' "$temporary_dir/arguments")" == -d ]]

# Commands that never start a container must stay untouched.
run_wrapper compose ps
assert_arguments compose ps

# Without services the wrapper must not invent an override.
: > "$temporary_dir/services"
(cd "$compose_project" && run_wrapper compose up)
assert_arguments compose up

echo "Docker host IPC wrapper argument tests passed"

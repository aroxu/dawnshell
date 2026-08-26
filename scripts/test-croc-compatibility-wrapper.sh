#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_source="$repo_dir/app/src/main/assets/bfu/dawnshell-croc.sh"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
runtime_java="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

cp "$wrapper_source" "$temporary_dir/croc"
chmod +x "$temporary_dir/croc"

cat > "$temporary_dir/fake-croc" <<'EOF_FAKE_CROC'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DAWNSHELL_CROC_ARGUMENTS:?}"
EOF_FAKE_CROC
chmod +x "$temporary_dir/fake-croc"

run_wrapper() {
    DAWNSHELL_CROC_REAL="$temporary_dir/fake-croc" \
    DAWNSHELL_CROC_ARGUMENTS="$temporary_dir/arguments" \
        "$temporary_dir/croc" "$@"
}

assert_arguments() {
    printf '%s\n' "$@" > "$temporary_dir/expected"
    cmp "$temporary_dir/expected" "$temporary_dir/arguments"
}

# Explicit files and receive codes must not inherit an idle non-TTY stdin.
run_wrapper send file.txt
assert_arguments --ignore-stdin send file.txt

run_wrapper --transport relay send file.txt
assert_arguments --ignore-stdin --transport relay send file.txt

run_wrapper --out /tmp six-word-receive-code
assert_arguments --ignore-stdin --out /tmp six-word-receive-code

run_wrapper send --text 'hello world'
assert_arguments --ignore-stdin send --text 'hello world'

CROC_SECRET=receive-secret run_wrapper --transport relay
assert_arguments --ignore-stdin --transport relay

# An explicit upstream choice must not be duplicated or reordered.
run_wrapper --ignore-stdin send file.txt
assert_arguments --ignore-stdin send file.txt

# Preserve croc's stdin transfer feature when no explicit payload is present.
run_wrapper send
assert_arguments send

CROC_SECRET=send-secret run_wrapper send
assert_arguments send

# Informational and relay-server commands remain untouched.
run_wrapper --help
assert_arguments --help

run_wrapper relay
assert_arguments relay

# Provisioning must carry the wrapper into DE, preserve a manual local binary,
# and put only DawnShell's wrapper at the ordinary croc command path.
grep -Fq '"bfu/dawnshell-croc.sh"' "$runtime_java"
grep -Fq 'crocCompatibilityScript' "$runtime_java"
# shellcheck disable=SC2016 # Match literal configurator variables.
grep -Fq 'croc_preserved="$ROOT/usr/local/libexec/dawnshell-croc-real"' \
    "$configurator"
grep -Fq 'Preserved manually installed croc' "$configurator"
# shellcheck disable=SC2016 # Match literal configurator variables.
grep -Fq 'ln -sfn "$croc_wrapper" "$ROOT/usr/local/bin/croc.new"' \
    "$configurator"
grep -Fq 'croc compatibility wrapper symlinks are forbidden' "$configurator"

echo "croc non-TTY stdin compatibility wrapper tests passed"

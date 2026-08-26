#!/bin/bash
set -euo pipefail

# croc treats every non-TTY stdin as file data before it considers explicit
# filenames or a receive code. SSH command runners and process supervisors can
# keep that pipe open without ever writing to it, which makes croc appear to
# hang. Add --ignore-stdin only when the command already contains an explicit
# file, text payload, receive code, or receive secret. A bare `croc send` keeps
# upstream's intentional piped-stdin behavior.

real_croc="${DAWNSHELL_CROC_REAL:-}"
if [[ -z "$real_croc" ]]; then
    if [[ -x /usr/local/libexec/dawnshell-croc-real ]]; then
        real_croc=/usr/local/libexec/dawnshell-croc-real
    else
        real_croc=/usr/bin/croc
    fi
fi
if [[ ! -x "$real_croc" ]]; then
    echo "dawnshell-croc: no upstream croc executable was found" >&2
    echo "dawnshell-croc: install croc in /usr/bin or /usr/local/libexec/dawnshell-croc-real" >&2
    exit 127
fi

for argument in "$@"; do
    case "$argument" in
        --ignore-stdin|--ignore-stdin=*) exec "$real_croc" "$@" ;;
    esac
done

command_name=
after_send=false
expect_value=false
explicit_payload=false

for argument in "$@"; do
    if [[ "$expect_value" == true ]]; then
        expect_value=false
        continue
    fi

    case "$argument" in
        --transport|--multicast|--curve|--ip|--relay|--relay6|--out|--pass|\
        --socks5|--connect|--throttleUpload|--revoke|--code|-c|--hash|\
        --port|--transfers|--exclude|--exclude-file|--store-downloads|\
        --store-expiration|--store-url)
            expect_value=true
            ;;
        --text|-t)
            [[ "$after_send" == true ]] && explicit_payload=true
            expect_value=true
            ;;
        --text=*|-t=*)
            [[ "$after_send" == true ]] && explicit_payload=true
            ;;
        --*=*|--*|-*)
            ;;
        send)
            command_name=send
            after_send=true
            ;;
        relay|help|h)
            command_name="$argument"
            after_send=false
            ;;
        *)
            if [[ "$after_send" == true ]]; then
                explicit_payload=true
            elif [[ -z "$command_name" ]]; then
                command_name=receive
                explicit_payload=true
            fi
            ;;
    esac
done

# A secret supplied through the environment with no send command is an
# explicit receive request. Do not apply this rule to `croc send` because a
# caller may intentionally pipe the outgoing payload while setting the secret.
if [[ -n "${CROC_SECRET:-}" && "$command_name" != send && \
      "$command_name" != relay ]]; then
    explicit_payload=true
fi

if [[ "$explicit_payload" == true ]]; then
    exec "$real_croc" --ignore-stdin "$@"
fi

exec "$real_croc" "$@"

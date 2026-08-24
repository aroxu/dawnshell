#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
java_protocol="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecProtocol.java"
broker="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecBroker.java"
service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/HardwareCodecService.java"
client="$repo_dir/app/src/main/cpp/dawnshell_codec_client.c"
runtime="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"

grep -Fq 'MAGIC = 0x44534342' "$java_protocol"
grep -Fq 'VERSION = 1' "$java_protocol"
grep -Fq 'MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024' "$java_protocol"
grep -Fq 'socket.getPeerCredentials()' "$broker"
grep -Fq 'credentials.getUid() != 0' "$broker"
grep -Fq 'MAX_SESSIONS_PER_PEER' "$broker"
grep -Fq 'payload length exceeds limit' "$broker"
grep -Fq 'HardwareCodecProtocol.INPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.OUTPUT' "$broker"
grep -Fq 'HardwareCodecProtocol.FLUSH' "$broker"
grep -Fq 'HardwareCodecProtocol.EOS' "$broker"
grep -Fq 'HardwareCodecProtocol.CLOSE' "$broker"
grep -Fq 'ensureBrokerStarted()' "$service"

grep -Fq '#define DSCB_MAGIC 0x44534342u' "$client"
grep -Fq '#define DSCB_VERSION 1u' "$client"
grep -Fq '#define DSCB_SOCKET_NAME "dawnshell.codec.v1"' "$client"
grep -Fq 'address.sun_path[0]' "$client"
grep -Fq 'pipe stdin/stdout records are:' "$client"

grep -Fq 'codecClientBinary = new File(bin, "dawnshell-codec")' "$runtime"
grep -Fq 'hardware_codec_client=/usr/local/bin/dawnshell-codec' "$configurator"
for abi in armeabi-v7a arm64-v8a x86_64; do
    test -s "$repo_dir/app/src/main/assets/bfu/bin/$abi/dawnshell-codec"
    grep -Fqx 'dawnshell_codec_protocol=1' \
        "$repo_dir/app/src/main/assets/bfu/bin/$abi/runtime.properties"
done

echo "Hardware codec broker protocol, client, and three-ABI assets are pinned"

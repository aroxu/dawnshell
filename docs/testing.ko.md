# 테스트 계획

[English](testing.md)

## 사전 검사

```sh
adb shell getprop ro.crypto.state
adb shell getprop ro.crypto.type
adb shell getprop ro.product.cpu.abi
adb shell dumpsys package me.aroxu.dawnshell | grep -E 'targetSdk|appId|dataDir'
adb shell dumpsys user | grep -i unlocked
```

기대값은 encrypted, 가능한 경우 crypto type `file`, 지원 ABI 중 하나,
target SDK 28, 독립 app ID다. Android 16 custom ROM은 `ro.crypto.type`이 비어
있을 수 있으므로 최종 각 cycle의 locked `CE_ISOLATION_PROBE`로 sentinel이
읽히지 않았음을 증명해야 한다. `file`이 아닌 nonempty 값은 실패다. 앱을 한 번
열어 Direct Boot를 켜고 저장하며 vendor battery restriction 예외를 설정한다.

## Milestone 1: locked boot broadcast

1. logcat을 지우고 재부팅한다.
2. PIN/pattern을 입력하지 않는다.
3. unlock 없이 ADB가 가능하면 로그를 검사한다.

대상 ROM이 최초 unlock 전 ADB를 막으면 ADB 때문에 unlock하지 않는다. BFU
단계는 network SSH로 검사하고 unlock 뒤 같은 boot의 DE marker를 읽는다.

```sh
adb logcat -c
adb reboot
adb wait-for-device
adb shell dumpsys user | grep -i unlocked
adb logcat -d -s DawnShell:I '*:S'
adb shell run-as me.aroxu.dawnshell \
  cat /data/user_de/0/me.aroxu.dawnshell/files/bfu-boot.log
```

user 0이 locked이고 새 `LOCKED_BOOT_COMPLETED <unix-epoch-milliseconds>` line이
있어야 통과다. marker는 service 시작보다 먼저 fsync되어 logcat보다 강한 증거다.

## Milestone 2: DE executable

로그에 다음이 있어야 한다.

```text
DE context initialized: /data/user_de/0/me.aroxu.dawnshell/files
BFU runtime verified: .../files/bfu
DE executable probe succeeded: DawnShell DE executable OK; ...
```

debuggable build에서는 다음처럼 app UID로 검사한다.

```sh
adb shell run-as me.aroxu.dawnshell ls -la files/bfu/scripts files/bfu/etc
adb shell run-as me.aroxu.dawnshell files/bfu/scripts/test.sh
```

root로 억지 통과시키지 않는다. denial이면 AVC를 보존하고 `nativeLibraryDir`
전략을 별도로 시험한다.

## Debian gate 1: BFU root와 CE 격리

unlock 상태에서 **Magisk 루트 권한 요청 / 확인**을 누르고 standalone UID에
영구 권한을 준다. AFU 결과 `exit=0 root=true`는 준비 확인일 뿐 BFU 증거가 아니다.

```sh
./scripts/test-root-bfu.sh
```

스크립트는 reboot 전 line count를 기록하고 30초 locked interval 뒤 unlock을
요청해 `bfu-root.log`를 읽는다. 최신 line에 다음이 모두 있어야 한다.

```text
exit=0
root=true
user_unlocked_before=false
user_unlocked_after=false
output=uid=0(
```

**BFU probe 결과 새로고침**은 같은 DE log를 읽기만 하며 `su`를 재실행하지
않는다. `bfu-root-authorization.log`는 BFU 증거로 대체할 수 없다.

CE 격리 log에는 새로 다음 결과가 있어야 한다.

```text
ce_isolated=true
user_unlocked_before=false
user_unlocked_after=false
output=TERMUX_CE_ISOLATED sentinel_unreadable=true
```

ROM이 sentinel을 노출하면 override를 끈 채 fail-closed를 먼저 확인한다.
기능 시험을 위해 명시적으로 override했다면
`BFU_EXPECT_CE_READABLE_OVERRIDE=1`을 설정하고
`TERMUX_CE_CONTENT_ACCESSIBLE`와 `CE_ISOLATION_OVERRIDE_USED`를 모두 요구한다.
FBE를 약화하거나 결과를 숨기지 않는다.

## Debian gate 2: rootfs 접근

unlock 상태에서 앱 installer를 사용한다. Termux package는 필요 없다.
**로그 → Debian 설치**에서 `SUCCEEDED`까지 보고 선택된 ABI, SHA-256 두 개,
유효한 Release signature, Debian 13/Trixie 검증, `INSTALL_SUCCEEDED`를 확인한다.
`/data/local/debian/.dawnshell-rootfs`에는 `suite=trixie`가 있어야 한다.

```sh
./scripts/test-rootfs-bfu.sh
```

이전 빌드가 `https:__..._Packages` 누락이나 `stat -c` 미지원으로 실패했다면
업데이트 APK를 설치하고 다시 실행한다. 기존 partial tree는
`/data/local/debian.failed.<epoch>`로 보존된다. 새 실패에서는 앱의
`DEBOOTSTRAP_LOG_TAIL_BEGIN/END`를 수집한다.

모든 full-screen 로그에서 오래된/최신 line까지 drag scroll, long-press 다중
선택/복사, copy-all을 시험한다. 선택 중이나 위로 스크롤한 동안 1초 refresh가
내용을 교체하거나 bottom으로 점프하면 안 된다.

unlock 뒤 최신 `bfu-rootfs.log`는 다음을 포함해야 한다.

```text
rootfs=/data/local/debian
exit=0
accessible=true
user_unlocked_before=false
user_unlocked_after=false
output=Debian-rootfs-access-ok root=/data/local/debian shell=/data/local/debian/bin/sh rw=true
```

이 probe는 저장소 접근만 확인하며 Debian ELF 실행은 다음 chroot gate로 남긴다.

## Debian gate 3: namespace와 chroot

```sh
./scripts/test-debian-runtime-bfu.sh
```

cold boot 후 locked 상태에서 생성된 새 결과가 다음을 만족해야 한다.

```text
exit=0
timeout=false
namespace_chroot=true
user_unlocked_before=false
user_unlocked_after=false
output=BFU_DEBIAN_NAMESPACE_OK pid=1 proc1=sh arch=<armhf|arm64|amd64> debian=13
```

helper는 Termux CE를 쓰지 않고 mount/PID/UTS/cgroup namespace를 만들며 Android
IPC/network를 공유한다. private `/proc`와 `/run`에서 Debian shell이 PID 1이 된
뒤 종료한다. 실패의 `stage=unshare_cgroup`, `proc_mount`, `chroot`,
`exec_debian_shell` 등을 보존한다. 이 성공은 one-shot launcher/chroot 증거이며
systemd 257 성공 증거는 아니다.

## Debian gate 4–7: systemd, D-Bus, BFU SSH

unlock 상태에서 생성된 Ed25519 공개 키를 확인하고
**Debian 13 systemd + SSH 구성**을 누른다. status는 `SUCCEEDED`, system config
로그는 두 `CONFIGURE_SUCCEEDED` line으로 끝나야 한다. 작업은 이전 test
instance를 중지하고 package 설치, `sshd` 검증, `ssh.service`,
`dawnshell-boot-proof.service`, ready marker를 설정하고 AFU validation용 systemd를
시작한다.

status의 성공 결과는 `BFU_DEBIAN_RUNNING`, valid supervisor/init identity,
private namespace topology, `network_namespace=android-shared`,
`network_mode=shared-nic`, D-Bus/SSH/TCP 22, delegated cgroup을 증명해야 한다.
uplink가 있으면 Tailscale mark priority 5200 rule이 Android table을 조회하고
`tbfu-host`, `TBFU_NAT`, `TBFU_FWD`는 없어야 한다. stop 뒤 rule도 없어야 한다.

다른 컴퓨터의 SSH 세션에서 검사한다.

```sh
ssh -p 22 -i /path/to/bfu_key debian@PHONE_IP
systemctl is-system-running
systemctl is-active dbus.service
systemctl is-active ssh.service
systemctl is-active dawnshell-boot-proof.service
systemctl is-active multi-user.target
test -f /run/dawnshell-enabled-service.ready
busctl --system --no-pager list
cat /proc/1/comm
ss -ltn
if test -r /sys/fs/cgroup/cgroup.controllers; then
  awk -F: '$1 == "0" && $2 == "" { print }' /proc/self/cgroup
else
  awk '$1 == "devices" { print }' /proc/cgroups
  test -r /sys/fs/cgroup/devices/devices.list
fi
```

같은 폰 AFU client는 **Termux private-key import command 복사**를 한 번 실행하고
owner-only `~/.ssh/dawnshell-ed25519`가 생기는지 확인한다. **SSH 접속 명령 복사**
후 `debian@127.0.0.1:22`에 password 없이 접속해야 한다. 120초 뒤 clipboard가
지워지고 DE와 Debian `authorized_keys`에 `PRIVATE KEY`가 없어야 한다.

결정적 cold-boot test:

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/bfu_key \
./scripts/test-systemd-ssh-bfu.sh
```

대기 중 unlock하지 않는다. TCP 22 SSH, `/proc/1/comm=systemd`, D-Bus,
configured+active `multi-user.target`, active SSH/proof service, proof marker,
delegated v2 root 또는 attached v1 devices view를 요구한다. 첫 unlock 뒤 PID 1
start ticks와 machine ID가 같고 각 locked gate의 same-cycle DE record가 정확히
하나씩 새로 생겨야 한다.

실패 전 lifecycle log를 복사한다. `cgroup_v2_mount`,
`cgroup_v2_device_bpf_attach`, `cgroup_v1_devices_mount`,
`devices_cgroup_move_pid1`, `cgroup_view_devices_bind`,
`namespace_command_setns_cgroup`, `exec_systemd`, `systemd_early_exit`가 정확한
gate를 나타낸다. mount denial은 root로 kernel log를 수집한다.

```sh
su root -c 'dmesg | tail -n 100 | grep -Ei "avc:|denied|cgroup|devices" || true'
```

Android hierarchy root를 Debian에 bind해 고치면 안 된다.

## 네트워크·Docker·reboot 검증

uplink 없이 시작해 systemd/sshd가 유지되는지 확인하고 Wi-Fi를 켠 뒤 Debian
재시작 없이 outbound IPv4와 phone IP SSH를 검사한다. 가능하면 USB Ethernet을
hot-plug하고 local subnet SSH/outbound를 반복한다. route 변경 때 lifecycle log의
`tailscale_bypass_table=`도 갱신되어야 한다. kernel-mode Tailscale은 shared
netns의 `tailscale0`과 IPv4 control-plane 연결을 요구한다.

Docker는 먼저 **안전한 host network only**를 적용해
`requested=host resolved_backend=none`을 확인한다. 컨테이너는
`--network host`를 쓴다. bridge 시험은 network를 파괴할 수 있으므로 별도
recovery path가 있을 때만 한다. auto는 native nftables → iptables-nft → legacy
순서로 검사하고 완전한 backend가 없으면 안전 host-only로 끝나야 한다.
Wi-Fi/모바일/USB Ethernet/VPN/Tailscale/SSH를 dockerd 전후 모두 확인한다.
unmanaged `daemon.json`은 보존되어야 한다.

`su root -c '/usr/local/sbin/reboot --check'`는
`Android host reboot bridge ready`를 출력하고 `debian` 사용자로는 실패해야 한다.
비파괴 테스트에서 `reboot now`를 실행하지 않는다. 이 명령은 의도적으로 Android
전체를 재부팅한다.

## 최초 unlock 연속성

BFU service 실행 중 한 번 unlock하고 다음을 확인한다.

- `USER_UNLOCKED received` 하나
- BFU foreground service 계속 실행
- 동일 Debian systemd PID와 namespace가 restart 없이 유지

일반 Termux boot script는 이 독립 앱의 범위 밖이다.

## reboot·격리 matrix

APK를 고정한 뒤 전체 물리 세션을 실행한다.

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/bfu_key \
BFU_CYCLES=5 \
./scripts/test-final-bfu.sh
```

각 cycle은 BFU SSH health 뒤 unlock을 요청하고 같은 Debian PID 1을 검증한다.
Android boot ID, app PID/RSS, supervisor, init host PID를 ignored
`test-results/`에 기록한다. boot ID 반복이나 32 MiB를 넘는 엄격한 단조 PSS
증가는 실패다. 설치 APK는 local staged artifact와 byte-for-byte 같아야 하고
DE helper digest도 staged APK에서 추출한 값과 매 cycle 일치해야 한다.

cycle 뒤 `test-systemd-shutdown-isolation.sh`가 status, restart/stop/start,
`systemctl poweroff`, `systemctl reboot`, fixed `shutdown`을 검사한다. Android
boot ID는 모두 불변이고 restart 뒤 SSH가 복구되어야 한다. BFU에서 CE를 root로
읽을 수 없는 것이 정상 결과이며 SELinux/FBE를 약화하지 않는다.

## 파괴적 rootfs 삭제

unlock 후 **Debian rootfs 영구 삭제**를 누르고 첫 경고 승인 뒤 `DELETE`를
입력한다. log에 `DEBIAN_ROOTFS_REMOVE_STARTED/SUCCEEDED`, live systemd 없음,
`test ! -e /data/local/debian`을 요구한다. 반복 실행은
`result=already_absent`로 성공해야 하며 target을 `/data/local`로 넓히지 않는다.

# Debian 13 systemd BFU 구현

[English](debian-systemd.md)

## 최종 상태

```text
Android init (host PID 1)
  -> LOCKED_BOOT_COMPLETED
  -> DawnShell directBootAware foreground service
  -> 사전 승인된 Magisk su
  -> root start-debian helper
  -> private mount + PID + UTS + cgroup namespace
  -> Android IPC + network namespace 유지
  -> shared NIC + Tailscale bypass-mark route shim
  -> Android ABI에 맞는 Debian 13 Trixie armhf/arm64/amd64 chroot
  -> /sbin/init (Debian PID namespace의 PID 1)
  -> enabled systemd services
```

대상에서는 IPC와 network namespace를 새로 만들지 않는다. Debian은 Android의
Wi-Fi, 모바일, USB Ethernet, IP 주소, `tailscale0`을 직접 본다. manager는
Android default table을 추적해 Tailscale `0x80000/0xff0000` bypass mark에만
priority 5200 rule을 유지한다. veth/NAT/forwarding/DNAT는 없다.

IPC 공유는 필수 호환성 예외다. Samsung 4.4.302 커널은 이 프로세스가
`CLONE_NEWIPC`를 요청하면 `copy_ipcs -> mq_init_ns -> mqueue_mount -> mount_ns`
경로에서 panic한다. 최초 unlock은 기록만 하고 BFU service, namespace,
systemd, Debian service를 중지하거나 재시작하지 않는다.

기기 전체 재부팅이 필요할 때 configurator가 `/usr/local/sbin/reboot` bridge를
설치한다. `su root` 뒤 `reboot now`를 실행하면 private `/run`의 mode-0600 FIFO로
고정 token을 보내고 pre-chroot manager가 Android host PID namespace에서
`/system/bin/reboot`를 호출한다. `reboot --check`는 재부팅 없이 검사하며
`systemctl reboot`는 기존 namespace 격리를 유지한다.

## 저장소

Termux CE 경로는 금지한다. `/data/local/debian`은 BFU root process가 디렉터리,
`bin/sh` mode, read/write를 검증한 뒤에만 사용한다. launcher는 다른 root
경로를 거부한다. 앱 DE `files/bfu/`는 bootstrap, 제어, 로그용이며 전체 rootfs가
아니다. 따라서 DawnShell uninstall이 Debian을 묵시적으로 삭제하지 않는다.

## 런처 계약

APK의 ABI별 네이티브 `probe`는 파괴적 상태를 남기지 않고 namespace/mount
작업 전체를 실행한 뒤 Debian `/bin/sh`를 namespace PID 1로 실행하고 결과를
DE에 기록한다. kernel/SELinux/launcher 문제를 systemd gate와 분리한다.

동일 helper의 `start`, `restart`, `status`, `health`, `stop`은 lifetime lock,
PID start ticks, executable device/inode를 사용해 중복과 PID reuse를 막는다.
새 mount namespace에서 다음 순서로 작업한다.

1. `mount --make-rprivate /`
2. rootfs를 private self-bind하고 `nodev`를 유지하면서 그 private root에서만
   `nosuid`를 해제한다. `/dev`, `/sys`를 recursive slave bind하고 Debian
   `/sys`를 read-only로 만든다.
3. 새 PID namespace를 반영하도록 `/proc`를 mount한다.
4. `$ROOT/run`에 `mode=755,nosuid,nodev` tmpfs와 `/run/lock`을 만든다.
5. cgroup namespace 전에 delegated v2 payload + device BPF를 시도하고 자동
   모드에서 불가능하면 v1 `name=systemd` + `devices`로 fallback한다. Debian
   PID 1은 선택된 delegated subtree로만 들어가며 Android root hierarchy를
   보지 않는다.
6. `env container=dawnshell chroot "$ROOT" /sbin/init`을 실행한다.

Android host mount propagation은 바꾸지 않는다. lifecycle checkpoint와 결과는
DE에 기록한다. `USER_UNLOCKED`는 `start`/`stop`/`restart`를 호출하지 않는다.

명시적 stop은 검증된 Debian PID/mount namespace 안에서
`systemctl --no-block exit`을 요청한다. systemd container-manager의 정상 종료
경로라 unit이 정리되고 PID 1이 Android kernel halt 없이 끝난다. 대상 Samsung
4.4에서 `wait_status=0`이 검증됐으며 wedged manager에만 bounded fallback을 쓴다.

AFU configurator는 `systemd`, `systemd-sysv`, `dbus`, `openssh-server`를 설치하고
`debian` 사용자를 만든다. BFU 전용 host key를 생성하고 DE의 검증된 공개 키를
복사해 TCP 22 `ssh.service`를 활성화한다. `multi-user.target`에서 private
`/run` marker를 만드는 independent oneshot service도 활성화한다. Android 소유
kernel/module/udev/sysctl/clock/network 상태를 쓰는 unit은 mask한다.
`.dawnshell-systemd-ready`는 모든 검증 후 마지막에 쓴다.

client identity는 앱 CE에서 생성하고 공개 절반만 자동 프로비저닝한다. 선택적
Termux import command는 명시적으로 내보낸 private key를
`~/.ssh/dawnshell-ed25519`로 설치하며 connect command는 주소 변화와 무관한
`debian@127.0.0.1:22`를 쓴다. private key는 DE/rootfs/log에 들어가지 않는다.
clipboard import는 120초 뒤 값이 그대로면 지워지며 document export가 더
안전한 경로다.

unlock 후 `chpasswd` stdin으로 `root`와 `debian`의 로컬 비밀번호를 설정할 수
있다. SSH password/root login은 켜지지 않는다. root 비밀번호와 setuid `su`는
공유 network/IPC namespace에서 Android uid 0 권한을 주므로 강력한 권한이다.

start grace period 뒤 PID/mount/UTS/cgroup은 private, IPC/network는 Android와
동일한지 검사한다. Java가 네이티브 `health`를 polling해 systemd PID 1, D-Bus,
`multi-user.target`, `ssh.service`, proof service/marker, TCP 22, writable delegated
cgroup을 증명한다. health helper는 먼저 자신을 v2 payload 또는 v1 child로 옮겨
PID 1의 cgroup namespace에 들어가며 `/proc/self/cgroup`이 delegated view의
`/`을 보고하는지 확인한다.

최종 harness는 제한된 `shutdown-test`의 `poweroff`, `reboot`, `shutdown`도
검사한다. 외부 host script가 Android boot ID를 전후 비교하고 Debian을
재시작하므로 helper 자신의 종료 결과만 믿지 않는다.

## Trixie systemd 호환성 gate

Debian 13은 systemd 257을 쓴다. 업스트림 최소 Linux 기준은 3.15라 4.4.302가
버전만으로 거부되지는 않지만 권장 5.4보다 낮아 제한적으로만 테스트된다.
systemd 257은 legacy/hybrid cgroup v1에서 문서화된 force 조건이 없으면
부팅하지 않으므로 launcher가 process-local `SYSTEMD_PROC_CMDLINE`으로 두 flag를
제공한다. Android 실제 kernel cmdline은 바꾸지 않는다.

launcher는 systemd/Docker에 적합한 private writable delegated view를 제공하지
못하면 fail-closed한다. 자동 모드는 실제 cgroup-device BPF attach까지 포함한
v2 probe 후 완전 정리하고 v1로 fallback한다. force-v2/force-v1은 fallback하지
않는다. 4.4 대상에서 `devices`가 `hierarchy=0`이면 `CLONE_NEWCGROUP` 전에
controller를 attach하고 child만 노출한다. Android task를 옮기거나 제한하지
않고 hierarchy root를 Debian에 bind하지 않는다.

참고:

- [systemd v257 요구사항](https://github.com/systemd/systemd/blob/v257/README)
- [Linux devices controller](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/devices.html)
- [systemd v257 릴리스 노트](https://github.com/systemd/systemd/blob/v257/NEWS)

## Docker 네트워크 호환성

선택 정책은 DE preference에 저장하지만 명시적 AFU 버튼을 눌러야 적용한다.
`host`는 bridge/firewall/forwarding/masquerading/userland proxy를 끈 관리
`/etc/docker/daemon.json`을 게시한다. `auto`는 Docker 29 native nftables와
read-only ruleset query, `iptables-nft`, `iptables-legacy` 순서로 검사한다.
iptables는 Docker bridge에 필요한 `addrtype`, `MASQUERADE`, `conntrack`을
read-only `-C`로 검증한다. 모두 실패하면 `resolved_backend=none` host-only로
성공하며 강제 backend는 fail-closed한다. Android kernel 편차 때문에 bridge
정책의 IPv6 Docker firewall 관리는 비활성화한다.

Debian 실행 중 적용하면 identity가 검증된 PID 1을 중지하고 private AFU mount
namespace에서 정책을 쓴 뒤 이전 실행 상태를 복구한다. 기존 unmanaged 설정과
외부에서 변경된 managed 설정은 보존하고 실패로 보고한다.

## 순서가 있는 기기 gate

1. BFU `su -c id`가 `uid=0`을 반환하고 DE에 저장된다.
2. BFU root가 Debian rootfs 구조, shell mode, 임시 read/write를 검증한다.
3. root helper가 namespace를 만들고 v2→v1 cgroup을 선택하며 Android
   IPC/network를 유지하고 route watcher를 시작한다.
4. `chroot`에서 Debian `/bin/sh`가 namespace PID 1로 실행된다.
5. `/sbin/init`이 namespace PID 1이 된다.
6. D-Bus, `systemctl`, default target이 정상이다.
7. 최초 unlock 전 cold boot에서 `ssh.service`와 proof service가 시작된다.

gate 1과 Debian 13 rootfs 설치는 대상에서 증명됐다. 나머지 구현은 소스에
완료되어 있으며 고정 APK로 `scripts/test-final-bfu.sh`를 실행해 gate 2–7,
unlock 연속성, cold boot 5회, shutdown 격리를 한 번에 검증한다. 구현 완료를
BFU SSH 성공 증거로 간주하지 않는다.

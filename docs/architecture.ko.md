# 아키텍처

[English](architecture.md)

## 업스트림 조사 결과

초기 PoC는 Termux:Boot에 구현했지만 제품 BFU 구현은 패키지
`me.aroxu.dawnshell`, target SDK 28, shared UID가 없는 독립 앱으로 분리됐다.

업스트림 Termux:Boot의 AFU 전용 흐름은 다음과 같다.

```text
BOOT_COMPLETED
  -> BootReceiver
  -> /data/data/com.termux/files/home/.termux/boot/*
  -> 일반 파일마다 JobScheduler job 생성
  -> BootJobService
  -> com.termux.app.TermuxService (com.termux.service_execute)
```

`BootReceiver`와 `BootJobService`는 CE 경로와 Termux service를 고정해서 쓴다.
Termux의 `TermuxConstants`도 `/data/data/com.termux/files/usr`와 home을 정의하며
prefix가 바이너리에 컴파일된다고 명시한다. 따라서 이 경로를 BFU에서 억지로
사용하지 않는다.

## 목표 수명주기

```text
LOCKED_BOOT_COMPLETED
  -> directBootAware BootReceiver
  -> UserManager.isUserUnlocked() == false
  -> DE SharedPreferences의 활성화 설정 확인
  -> directBootAware BfuBootService (foreground)
  -> createDeviceProtectedStorageContext()
  -> 사전 승인 su
  -> root launcher
  -> CE 밖 Debian rootfs
  -> mount/PID/UTS/cgroup namespace (IPC/network 공유)
  -> Android NIC 직접 사용 + Tailscale fwmark route watcher
  -> chroot -> /sbin/init
  -> Debian PID namespace의 PID 1로 systemd 실행

USER_UNLOCKED (BfuBootService의 runtime receiver)
  -> 전환 기록
  -> BFU service와 Debian/systemd를 그대로 유지

BOOT_COMPLETED
  -> locked 상태 fallback으로 BFU service를 idempotent하게 보장
```

Android 문서상 `ACTION_USER_UNLOCKED`는 등록 receiver 전용이므로 service가
동적으로 등록한다. Manifest에는 `LOCKED_BOOT_COMPLETED`와 `BOOT_COMPLETED`만
둔다. 일반 Termux boot script는 별도 Termux:Boot 앱의 책임이다.

## 저장소 경계

BFU root는 반드시 Context API 결과로 계산한다.

```java
Context de = context.createDeviceProtectedStorageContext();
File root = new File(de.getFilesDir(), "bfu");
```

런타임 layout 계산에 `/data/user_de/0/...`를 하드코딩하지 않는다. user 0의
일반적인 경로는 `/data/user_de/0/me.aroxu.dawnshell/files/bfu`지만 Context
결과가 유일한 기준이다. 이전 Termux:Boot BFU와 자동 조정하지 않는다.

주요 DE 파일과 디렉터리는 다음과 같다.

```text
<DE filesDir>/bfu-boot.log
<DE filesDir>/bfu-root.log
<DE filesDir>/bfu-root-authorization.log
<DE filesDir>/bfu-ce-isolation.log
<DE filesDir>/bfu-rootfs.log
<DE filesDir>/bfu-debian-runtime.log
<DE filesDir>/debian-install.{status,log}
<DE filesDir>/debian-system-config.{status,log}
<DE filesDir>/debian-lifecycle.status
<DE filesDir>/docker-network-policy.{status,log}
<DE filesDir>/bfu-operation.log
bfu/
  bin/{dawnshell-toolbox,pkgdetails,gpgv,bfu-namespace-probe}
  etc/authorized_keys
  home/
  run/{debian-lifecycle.log,debian-supervisor.lock,debian-supervisor.state}
  scripts/
  downloads/
  tmp/
```

`BootReceiver`는 설정 확인이나 service 시작보다 먼저
`LOCKED_BOOT_COMPLETED <unix-epoch-ms>`를 `bfu-boot.log`에 append한다. logcat이
회전하거나 이후 단계가 실패해도 DE 사용 가능 시점의 receiver 실행을 증명한다.

DE `test.sh`는 owner-only mode로 직접 `execve()`하여 target-28 앱이 writable
DE 파일을 실행할 수 있는지 검사한다. `BfuRootProbe`는 shell 없이 bounded
`su -c id`를 실행하고 exit 0 및 `uid=0`을 모두 요구한다. unlock 전후 상태와
정제된 결과를 fsync하며 실패해도 foreground service는 죽지 않는다.

런처의 별도 root 승인 버튼은 AFU에서만 최대 120초 동안 Magisk UI를 허용하고
`su -c id`만 실행한다. 결과는 BFU 증거와 다른 파일에 기록하며 앱은 사용자가
임시/영구 중 무엇을 선택했는지 강제하거나 판별할 수 없다.

프로비저닝은 앱 CE에 고정 비밀 없는 sentinel, DE에 matching receipt를 쓴다.
locked 상태에서 root 검사가 성공한 뒤 앱 UID로 sentinel 읽기를 시도한다.
receipt가 없거나 CE 내용이 읽히면 Debian 시작은 fail-closed한다. 빈 CE mount
stub을 목록화할 수 있는 것만으로 내용 접근으로 판단하지 않는다.

CE 격리 gate 다음에는 `probe-rootfs.sh`가 `/data/local/debian`, `etc`, 실행 가능한
`bin/sh`, 임시 marker read/write/remove를 검사한다. 이 단계는 Debian ELF나
chroot를 실행하지 않아 저장소 접근과 loader/namespace 문제를 분리한다.

rootfs 설치는 AFU에서 사용자가 명시적으로 시작한다. foreground worker가 APK의
고정 입력과 기기 ABI 런타임을 DE에 프로비저닝하고 root helper를 호출한다.
helper는 소스 빌드 BusyBox, `pkgdetails`, `gpgv`만 사용하고 private mount
namespace에서 debootstrap을 실행한다. architecture, dpkg 상태, shell, Debian
버전, root ownership 검증 뒤 `/data/local/debian.installing`을 원자적으로
게시한다. Termux CE는 열거나 실행하지 않는다.

두 번째 AFU 작업은 systemd, D-Bus, OpenSSH를 설치한다. 임시 `policy-rc.d`로
post-install service 시작을 막고 unprivileged `debian` 계정을 만든다. SSH는
password, keyboard-interactive, empty password, root login을 모두 거부하고
IPv4 wildcard TCP 22에 bind한다. 공개 키는 DE에서 오며 BFU host key와 설치된
키는 BFU 접근 가능한 Debian rootfs에 있다. 별도 oneshot proof service는
`multi-user.target`에서 `/run/dawnshell-enabled-service.ready`를 만든다.

클라이언트 Ed25519 identity는 unlock 후 앱 CE `files/ssh/`에 owner-only로
생성한다. 공개 절반만 DE에 저장하고 private half는 document provider 또는
시간 제한 sensitive Termux import command로만 명시적으로 내보낸다.

## 수명주기와 멱등성

- BFU는 기본 비활성화이며 런처에서 한 번 켜야 한다.
- 비밀이 아닌 설정만 DE preference에 저장한다.
- service는 파일·프로세스 작업 전에 foreground로 승격한다.
- single-thread executor가 한 service에서 probe 중복 실행을 막는다.
- `USER_UNLOCKED`는 BFU service를 중지·재시작하지 않고 기록만 한다.
- `BOOT_COMPLETED`는 service를 idempotent하게 요청한다. 이미 unlocked된 상태에서
  새로 생성된 service는 BFU probe를 건너뛰어 locked 증거를 오염시키지 않는다.
- root supervisor는 Android 앱 process와 독립적이므로 UI 재생성도 Debian PID 1을
  signal하거나 재시작하지 않는다.

## Debian 런처 경계

Android service는 작은 lifecycle controller이고 mount, namespace, chroot,
systemd는 검증 가능한 네이티브 root launcher가 담당한다. universal APK에서
ARMv7/ARM64/x86_64 PIE를 선택해 owner-only DE에 복사하며 Android platform
linker, `libc.so`, `libdl.so`만 의존한다.

`probe`는 root 소유의 정확한 `/data/local/debian`만 받는다. private
mount/PID/UTS/cgroup namespace를 만들고 `/`를 recursively private로 전환한다.
`/dev`, `/sys`는 slave bind, `/proc`는 PID namespace용으로 mount, `/run`은
private tmpfs로 만들고 chroot Debian `/bin/sh`를 PID 1로 실행한다. Samsung
4.4 커널이 새 IPC namespace의 `mqueue_mount`에서 panic하므로
`CLONE_NEWIPC`는 사용하지 않는다.

장기 실행 helper는 `start`, `restart`, `status`, `health`, `stop`을 제공한다.
start는 수명 전체 exclusive lock, PID start ticks, executable device/inode,
namespace inode를 기록하고 orphan/중복을 거부한다. Android IPC/network는
동일해야 하고 요청한 나머지 namespace는 달라야 한다.

host manager는 Android route table을 추적해 Tailscale bypass mark
`0x80000/0xff0000`에 priority 5200 IPv4/IPv6 rule만 설치한다. veth, NAT,
forwarding, DNAT는 없다. uplink가 없어도 systemd/sshd는 유지되고 watcher가
재시도한다. root-only mode-0600 FIFO `/run/dawnshell-host-reboot`도 관리하며
literal token만 받아 Android host PID namespace에서 `/system/bin/reboot`를
실행한다. `systemctl reboot`는 namespace에 격리된 채 유지된다.

stop은 identity가 검증된 supervisor만 대상으로 systemd container manager의
`systemctl exit`을 요청한다. 정상 경로는 Android kernel halt로 들어가지 않는다.
rootfs는 private self-bind이므로 systemd shutdown이 chroot root를 remount해도
Android `/data` mount는 변하지 않는다. `/sys`와 `/proc/sys`는 read-only다.

health는 PID reuse race를 막기 위해 identity를 다시 검사한 뒤 검증된
PID/mount/cgroup namespace에 들어간다. PID 1, D-Bus, default target,
`multi-user.target`, `ssh.service`, TCP 22, delegated cgroup, proof service와
marker를 고정 명령으로 검사한다. `shutdown-test`는 `poweroff`, `reboot`,
`shutdown` 세 selector만 받으며 외부 harness가 Android boot ID 불변을 증명한다.

## cgroup 선택

기본 정책은 커널 버전을 파싱하지 않고 capability를 검사한다. private mount
namespace에서 cgroup v2를 mount하고 `dawnshell/payload` subtree를 만든 뒤 부모가
이미 위임한 controller만 켠다. 빈 probe child에 allow-only
`BPF_PROG_TYPE_CGROUP_DEVICE`를 load/attach/detach한 경우에만 v2를 선택한다.
Debian은 payload만 `/sys/fs/cgroup`으로 보며 Android global hierarchy/task는
노출되지 않는다.

v2가 실패하면 probe subtree와 mount를 완전히 제거하고 v1 fallback으로 간다.
`CLONE_NEWCGROUP` 전에 `devices`를 v1 hierarchy에 연결하고 private
`name=systemd` hierarchy를 만든다. 각각 전용 `dawnshell` child를 만들고 미래
Debian PID 1을 두 child로 옮긴 뒤 cgroup namespace를 만든다. Debian에는 child
root만 `/sys/fs/cgroup/devices`와 `.../systemd`로 bind한다.

v1 controller attach는 kernel-global이지만 Android task는 hierarchy root에
남고 root allow-all policy를 바꾸지 않는다. Debian/Docker descendant는 부모가
허용한 장치를 더 제한할 수만 있고 거부된 장치를 허용할 수 없다. stop 시
descendant와 child를 재귀 삭제한 뒤 source hierarchy를 unmount한다.
`SYSTEMD_PROC_CMDLINE`은 Android `/proc/cmdline`을 바꾸지 않고 systemd 257의
legacy-force 조건만 process-local로 제공한다.

Docker 기본 host-only 정책은 bridge/firewall을 끈다. 선택적 native nftables,
iptables-nft, legacy negotiation은 `addrtype`, `MASQUERADE`, `conntrack`을
read-only probe한다. 자동 모드는 완전한 backend가 없으면 host-only로 돌아가고
강제 모드는 fail-closed한다. 모든 bridge 정책은 공유 Android network
namespace를 변경하므로 경고가 있는 명시적 AFU 작업이다.

## 플랫폼 제약

Android Direct Boot는 `android:directBootAware=true`와 DE Context API를 요구한다.
Android 10의 target-29 정책은 writable app home의 직접 실행 권한을 제거하므로
target SDK 28을 유지한다. boot broadcast는 foreground service background-start
예외이며 관련 없는 FGS type을 정책 우회 목적으로 지정하지 않는다.

참고 자료:

- [Android Direct Boot](https://developer.android.com/privacy-and-security/direct-boot)
- [ACTION_USER_UNLOCKED](https://developer.android.com/reference/android/content/Intent#ACTION_USER_UNLOCKED)
- [Android 10 실행 권한 변경](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
- [FGS background-start 제한](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Linux cgroup-v1 devices](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/devices.html)
- [Linux cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Docker cgroup/runtime](https://docs.docker.com/engine/containers/runmetrics/)

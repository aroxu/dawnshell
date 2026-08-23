# 보안 모델

[English](security.md)

## 불변 조건

1. BFU 런타임과 Debian은 CE에 의존하지 않는다. locked 상태의 유일한 CE
   접근은 고정된 비밀 없는 격리 sentinel에 대한 bounded read이며, 읽히면
   기본 정책이 시작을 차단한다.
2. 앱 제어 데이터는 DawnShell 소유 Device Protected Context에서만 만들고,
   별도로 검증한 rootfs 경로는 `/data/local/debian`으로 고정한다.
3. CE→DE 자동 동기화는 없다.
4. DE와 BFU rootfs에 사용자/client private SSH key, Termux user key, API token,
   Tailscale auth key, 평문 비밀번호, cloud credential, 개인 비밀을 두지 않는다.
   Debian BFU server host key와 app CE의 Ed25519 client identity는 분리한다.
5. Debian launcher는 root가 필요하지만 이를 가정하지 않는다. 매 boot에서
   `su -c id`가 실제 `uid=0`인지 증명하며 실패해도 controller는 crash하지 않는다.
6. 성능을 위해 Android network namespace를 공유한다. Android cgroup root는
   systemd에 노출하지 않고 검증된 v2 payload 또는 v1 전용 child만 위임한다.
7. locked 앱 UID가 프로비저닝된 CE sentinel 내용을 읽지 못함을 증명한 뒤에만
   rootfs/namespace launcher를 실행한다. 고정 경로와 판정만 log할 수 있다.

## DE 노출

DE는 사용자 PIN 기반 CE key가 아니라 verified boot/device key로 보호되므로
물리·offline·privileged 공격에 CE보다 약하다. DE에는 bootstrap/control,
공개 authorized key, 운영 로그만 둔다. BFU rootfs의 OpenSSH host key와 public
key 사본도 PIN 전에 접근 가능하므로 별도 offline threat 대상으로 본다.

## root와 namespace 제한

재부팅 전에 standalone DawnShell UID에 Magisk 권한을 영구 승인해야 한다. BFU
경로는 승인 UI를 무한정 기다리지 않으며 command path, exit, timeout, root
판정, 정제된 `id`만 기록한다. Magisk 정책은 numeric UID 기준이다. shared UID가
없어 Termux와 정책이 독립적이다. AFU 승인 버튼은 현재 UID의 package 목록을
보여주며 예상하지 않은 package가 있으면 승인하지 않는다. AFU 성공 결과는
BFU 증거로 복사하지 않는다.

root launcher는 고정 검증 경로만 받고 `/`를 recursively private로 바꾼 뒤
bind mount한다. DE를 CE 위에 bind하거나 FBE/SELinux를 약화하거나 Android
cgroup을 global remount하면 안 된다. lifetime `flock`, PID start ticks,
executable inode로 PID reuse를 막는다. `USER_UNLOCKED`는 stop 경로에 들어가지
않는다.

네이티브 helper는 API 24 PIE로 ARMv7/ARM64/x86_64를 지원하고 Android system
`libc.so`/`libdl.so` 외 의존성을 허용하지 않는다. 정확한 non-symlink,
uid-0-owned, group/world writable이 아닌 `/data/local/debian`만 받는다. 장기
실행 모드는 Android task 밖의 delegated cgroup child만 노출한다. v1 attach가
kernel-global이어도 root allowlist와 Android task 위치는 바꾸지 않는다.

rootfs는 private self-bind에서만 `nosuid`를 해제하고 `nodev`를 유지한다.
Android host `/data`는 remount하지 않는다. 따라서 Debian root shell은 실제
기기 수준 root 권한이며 보안 컨테이너 경계가 아니다. `/sys`, `/proc/sys`는
read-only지만 IPC/network는 Android와 공유한다. launcher가 만드는 host route
변경은 Tailscale exact mark용 priority 5200 rule뿐이며 supervisor 종료 때
제거한다.

host reboot bridge는 의도적으로 privileged하다. private DE의 root-owned
mode-0600 FIFO를 private Debian `/run`에만 bind한다. wrapper는 root caller와
인수 없음/`now`/`--check`만 받고 manager는 literal `ANDROID_REBOOT` token만
받는다. 성공하면 Android 전체가 재부팅된다.

health와 shutdown-test는 identity가 검증된 live PID 1의 namespace descriptor만
사용한다. helper를 delegated cgroup child로 옮긴 뒤 namespace에 들어간다.
health는 고정된 bounded systemd/D-Bus/socket/devices 검사만 수행한다.
shutdown-test selector는 `poweroff`, `reboot`, `shutdown`만 허용하고 외부 harness가
Android boot ID 불변을 증명한다.

rootfs accessibility probe는 rootfs top에 `.dawnshell-access-probe.<pid>`만
생성·읽기·삭제하며 Debian 설정, user, service, mount, CE를 바꾸지 않는다.

AFU rootfs 삭제 제어의 target은 compile-time `/data/local/debian` 하나다. 두
confirmation과 literal `DELETE`, symlink/resolved path 검사, graceful stop,
남은 systemd 부재, 삭제 후 부재 검증을 요구한다. app DE, staging sibling,
Termux data, caller path는 삭제하지 않는다.

## rootfs 공급망

설치는 unlock 후에만 가능하며 Termux/타 패키지 executable을 쓰지 않는다.
BusyBox, `pkgdetails`, `gpgv`, launcher는 `SOURCES.lock`의 고정 소스에서 빌드한다.
APK는 matching debootstrap과 Debian archive keyring을 포함한다. helper가 digest,
Debian Release signature, Packages index hash, package hash를 모두 다시 검사한다.
검증 건너뛰기 경로는 없다.

최종 rootfs를 덮어쓰거나 재귀 삭제하지 않는다. 같은 filesystem의 staging
sibling을 검증해 atomic rename한다. 중단 tree와 stale lock은 timestamp 이름으로
보존한다. 로그에는 package/path가 나올 수 있지만 repository credential, proxy
secret, password, private key는 절대 기록하지 않는다.

systemd/OpenSSH 설정도 AFU-only다. minbase에 CA가 없을 때 첫 signed APT
transaction만 HTTP를 쓸 수 있지만 Debian Release signature는 필수다. CA 설치
뒤 HTTPS source로 바꿔 다시 update한다. 임시 `policy-rc.d`로 package service
시작을 막고 복원한다. `sshd -t`, public-key-only effective policy, host key,
`ssh.service`, proof unit 검증 뒤에만 ready marker를 게시한다.

SSH 계정은 non-root다. 로컬 password는 `su`용으로 설정할 수 있지만 server는
password, keyboard-interactive, empty password, root authentication을 거부한다.
공개 키는 Java와 Debian `ssh-keygen`으로 검증하고 key option을 허용하지 않는다.
로그에는 key body 대신 count만 기록한다.

`root`/`debian` password 변경은 AFU-only다. 입력 필드를 즉시 비우고
`account:password`를 root-owned `chpasswd` stdin으로만 전달한 뒤 mutable buffer를
지운다. Intent, command line, preference, DE, log에는 password를 저장하지 않는다.
`/etc/shadow`의 salted hash는 BFU 접근 가능하므로 unique strong password를 쓰고
offline cracking을 threat model에 포함한다.

앱은 unlock 후 `SecureRandom`으로 unencrypted purpose-specific Ed25519 client
identity를 만들어 CE owner-only record에 둔다. private export는 명시적 AFU
작업이다. document picker는 사용자가 고른 위치로 쓰고 Termux command는 key를
Base64 clipboard에 포함하므로 확인, sensitive flag, log 금지, 120초 자동 삭제를
적용한다. rotation 뒤 Debian 재설정을 해야 새 공개 키가 반영된다.

Tailscale kernel TUN mode는 공유 network namespace에서 실행할 수 있다.
`tailscale0`, route, netfilter가 Android-global이므로 보안 격리가 아니라 성능
선택이다. 재사용 auth key를 DE/rootfs에 저장하지 않고 interactive login을
권장한다. 등록 후 `tailscaled.state`는 BFU device credential로 취급한다.

Docker도 공유 network 설계에서 보안 경계가 아니다. 기본 host-only 정책은
bridge, iptables/ip6tables, forwarding, masquerading을 끈다. bridge 자동 모드는
native nft/iptables 기능을 read-only probe하고 불완전하면 host-only로 돌아간다.
성공한 bridge backend도 Android 전역 route/NAT/firewall을 바꾸므로 UI가 모두
위험으로 표시하며 동일 network 연결 외 별도 복구 경로가 필요하다.

정책 writer는 기존 unmanaged `/etc/docker/daemon.json`을 거부한다. managed
파일도 기록된 SHA-256과 일치할 때만 교체한다. 이것은 사용자 설정을 지키지만
위험한 bridge 정책을 안전하게 만들지는 않는다.

IPC 공유는 문서화된 호환성 예외다. Samsung 4.4.302 panic 때문에
`CLONE_NEWIPC` 재도입을 빌드가 거부한다. mount/PID/UTS/cgroup은 private,
IPC/network는 shared여야 한다. 공개 키 인증 emergency account와 검토된 BFU
service만 실행해야 하며 IPC 격리를 주장하려면 수정된 커널이 필요하다.

## 서명 경계

`me.aroxu.dawnshell`은 shared UID가 없으므로 Termux/Termux:Boot/plugin과 인증서를
맞출 필요가 없다. 다만 Android update는 계속 같은 인증서로 서명해야 한다.
체크인된 debug key는 공개되어 제품 배포에 부적합하며 production은 private
signing key를 요구한다.

## 로그

tag는 `DawnShell`이다. lifecycle action, DE root, runtime 검증, child PID/status,
정제된 exit error는 허용한다. key 내용, environment dump, credential 포함 full
command line, SSH packet data는 금지한다. 자동 health는 unit name/state만 쓰고
임의 system journal을 DE로 복사하지 않는다.

## CE-readable ROM override

기본 정책은 locked 상태에 앱 CE sentinel이 읽히면 fail-closed한다. 일부
legacy/custom ROM이 unlock 전 CE를 노출할 수 있어 exact sentinel-readable
결과에만 적용되는 명시적 DE preference override가 있다. receipt 누락, probe
error/timeout, root 실패, probe 중 unlock에는 적용하지 않고 매 사용을
`CE_ISOLATION_OVERRIDE_USED`로 저장한다.

이 override는 CE를 decrypt/mount하지 않는다. ROM이 이미 CE를 노출했다는 위험을
사용자가 수락하는 기능이며 기본 비활성화다. 활성화한 기기에서는 BFU root/SSH가
CE data에도 접근할 수 있다고 간주해야 한다.

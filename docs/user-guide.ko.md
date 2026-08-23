# DawnShell 사용자 매뉴얼

[English](user-guide.md)

[프로젝트 홈](../README.ko.md) · [설치 가이드](installation.ko.md) ·
[문제 해결](#문제-해결)

이 문서는 설치와 최초 구성을 마친 DawnShell의 일상 사용법을 설명한다. 아직
rootfs와 systemd/SSH를 구성하지 않았다면 먼저 [설치 가이드](installation.ko.md)를
따른다.

## 핵심 동작

- cold boot의 `LOCKED_BOOT_COMPLETED`에서 Debian systemd와 SSH를 시작한다.
- Android 최초 unlock 전과 후에 같은 Debian 인스턴스를 유지한다.
- Debian은 Android NIC와 network namespace를 공유한다.
- 앱 설정·로그·공개 키는 DE, client private key는 앱 CE, Debian 전체 rootfs는
  `/data/local/debian`에 있다.
- SSH는 `debian` 계정의 공개 키 인증만 허용하며 기본 포트는 TCP 22다.
- Debian root shell은 Android 기기 수준 root 권한이므로 일반 컨테이너처럼
  안전하게 격리됐다고 가정하면 안 된다.

## 화면 구성

### 1 · 다이렉트 부트

**다이렉트 부트 Debian 부트스트랩 활성화**는 다음 cold boot 자동 시작을
제어한다. switch를 바꾼 뒤 반드시 **BFU 설정 저장 및 런타임 배치**를 눌러야
한다. 저장하지 않은 변경이 있으면 화면에 경고가 표시된다.

**Magisk 루트 권한 요청 / 확인**은 AFU에서 현재 UID가 root를 사용할 수 있는지
확인한다. cold boot 전에 Magisk의 영구 허용 정책이 유지되는지도 별도로 확인한다.

**BFU 검사 결과 새로고침**은 저장된 locked-boot 증거를 읽기만 한다. 이 버튼을
unlock 상태에서 눌렀다고 BFU probe를 다시 실행하거나 성공으로 바꾸지 않는다.

CE-readable override는 진단 세부 정보에 있는 위험 옵션이다. 정상 FBE 기기에서는
항상 끈다. 이 옵션은 암호화를 고치는 기능이 아니라 ROM이 이미 CE를 노출하는
상태에서 위험을 수락하고 시작 차단만 해제한다.

### 2 · Debian 설정

**Debian 13 Trixie rootfs 설치**는 최초 설치 또는 유효한 기존 설치 확인에 쓴다.
기존 `/data/local/debian`을 덮어쓰거나 in-place release upgrade하지 않는다.

**Debian 13 systemd + SSH 구성**은 systemd, D-Bus, OpenSSH, `debian` user,
현재 앱 공개 키, proof service를 구성한다. SSH client key를 교체했거나 rootfs를
복원한 뒤에도 다시 실행한다.

두 작업은 Android가 unlocked된 AFU에서만 시작할 수 있다. 진행 중에는 각각
Debian 설치/시스템 구성 로그를 확인한다.

### 3 · 서버 제어

- **시작**: rootfs와 ready marker를 검증하고 새 Debian systemd PID 1을 시작한다.
- **재시작**: 검증된 기존 인스턴스를 정상 종료하고 새 인스턴스를 시작한다.
- **상태**: supervisor identity, namespace, systemd, D-Bus, target, SSH, TCP 22,
  cgroup health를 검사한다.
- **중지**: systemd container `exit` 경로로 unit을 정리하고 SSH를 중지한다.

Android unlock 이벤트는 자동으로 중지를 실행하지 않는다. 수동 중지 뒤 다시
사용하려면 **시작**을 누르거나 다음 cold boot의 자동 시작을 기다린다.

### 4 · SSH 접속

**SSH 개인 키 파일 내보내기**가 외부 PC에 권장되는 방법이다. 파일은
unencrypted credential이므로 mode 0600으로 제한하고 비공개 저장소에 둔다.

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

**Termux 개인 키 가져오기 명령 복사**는 같은 휴대폰의 본인 Termux에 한 번
붙여 넣는 편의 기능이다. 명령 전체에 private key가 포함되므로 다른 앱, 메신저,
shell history 공유 화면에 붙여 넣지 않는다. **SSH 접속 명령 복사**는
`debian@127.0.0.1:22`용 명령을 복사한다.

**새 임의 SSH 클라이언트 키 생성**은 기존 client identity를 영구 교체한다.
교체 순서:

1. 필요한 경우 기존 private key를 백업한다.
2. 새 key를 생성한다.
3. **Debian 13 systemd + SSH 구성**을 다시 실행한다.
4. 새 private key를 client로 다시 내보낸다.
5. 새 key 접속을 확인한 뒤 기존 export를 폐기한다.

rootfs 재설치로 SSH host key가 바뀌어 known_hosts 경고가 발생하면 실제 재설치
사실을 확인한 뒤 해당 항목만 제거한다.

```sh
ssh-keygen -R "[PHONE_IP]:22"
```

### 계정

`root`와 `debian`의 로컬 password를 각각 8~128자로 설정할 수 있다. password는
`chpasswd` stdin으로만 전달되고 앱 설정·DE·로그에 저장되지 않는다. SSH는 계속
password 인증과 root login을 거부한다.

SSH로 `debian`에 접속한 뒤 root 전환:

```sh
su root
```

앱에서 설정한 Debian root password를 입력한다. root shell에서 나가려면
`exit`를 실행한다. 이 root는 Android network/IPC를 공유하는 실제 기기 수준
권한이므로 신뢰한 명령만 실행한다.

Android 전체를 의도적으로 재부팅하려면 root에서 다음을 실행한다.

```sh
reboot --check
reboot now
```

`reboot --check`는 bridge만 확인하고, `reboot now`는 Android 전체를 즉시
재부팅한다. 반면 `systemctl reboot`는 Debian namespace 격리 시험 경로이므로
기기 재부팅 명령으로 사용하지 않는다.

### 커널 & Docker 호환성

cgroup 기본값 **자동: v2 → v1**을 권장한다. v2 강제는 device BPF나 delegation이
부족한 커널에서 Debian을 부팅하지 못할 수 있고, v1 강제는 최신 경로를 건너뛴다.
설정은 다음 Debian start/restart부터 적용된다.

Docker network 기본값 **안전한 호스트 네트워크만 사용**에서는 컨테이너를
다음처럼 실행한다.

```sh
docker run --network host ...
```

bridge 옵션은 Android 전역 firewall, NAT, forwarding, route를 변경해 Wi-Fi,
모바일, USB Ethernet, VPN/Tailscale, 현재 SSH를 끊을 수 있다. 원격 연결과 다른
recovery path 없이 강제 bridge backend를 사용하지 않는다. 정책 switch를
선택하는 것만으로 적용되지 않으며 **Docker 네트워크 정책 적용**을 누를 때만
Debian 중지→probe→설정→이전 실행 상태 복구를 수행한다.

### 로그

상단 **로그**에서 다음 stream을 연다.

- 앱 작업: 버튼 요청, 검증 결과, 오류
- Debian 설치: debootstrap과 rootfs 게시
- 시스템 구성: APT, systemd, OpenSSH, account 배치
- 호환성 정책: cgroup과 Docker backend probe
- 서버 수명 주기: start/stop/restart/status/health
- 다이렉트 부트 진단: boot marker, BFU root, CE, rootfs, chroot probe

각 reader는 1초마다 갱신되고 scroll, long-press 선택, 전체 복사를 지원한다.
선택 중이거나 이전 line을 읽도록 위로 스크롤하면 자동 follow가 멈춘다.
오류를 신고할 때 private key/password를 추가하지 말고 관련 stream 전체를
복사한다.

## 네트워크 사용

sshd는 주소가 아직 없어도 wildcard TCP 22에서 listen한다. Android가 나중에
Wi-Fi, 모바일, USB Ethernet 주소를 붙이면 Debian 재시작 없이 접속할 수 있다.

같은 Wi-Fi의 PC:

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

같은 휴대폰 Termux:

```sh
ssh -i "$HOME/.ssh/dawnshell-ed25519" -p 22 debian@127.0.0.1
```

Tailscale kernel mode는 `tailscale0`과 route/netfilter를 Android와 공유한다.
재사용 auth key를 BFU rootfs에 저장하지 말고 interactive login을 권장한다.
등록된 `tailscaled.state`는 PIN 전에도 사용되는 device credential로 취급한다.

## 업데이트와 백업

공식 업데이트는 [GitHub Releases](https://github.com/aroxu/dawnshell/releases)에서
받고 `SHA256SUMS`를 검증한다. 동일 release signing key APK는 기존 앱 위에
설치한다. 업데이트 뒤 unlock 상태에서 **BFU 설정 저장 및 런타임 배치**를 다시
실행하고 상태/restart/cold boot를 검증한다.

백업 권장 항목:

- 앱에서 내보낸 DawnShell SSH client private key
- Debian 안의 필요한 `/etc`, 사용자 데이터, service 설정
- 설치한 package 목록과 별도 application data

앱 설정과 rootfs는 자동 양방향 동기화되지 않는다. APK uninstall은 app CE/DE와
생성 client key를 지우지만 `/data/local/debian`을 자동 제거하지 않는다.
반대로 앱의 위험 구역에서 rootfs를 삭제해도 앱 설정/log는 남는다.

## 안전한 제거

Debian까지 완전히 제거하려면:

1. 필요한 데이터와 client key를 백업한다.
2. Android unlock 상태에서 **중지**하고 status로 systemd 부재를 확인한다.
3. **위험 구역 → Debian rootfs 영구 삭제**를 누른다.
4. 두 확인 창을 거쳐 literal `DELETE`를 입력한다.
5. 로그에서 `DEBIAN_ROOTFS_REMOVE_SUCCEEDED`를 확인한다.
6. 이후 Android 설정에서 DawnShell APK를 제거한다.

삭제 target은 정확히 `/data/local/debian` 하나다. staging/failed sibling이
남아 있다면 로그와 출처를 확인한 뒤 별도로 판단한다.

## 문제 해결

### cold boot에서 시작하지 않음

- Direct Boot switch 변경 후 **저장 및 런타임 배치**를 눌렀는지 확인한다.
- Magisk에서 DawnShell이 영구 허용인지 확인한다.
- unlock 후 다이렉트 부트 진단에서 새 `LOCKED_BOOT_COMPLETED`, BFU root,
  CE isolation, rootfs, chroot 결과를 순서대로 확인한다.
- vendor battery/자동 시작 제한에서 앱을 제외한다.

### `root=false`, timeout, permission denied

unlock 상태에서 root 승인 버튼을 다시 누르고 Magisk에서 영구 허용한다. BFU
중에는 승인 UI가 표시되지 않으므로 일회성 승인으로 해결할 수 없다. 예상하지
않은 package가 같은 UID 목록에 보이면 승인하지 않는다.

### Debian 설치 실패

Debian 설치 log의 마지막 `ERROR:`와 `DEBOOTSTRAP_LOG_TAIL`을 복사한다. checksum,
Release signature 오류는 우회하지 않는다. interrupted staging은 자동 보존되므로
진단 전에 `/data/local/debian.installing`이나 `.failed.*`를 무작정 지우지 않는다.

### systemd + SSH 구성 요청 실패

Android가 unlocked인지, Direct Boot 설정이 저장됐는지, rootfs 설치 status가
`SUCCEEDED`인지, Magisk root가 유효한지 확인한다. 시스템 구성 log의 첫 실패
stage를 수집하고 저장/배치 후 다시 시도한다.

### `ssh: connect ... port 22: Connection refused`

1. 앱 **상태**와 서버 수명 주기 log를 확인한다.
2. systemd/SSH 구성이 완료됐는지 확인한다.
3. Debian에서 `systemctl is-active ssh.service`와 `ss -ltn`을 확인한다.
4. 다른 process가 TCP 22를 점유하는지 확인한다.
5. remote 접속이면 Android가 BFU에서 실제 IP를 받았는지 확인한다.

`ssh user@host`만 입력하면 기본 port 22를 쓴다. DawnShell 역시 port 22가
기본이므로 별도 `-p`는 선택 사항이지만 key와 user `debian`은 정확히 지정한다.

### `network is unreachable`

sshd 문제와 uplink 문제를 구분한다. 같은 기기의 `127.0.0.1` SSH가 되지만 외부가
안 되면 Android interface/address/route를 확인한다. BFU에서 ROM이 Wi-Fi를
복원하지 않으면 DawnShell이 credential을 대신 열거나 연결할 수 없다.

### CE isolation 때문에 차단됨

정상 FBE 기기에서는 차단이 올바른 결과다. 먼저 ROM/FBE 설정을 조사한다.
CE-readable override는 해당 ROM이 unlock 전 CE를 이미 노출한다는 사실과
그 위험을 수락할 때만 켠다. 이 옵션은 보안을 복구하지 않는다.

### Docker 적용 후 네트워크가 끊김

가능하면 local console/ADB 같은 별도 recovery path에서 DawnShell을 열고
**안전한 호스트 네트워크만 사용**을 선택해 정책을 적용한다. 호환성 log를
수집한다. 공유 network namespace에서는 Docker bridge rule이 Android 전역에
영향을 준다.

### 업데이트 APK가 설치되지 않음

대부분 signing certificate가 다른 debug/custom APK와 공식 Release의 충돌이다.
현재 client key와 데이터를 먼저 백업한다. 기존 앱 uninstall은 app CE/DE를
삭제하므로 준비 없이 수행하지 않는다. 공식 Release끼리도 문제가 나면 Release
asset과 checksum, version, certificate 정보를 함께 보고한다.

## 관련 문서

- [설치 가이드](installation.ko.md)
- [보안 모델](security.ko.md)
- [아키텍처](architecture.ko.md)
- [상세 테스트 계획](testing.ko.md)
- [rootfs 설치 내부 동작](rootfs-installation.ko.md)

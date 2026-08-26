# Debian systemd와 SSH 구성

[English](debian-systemd.md) · [문서 홈](README.ko.md) · [쉬운 용어집](glossary.ko.md)

이 문서는 설치된 Debian rootfs에 systemd와 OpenSSH를 구성하고, BFU(Before
First Unlock)에서 계속 실행하는 방법을 설명합니다.

## systemd가 필요한 이유

systemd는 Debian의 서비스 관리자입니다. SSH, D-Bus, Tailscale 같은 서비스를
정해진 순서로 시작하고 상태를 추적합니다. DawnShell은 전용 PID(Process
Identifier) namespace 안에서 systemd를 PID 1로 실행합니다.

## 구성 버튼이 하는 일

**Debian 13 systemd + SSH 구성**은 다음 작업을 수행합니다.

1. rootfs와 ready marker를 확인합니다.
2. Debian 패키지 데이터베이스를 준비합니다.
3. systemd, D-Bus, OpenSSH를 설치하고 설정합니다.
4. `debian` 사용자를 생성합니다.
5. 현재 앱 공개 키를 `authorized_keys`에 넣습니다.
6. 비밀번호 SSH 인증과 root SSH 로그인을 끕니다.
7. 부팅 성공을 기록하는 proof service를 활성화합니다.
8. rootfs 내부 파일 권한과 소유권을 다시 확인합니다.

이 작업은 Android 잠금을 해제한 AFU(After First Unlock)에서만 시작합니다.
비밀번호와 개인 키는 로그에 남기지 않습니다.

## 실행 환경

런처는 Debian을 위해 다음 Linux namespace를 준비합니다.

- mount namespace: Debian 전용 마운트를 분리합니다.
- PID namespace: systemd를 Debian PID 1로 보이게 합니다.
- UTS namespace: 호스트 이름 `dawnshell`을 분리합니다.
- cgroup namespace: 위임된 자원 관리 계층만 보여 줍니다.
- network namespace: 분리하지 않고 Android 네트워크를 공유합니다.

chroot(change root)는 프로세스가 보는 `/`를 Debian rootfs로 바꾸지만 가상
머신은 아닙니다. 용어는 [쉬운 용어집](glossary.ko.md#debian과-원격-접속)을
참고해 주세요.

## 기본 마운트

Debian 안에는 `/proc`, `/sys`, `/dev`, `/dev/pts`, `/run`이 준비됩니다.
Android 호스트 `/data` 전체를 다시 마운트하지 않습니다. rootfs 내부의 `/data`는
필요한 최소 경로만 보이도록 유지합니다.

## 네트워크

Debian은 Android NIC(Network Interface Controller)를 직접 공유합니다. Wi-Fi,
모바일 데이터, USB Ethernet, VPN 인터페이스가 Android에서 준비되면 Debian도
바로 볼 수 있습니다.

SSH 서버는 주소가 없어도 TCP 22의 모든 주소에서 대기합니다. Android가 나중에
주소를 할당하면 systemd나 SSH를 다시 시작하지 않아도 됩니다.

## cgroup

DawnShell은 cgroup v2와 장치 BPF(Berkeley Packet Filter)를 먼저 시험합니다.
성공하면 전용 v2 하위 트리를 사용합니다. 실패하면 시험 자원을 정리한 뒤 격리된
cgroup v1 `devices`와 `name=systemd` 방식으로 전환합니다.

이 구조는 Debian과 Docker에 필요한 기능을 제공하면서 Android 전역 장치 정책을
직접 노출하지 않기 위한 것입니다.

## SSH 정책

OpenSSH는 다음 정책으로 구성합니다.

```text
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
```

SSH 개인 키는 앱 CE(Credential Encrypted) 저장소에 남고 공개 키만 Debian에
들어갑니다. 키를 바꿨다면 구성 버튼을 다시 눌러 새 공개 키를 반영합니다.

## 종료와 재시작

**중지**는 systemd에 정상 종료를 요청하고, 제한 시간까지 기다린 뒤 남은 자식
프로세스와 마운트, cgroup 하위 트리를 정리합니다. **재시작**은 이 종료 절차를
마친 뒤 새 systemd PID 1을 시작합니다.

`USER_UNLOCKED`는 종료 신호가 아닙니다. 사용자가 잠금을 풀어도 Debian과 SSH는
계속 실행됩니다.

## 상태 확인

앱의 **상태**는 다음 항목을 확인합니다.

- supervisor 프로세스와 boot ID
- systemd가 Debian PID 1인지 여부
- D-Bus와 기본 target
- `ssh.service`
- TCP 22 listen 상태
- cgroup health
- 마운트와 namespace identity

오류가 있으면 **서버 수명 주기**와 **시스템 구성** 로그를 함께 확인합니다.

## Android 전체 재부팅

Debian root 셸에서 `systemctl reboot`를 실행해도 Android 전체를 재부팅하지
않도록 격리합니다. Android 전체 재부팅은 DawnShell이 제공하는 명시적 bridge를
사용합니다.

```sh
reboot --check
reboot now
```

`reboot now`는 즉시 기기를 재부팅하므로 저장 중인 작업을 먼저 끝내 주세요.

# DawnShell 설치 가이드

[프로젝트 홈](../README.ko.md) · [사용자 매뉴얼](user-guide.ko.md) ·
[최신 릴리스](https://github.com/aroxu/dawnshell/releases/latest)

이 문서는 GitHub Actions가 빌드하고 태그에서 자동 게시한 공식 Release APK를
기준으로 한다. 일반 사용자는 `main` 브랜치의 debug artifact 대신
**GitHub Releases에 게시된 서명 APK**를 설치해야 한다.

## 1. 준비 사항

필수 조건:

- Android 7.0/API 24 이상과 FBE(File Based Encryption)
- `armeabi-v7a`, `arm64-v8a`, `x86_64` 중 하나의 ABI
- Magisk 또는 호환되는 `su`와 DawnShell에 대한 영구 root 승인
- Debian 패키지를 받을 인터넷 연결과 충분한 내부 저장 공간
- BFU 원격 접속이 목적이면 최초 unlock 전에도 ROM이 복원하는 Wi-Fi 또는
  다른 네트워크

DawnShell은 root 없이 Debian을 시작할 수 없다. ADB 권한은 설치나 Direct Boot
동작에 필요하지 않으며 진단용으로만 선택적으로 사용한다. 다른 SSH daemon이
이미 TCP 22를 사용하면 먼저 포트 충돌을 해결해야 한다.

Samsung 등 제조사 ROM에서는 앱을 배터리 최적화/절전/자동 시작 제한에서
제외하는 것이 좋다. 다만 BFU 중 네트워크 인터페이스와 주소를 실제로 복원하는
책임은 Android ROM에 있다.

## 2. 공식 Release 다운로드와 검증

1. [DawnShell Releases](https://github.com/aroxu/dawnshell/releases)에서 최신
   정식 버전을 연다.
2. Release 본문에 build commit과 asset 목록이 있는지 확인한다.
3. 최소한 다음 파일을 같은 폴더에 받는다.

```text
dawnshell-<version>.apk
SHA256SUMS
```

Release에는 다음 대응 자료도 함께 게시된다.

```text
dawnshell-<version>-<commit>-corresponding-source.tar.gz
dawnshell-<version>-<commit>-licenses.tar.gz
dawnshell-<version>-<commit>-build-info.txt
RELEASE_NOTES.md
```

Linux, macOS 또는 Termux에서는 전체 asset을 받은 폴더에서 검증한다.

```sh
sha256sum -c SHA256SUMS
```

Windows PowerShell에서는 APK hash를 계산한 뒤 `SHA256SUMS`의 같은 파일 항목과
비교한다.

```powershell
Get-FileHash .\dawnshell-0.2.0.apk -Algorithm SHA256
Get-Content .\SHA256SUMS
```

파일명이 다르면 실제 Release 버전명으로 바꾼다. checksum이 다르면 설치하지
말고 파일을 다시 받는다.

### Actions artifact와 Release의 차이

- branch/pull request/manual workflow는 테스트용 debug APK를 artifact로 만들 수
  있다. 공개 debug key이므로 일반 설치·업데이트용이 아니다.
- `vMAJOR.MINOR.PATCH` 태그 빌드는 저장소의 private release key로 서명되고 모든
  검사와 checksum 재검증을 통과한 뒤 GitHub Release로 게시된다.
- 서로 다른 서명키의 APK는 기존 앱 위에 업데이트할 수 없다. debug/custom
  빌드에서 공식 Release로 전환하려면 앱 제거가 필요할 수 있으므로 먼저 SSH
  private key를 안전하게 내보낸다.

## 3. APK 설치

휴대폰에서 APK를 열어 해당 파일 앱/브라우저의 “알 수 없는 앱 설치” 권한을
일시 허용하고 설치한다. 설치 후 불필요하면 그 권한을 다시 끈다.

ADB를 사용하는 선택 경로:

```sh
adb install -r dawnshell-<version>.apk
```

동일한 release signing key로 서명된 업데이트는 `-r`로 앱 데이터와 설정을
유지한다. 서명이 다르면 제거 후 재설치해야 한다. DawnShell 앱 제거는 앱의
CE/DE 설정과 생성한 client key를 잃게 하지만 `/data/local/debian` rootfs는
자동 삭제하지 않는다.

## 4. 최초 실행과 Magisk 영구 승인

Android 잠금을 해제한 상태에서 DawnShell을 연다.

1. **Magisk 루트 권한 요청 / 확인**을 누른다.
2. 확인 창에 예상한 DawnShell package만 표시되는지 확인한다.
3. Magisk 승인 창에서 **영구/항상 허용**을 선택한다.
4. 앱의 최근 AFU 결과가 `exit=0`, `root=true`, `uid=0`인지 확인한다.

일회성 승인은 cold boot의 BFU 단계에서 승인 UI가 뜨지 않아 실패한다. 앱은
Magisk가 영구 정책을 저장했는지 판별할 수 없으므로 Magisk 관리자에서도
DawnShell 정책을 확인한다.

## 5. Direct Boot 설정과 런타임 배치

권장 초기값:

- **다이렉트 부트 Debian 부트스트랩 활성화**: 켬
- **CE 저장소를 읽을 수 있는 BFU 환경 허용**: 끔
- cgroup: **자동: cgroup v2 → v1 전환(권장)**
- Docker network: **안전한 호스트 네트워크만 사용(권장)**

그다음 **BFU 설정 저장 및 런타임 배치**를 누른다. 이 작업은 비밀 없는 설정,
CE 격리 sentinel/receipt, 기기 ABI용 네이티브 도구와 Debian bootstrap 입력을
앱 DE 저장소에 배치한다. “설정이 변경되었습니다” 표시가 남아 있으면 재부팅
전에 다시 저장한다.

CE-readable override는 기본적으로 켜면 안 된다. locked 상태에서 최신 CE 격리
probe가 실제로 `TERMUX_CE_CONTENT_ACCESSIBLE`을 기록했고 해당 ROM의 플랫폼
위험을 이해·수락한 경우에만 사용한다.

## 6. Debian 13 rootfs 설치

1. **Debian 13 Trixie rootfs 설치**를 누른다.
2. 확인 창에서 설치를 승인한다.
3. **로그 → Debian 설치**를 열어 진행 상황을 본다.
4. 상태가 `SUCCEEDED`이고 로그가 `INSTALL_SUCCEEDED`로 끝날 때까지 기다린다.

설치 프로그램은 기기 ABI에 맞는 앱 내장 도구로 Debian Release 서명과 package
hash를 검증하고 `/data/local/debian.installing`에 만든 뒤 검증된 결과만
`/data/local/debian`으로 원자 게시한다. 기존 rootfs는 덮어쓰지 않는다.

실패하면 앱을 지우거나 staging tree를 바로 삭제하지 말고 전체 설치 로그를
복사한다. 다음 재시도는 중단된 tree를
`/data/local/debian.failed.<timestamp>`로 옮겨 진단 자료를 보존한다.

## 7. systemd와 SSH 구성

rootfs 설치 성공 후 다음을 수행한다.

1. 화면의 생성된 Ed25519 공개 키가 표시되는지 확인한다.
2. **Debian 13 systemd + SSH 구성**을 누른다.
3. **로그 → 시스템 구성**에서 APT, systemd, OpenSSH 설정을 확인한다.
4. 상태가 `SUCCEEDED`, 마지막 결과가 `CONFIGURE_SUCCEEDED`인지 확인한다.
5. **상태**를 눌러 systemd PID 1, D-Bus, `ssh.service`, TCP 22, cgroup health가
   정상인지 확인한다.

SSH 기본 계정은 `debian`, 포트는 TCP 22다. SSH password와 root login은
비활성화되고 앱이 생성한 공개 키만 설치된다.

## 8. SSH private key 내보내기

다른 컴퓨터에서 접속하려면 **SSH 개인 키 파일 내보내기**로 파일을 저장해
안전한 방법으로 PC에 옮긴 뒤 소유자만 읽도록 제한한다.

```sh
chmod 600 dawnshell-ed25519
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

같은 휴대폰의 Termux에서 접속하려면:

1. **Termux 개인 키 가져오기 명령 복사**를 누른다.
2. 경고를 확인하고 복사한 한 줄을 본인의 Termux에 즉시 붙여 넣는다.
3. **SSH 접속 명령 복사**를 눌러 복사한 명령을 Termux에서 실행한다.

private key가 포함된 clipboard는 값이 바뀌지 않았다면 120초 뒤 자동 삭제된다.
그래도 clipboard 접근 앱이 있을 수 있으므로 파일 내보내기가 더 안전하다.

## 9. 최초 BFU 검증

설정이 모두 성공한 뒤 휴대폰을 재부팅하고 PIN/pattern을 입력하지 않는다.
다른 기기에서 휴대폰의 BFU 네트워크 주소로 접속한다.

```sh
ssh -i ./dawnshell-ed25519 -p 22 debian@PHONE_IP
```

접속 후 최소 확인:

```sh
id
cat /proc/1/comm
systemctl is-system-running
systemctl is-active ssh.service
ip addr
uptime
```

`/proc/1/comm`은 `systemd`, SSH service는 `active`여야 한다. 이후 Android를
unlock하고 기존 SSH session과 Debian PID 1이 재시작 없이 유지되는지 확인한다.
unlock은 DawnShell Debian을 중지하지 않는다.

## 10. 업데이트

1. 새 Release의 `RELEASE_NOTES.md`와 checksum을 확인한다.
2. 같은 signing key APK를 기존 앱 위에 설치한다.
3. unlock 상태에서 DawnShell을 한 번 연다.
4. **BFU 설정 저장 및 런타임 배치**를 다시 눌러 새 runtime asset을 반영한다.
5. 상태를 확인하고 계획된 시점에 Debian 재시작 또는 cold boot 검증을 한다.

업데이트 전에 client private key를 별도 안전한 위치에 보관하면 서명 오류나
재설치 상황에서 복구하기 쉽다. rootfs는 앱과 별도이지만 새 버전에서
지원하지 않는 downgrade/in-place 변경은 임의로 수행하지 않는다.

## 다음 문서

- 일상 운영과 화면 기능: [사용자 매뉴얼](user-guide.ko.md)
- 상세 rootfs 동작: [rootfs 설치 문서](rootfs-installation.ko.md)
- 보안 전제와 위험: [보안 모델](security.ko.md)
- 전체 실기기 검증: [테스트 계획](testing.ko.md)

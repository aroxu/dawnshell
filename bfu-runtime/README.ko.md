# BFU 런타임

[English](README.md)

현재 BFU 런타임은 독립 Dropbear 트리가 아니라 Debian 13 환경이다.
`scripts/build-bootstrap-runtime.sh`는 이 디렉터리에 고정된 소스에서 다음
Android ABI용 부트스트랩 도구를 모두 빌드한다.

- `armeabi-v7a` → Debian `armhf`
- `arm64-v8a` → Debian `arm64`
- `x86_64` → Debian `amd64`

각 ABI에는 최소 BusyBox 도구 상자, Debian `pkgdetails`, GnuPG `gpgv`,
namespace/chroot 런처가 포함된다. BusyBox 설정에는 rootfs 게시 단계가
소유권 확인에 사용하는 `stat -c` 형식 출력 기능이 반드시 포함된다. 빌드
스크립트가 이 설정을 불변 조건으로 검사하고, 기기 설치 프로그램도
다운로드나 staging 트리 변경 전에 이를 다시 확인한다.

이 디렉터리는 저장소 간 런타임 설계 결정을 기록한다. 런타임 키,
`authorized_keys`, PID, 로그는 DawnShell Device Protected Storage 또는 별도
검토된 기기의 Debian rootfs에만 두며 Git에 커밋하면 안 된다. 내장 helper는
고정된 `probe`, `start`, `restart`, `status`, `health`, `stop` 및 제한된 종료
격리 테스트만 제공하고 임의 셸 명령은 받지 않는다.

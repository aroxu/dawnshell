# DawnShell 내장 부트스트랩 런타임

[English](README.md) · [쉬운 용어집](../docs/glossary.ko.md)

이 디렉터리에는 Android에서 Debian 13 rootfs를 설치하고 시작하는 데 필요한
최소 도구의 소스, 패치, 설정과 버전 잠금 정보가 있습니다.

지원하는 ABI(Application Binary Interface)는 다음과 같습니다.

| Android ABI | Debian 아키텍처 |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

ABI는 CPU에 맞는 네이티브 실행 파일 규칙입니다.
[Google Android ABI 문서](https://developer.android.com/ndk/guides/abis)를 참고해 주세요.

각 ABI 런타임에는 BusyBox 도구 모음, Debian `pkgdetails`, 정적으로 연결한
`gpgv`, namespace 런처가 포함됩니다. BusyBox는 설치 완료 뒤 소유권을 확인하기
위해 `stat -c` 형식 출력을 지원합니다.

- 고정 소스와 SHA-256: `sources/SOURCES.lock`
- Android용 패치: `patches/`
- 최소 빌드 설정: `config/`
- 빌드 스크립트: `../scripts/build-bootstrap-runtime.sh`
- 서드파티 라이선스: [THIRD_PARTY_NOTICES.ko.md](THIRD_PARTY_NOTICES.ko.md)

실제 기기의 키, PID(Process Identifier), 로그와 `authorized_keys`는 이 저장소에
커밋하지 않습니다. 앱의 DE(Device Encrypted) 저장소 또는 검토된 Debian
rootfs에만 둡니다.

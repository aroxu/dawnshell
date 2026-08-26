# Dropbear 조사 메모

[English](README.md) · [문서 홈](../../docs/README.ko.md)

초기 최소 SSH 서버 후보로 Dropbear 2026.94를 조사했습니다. 현재 제품은 Debian
rootfs 안의 OpenSSH를 사용하므로 이 디렉터리는 소스 조사 메모만 보관합니다.

> 이 코드는 현재 APK의 BFU SSH 경로가 아닙니다. Dropbear를 빌드하거나 복사해도
> DawnShell의 systemd/OpenSSH 구성이 바뀌지 않습니다.

후보 실행 파일의 검토 기준은 다음과 같습니다.

- `arm64-v8a` PIE(Position-Independent Executable)로 빌드합니다.
- 런타임 공유 라이브러리 의존성을 최소화합니다.
- Android 사용자 번호나 앱 데이터 절대 경로를 고정하지 않습니다.
- source tarball과 SHA-256을 고정합니다.

PIE와 ABI 같은 용어는 [쉬운 용어집](../../docs/glossary.ko.md)을 참고해 주세요.

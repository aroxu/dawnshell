# Dropbear 빌드 요구사항

[English](README.md)

분석 당시 Termux 패키지와 같은 후보 소스는 Dropbear 2026.94다.

이 디렉터리에서 실제 산출물을 만들기 전 다음 조건을 증명해야 한다.

- 소스 SHA-256이 기록된 재현 가능한 `arm64-v8a` PIE 산출물
- 의도한 Android 시스템 런타임 외 `DT_NEEDED` 의존성이 없거나,
  API 36/커널 4.4에서 동작하는 정적 PIE 결과가 문서화되어 있을 것
- password/PAM/shadow/keyboard-interactive 코드 경로가 없을 것
- Termux prefix, `/data/data/com.termux`, 고정 `/data/user_de/0` 문자열이 없을 것
- host key, authorized keys, PID, home, shell, port 경로를 런타임에서 받을 것
- `nativeLibraryDir` 실행과 비교용 DE `filesDir` 실행을 모두 검증할 것
- APK에 라이선스와 대응 소스 고지를 포함할 것

현재 제품 경로는 Debian systemd/OpenSSH이며 이 디렉터리는 대안 검토 기록이다.

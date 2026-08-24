# DawnShell 개발 진행 상황

[English](progress.md) · [쉬운 용어집](glossary.ko.md)

이 문서는 현재 독립 DawnShell 앱의 구현 상태만 기록합니다. 오래된 시험 앱 이름,
패키지, 서명 값과 이전 APK 정보는 현재 제품 동작에 도움이 되지 않아 제거했습니다.

## 완료된 기능

### Android Direct Boot

- [x] 전용 패키지 `me.aroxu.dawnshell`과 전용 UID를 사용합니다.
- [x] `LOCKED_BOOT_COMPLETED` receiver와 Direct-Boot-aware 포그라운드 서비스를
  사용합니다.
- [x] DE(Device Encrypted) 저장소에 부팅 설정, 공개 키, 런타임과 로그를
  배치합니다.
- [x] BFU(Before First Unlock) root, CE 격리, rootfs, chroot 검사를 수행합니다.
- [x] `USER_UNLOCKED` 뒤에도 같은 Debian 인스턴스를 유지합니다.
- [x] 중복 부팅 알림과 오래된 PID 상태를 안전하게 처리합니다.

Android 요구 사항은 [Google Direct Boot 문서](https://developer.android.com/privacy-and-security/direct-boot)와
[AOSP 파일 기반 암호화 문서](https://source.android.com/docs/security/features/encryption/file-based)를
기준으로 구현했습니다.

### Debian 13

- [x] Debian 13 Trixie rootfs 설치 화면과 실시간 로그를 제공합니다.
- [x] Debian Release 서명과 패키지 SHA-256을 확인합니다.
- [x] 임시 설치 트리 검증 후 `/data/local/debian`에 원자적으로 게시합니다.
- [x] systemd, D-Bus, OpenSSH와 `debian` 사용자를 구성합니다.
- [x] SSH 비밀번호 인증과 직접 root 로그인을 끕니다.
- [x] 로컬 `root`와 `debian` 비밀번호 설정을 지원합니다.
- [x] `su root`를 통한 로컬 root 전환을 지원합니다.
- [x] 안전한 중지, 재시작, 상태 확인과 rootfs 삭제를 제공합니다.

### 내장 런타임

- [x] `armeabi-v7a`, `arm64-v8a`, `x86_64`를 지원합니다.
- [x] BusyBox, Debian `pkgdetails`, GnuPG `gpgv`, 관련 라이브러리와 Debian
  archive keyring을 고정된 소스에서 빌드합니다.
- [x] BusyBox `stat -c` 지원을 설치 전에 확인합니다.
- [x] 소스 URL, 버전과 SHA-256을 `SOURCES.lock`에 기록합니다.
- [x] 컴파일은 기본적으로 `make -j"$(nproc)"`를 사용합니다.

ABI(Application Binary Interface)의 의미는
[Google Android ABI 문서](https://developer.android.com/ndk/guides/abis)를 참고해 주세요.

### 커널과 네트워크

- [x] 전용 cgroup v2 하위 트리와 장치 BPF를 먼저 시험합니다.
- [x] 최신 경로가 실패하면 정리 후 격리된 cgroup v1 방식으로 전환합니다.
- [x] Android NIC를 직접 공유하고 Wi-Fi, 모바일, USB Ethernet 변경을 처리합니다.
- [x] 기본 비활성 직접/VID:PID 제한 독점 USB 패스스루, v2 BPF/v1 devices
  차단과 정상 종료 드라이버 복원을 제공합니다.
- [x] Tailscale 경로 표시를 Android가 선택한 routing table에 맞춥니다.
- [x] Docker 기본값을 안전한 host-network-only 방식으로 설정합니다.
- [x] bridge와 방화벽 backend 선택을 위험 옵션으로 제공합니다.
- [x] `reboot now`를 Android 전체 재부팅에 연결하고 `systemctl reboot`는 Debian
  격리 영역 안에 유지합니다.

### UI와 문서

- [x] Material 3 대시보드를 제공합니다.
- [x] 앱 이름을 제외한 번역 가능한 UI에 한국어를 제공합니다.
- [x] 로그를 별도 화면과 펼침 구조로 나누고 선택, 복사, 스크롤을 지원합니다.
- [x] SSH 키 생성, 파일 내보내기, 로컬 셸용 명령 복사를 제공합니다.
- [x] 한국어와 영어 설치 가이드, 사용자 매뉴얼, 기술 문서를 제공합니다.
- [x] 약어를 풀어 쓴 쉬운 용어집과 Google/AOSP 공식 링크를 제공합니다.
- [x] 과거 제품 명칭과 오래된 마이그레이션 안내를 제거했습니다.

### 하드웨어 영상 가속

- [x] 기본 비활성 MediaCodec 옵션과 별도 `:codec` 프로세스를 추가했습니다.
- [x] BFU 부팅 재시도와 `USER_UNLOCKED` 이후 유지 수명 주기를 연결했습니다.
- [x] API 29 이상 플랫폼 판정과 API 24~28 보수적 하위 호환 판정을 구현했습니다.
- [x] secure/DRM 및 software fallback을 제외하고 AVC/HEVC 인스턴스 생성을
  DE JSON/로그로 기록합니다.
- [x] root peer 인증 binary protocol과 3개 지원 ABI용 정적 Debian client를
  구현했습니다.
- [x] 고정 AVC decode/I420 checksum 및 hardware encode/FFmpeg 자체 검사를
  구현했습니다.
- [x] bounded packet framing과 timestamp를 유지하는 FFmpeg hardware decode/encode
  demux/mux wrapper를 구현했습니다.
- [x] bounded socket 폴백이 있는 `memfd`/`SCM_RIGHTS` media 전송을 구현했습니다.
- [x] 전체 YUV frame을 Debian으로 반환하지 않는 H.264/HEVC→H.264 Surface
  transcode를 구현했습니다.
- [x] keyframe 요청, broker/session 통계와 잘못된 요청 격리 회귀 검사를
  구현했습니다.
- [x] 720p shared-memory/socket 비교, 1080p30 실시간 Surface transcode와
  비정상 peer 자원 정리 성능 검사 경로를 구현했습니다.
- [x] Android 16 AFU에서 Exynos AVC/HEVC encoder·decoder instance 생성을
  확인했습니다.
- [ ] BFU 실기기에서 Exynos AVC hardware instance 생성을 확인합니다.
- [ ] 최초 잠금 해제 전후에 고정 vector decode, encode, shared-memory 전송과
  Surface transcode를 검증합니다.
- [ ] 대상 기기에서 1080p 실시간 성능, timestamp 안정성과 자원 정리를
  검증합니다.

### 라이선스와 자동 빌드

- [x] DawnShell 코드를 MIT 라이선스로 제공합니다.
- [x] 내장 프로그램의 GPL/LGPL 등 원래 라이선스와 대응 소스를 보존합니다.
- [x] 앱에서 오픈소스 라이선스 전문과 소스 위치를 확인할 수 있습니다.
- [x] GitHub Actions에서 세 ABI와 Android 앱을 빌드하고 검사합니다.
- [x] 태그에서 서명 APK, 대응 소스, 라이선스, 빌드 정보와 SHA-256을 Release로
  게시하는 흐름을 제공합니다.

## 실기기에서 확인한 항목

- [x] Android 16 / ARM64 실기기에서 `LOCKED_BOOT_COMPLETED`를 받았습니다.
- [x] BFU에서 DE 파일과 네이티브 실행 파일을 사용했습니다.
- [x] BFU에서 Debian systemd와 SSH를 시작했습니다.
- [x] 첫 잠금 해제 뒤 같은 Debian과 SSH가 유지되었습니다.
- [x] cgroup v1 위임으로 Docker의 cgroup 초기화를 통과했습니다.
- [x] 호스트 네트워크 공유와 Tailscale 경로를 확인했습니다.

## 남은 검증

- [ ] ARMv7 실기기에서 전체 설치와 BFU 부팅을 확인합니다.
- [ ] x86_64 실기기 또는 에뮬레이터에서 전체 흐름을 확인합니다.
- [ ] 여러 제조사 ROM에서 5회 cold boot 회귀 시험을 수행합니다.
- [ ] Docker bridge backend를 다양한 커널과 방화벽 구현에서 추가 확인합니다.
- [ ] 실기기에서 직접/독점 USB hot-plug, 드라이버 복원, 시리얼, libusb와
  저장장치를 확인합니다.
- [ ] 장기 실행 시 메모리, 마운트와 cgroup 누적 여부를 관찰합니다.
- [ ] `BFU_REQUIRE_HARDWARE_CODEC=1`로 BFU hardware codec 5회 회귀 시험을
  수행합니다.

## 현재 통과 기준

```text
재부팅
  → PIN 입력 전 SSH 접속
  → systemd PID 1과 SSH 확인
  → 첫 잠금 해제
  → 기존 연결과 PID 1 유지
  → 중복 supervisor 없음
```

전체 절차는 [테스트 방법](testing.ko.md)을 참고해 주세요.

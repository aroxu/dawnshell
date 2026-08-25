# DawnShell 하드웨어 영상 코덱 구현 결정 기록

이 문서는 초기 설계안이 아니라 현재 구현의 결정 기록입니다. 실제 wire format은
[하드웨어 코덱 worker protocol](hardware-codec-protocol.ko.md), 사용법은
[FFmpeg 하드웨어 코덱 안내](ffmpeg-hardware-codec.ko.md)를 기준으로 합니다.

## 목표와 비목표

DawnShell은 Debian에 OpenGL/Vulkan GPU를 패스스루하지 않습니다. Debian의 FFmpeg가
demux, packet framing, software preprocessing과 mux를 담당하고, Android NDK
`AMediaCodec` worker가 AVC/HEVC decode·encode를 담당합니다.

비목표는 다음과 같습니다.

- 일반 GPU compute 또는 VirGL 제공
- Debian glibc 프로세스에 Android bionic library 직접 로드
- 공개 TCP/Unix listener 또는 Binder service 등록
- 상주 codec daemon
- 실패 시 소프트웨어 코덱으로 조용히 전환

## 최종 구조

```text
Debian FFmpeg wrapper
  → 정적 dawnshell-codec client
  → memfd 1개 + eventfd 2개 생성
  → fork/exec dawnshell-codec-worker
  → 상속 FD ready handshake
  → bionic NDK AMediaCodec
  → bounded response record
  → worker 회수
```

worker는 `/usr/local/libexec/dawnshell-codec-worker`에 설치됩니다. client와 worker는
fixed FD 3/4/5만 공유합니다. `sendmsg`/`recvmsg`, `SCM_RIGHTS`, 파일시스템 socket,
abstract socket은 사용하지 않습니다. 요청과 응답 payload는 각각 8 MiB로 제한되며,
control header의 protocol version, sequence, 길이와 상태를 양쪽에서 확인합니다.

worker는 부모 종료 시 함께 종료되도록 parent-death signal을 사용하고, client는
정상·오류·signal 종료 경로에서 worker를 회수합니다. 명령마다 worker PID가 바뀌는
것이 정상입니다.

## Android runtime view

worker는 bionic 동적 실행 파일이므로 Debian의 private mount namespace 안에서 다음
Android 경로를 읽기 전용으로 봅니다.

- `/system`
- `/apex`
- `/linkerconfig` (존재하는 플랫폼에서만)

일반 앱 CE data를 mount하지 않습니다. BFU runtime과 Debian rootfs는 DE 또는
root가 관리하는 경로만 사용합니다. 위 Android runtime mount는 Debian 종료 시
private namespace와 함께 사라집니다.

## 코덱 경로

- decode: NDK decoder → `AImageReader` YUV_420_888 → I420 정규화
- encode: I420 byte buffer → NDK encoder → Annex-B AVC/HEVC
- transcode: decoder output Surface → encoder input Surface

Surface transcode는 전체 YUV frame을 Debian으로 왕복시키지 않습니다. decode/encode
개별 명령은 bounded shared slot을 사용합니다. Exynos 및 Qualcomm의 보수적인
component 이름을 우선하며, 플랫폼이 제공하는 하드웨어 metadata를 함께 사용합니다.
`OMX.google.*`, `c2.android.*`와 secure component는 하드웨어 성공으로 인정하지
않습니다.

## BFU와 AFU

BFU와 AFU 모두 동일한 on-demand worker 구조입니다. 시작 시 상주 broker를 띄우지
않습니다. `USER_UNLOCKED`는 Debian/systemd를 종료하지 않으며 코덱 daemon을 넘겨줄
필요도 없습니다. 검증은 다음과 같이 수행합니다.

1. BFU SSH에서 `dawnshell-codec health`와 self-test 실행
2. unlock
3. 같은 Debian PID 1과 SSH가 유지되는지 확인
4. AFU에서 새 private worker로 health와 self-test 재실행

BFU에서 Android media service가 준비되지 않은 플랫폼은 코덱 기능만 실패해야 하며,
Debian PID 1, SSH와 Direct Boot handoff는 계속 동작해야 합니다.

## 보안 경계

- listener가 없으므로 외부 peer가 worker에 접속할 endpoint가 없습니다.
- 상속 FD를 가진 직계 자식만 transport에 접근합니다.
- payload, session 수, 해상도, frame rate, bitrate와 timeout에 상한이 있습니다.
- 소프트웨어 codec fallback은 없습니다.
- worker에는 일반 Termux CE data나 credential을 제공하지 않습니다.
- 관리되는 native/chroot 실행 경로는 root 전용입니다.

## 정적 완료 기준

- armv7, arm64-v8a, x86_64 client/worker 빌드
- client는 static Android ELF, worker는 제한된 bionic 의존성만 보유
- APK에 ABI별 client와 worker 포함
- source 및 패키지에 Java socket broker/JNI가 없음
- shell syntax/lint, JVM unit test, APK assemble 성공
- 문서와 UI가 private worker 모델을 설명

## 실기기 완료 기준

이 항목은 호스트 정적 검증과 별개이며 실제 Android 기기가 필요합니다.

- BFU에서 `worker_state=ready`, 하드웨어 codec 이름과 decode/encode 결과 확인
- 1080p H.264/HEVC 파일과 Surface transcode 검증
- AFU 재검증 및 Debian PID 1 연속성 확인
- 잘못된 입력, 동시 worker, client 강제 종료 후 자원 정리 확인
- 5회 cold-boot 반복과 장기 thermal/CPU/RSS 기록

실기기에서 성공하기 전에는 하드웨어 코덱 기능을 최종 검증 완료로 표시하지 않습니다.

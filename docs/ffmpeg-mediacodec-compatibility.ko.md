# 순정 FFmpeg 문법 호환성 (MediaCodec)

[English](ffmpeg-mediacodec-compatibility.md)

[프로젝트 홈](../README.ko.md) · [FFmpeg 하드웨어 코덱](ffmpeg-hardware-codec.ko.md) ·
[사용자 매뉴얼](user-guide.ko.md) · [테스트 안내](testing.ko.md)

## 이 문서가 답하는 질문

"왜 Debian 안의 순정 `ffmpeg`로 `-hwaccel mediacodec`을 바로 쓸 수 없는가,
그리고 DawnShell은 그 문법을 어떻게 지원하는가"입니다.

## 1. 왜 순정 Debian FFmpeg로는 불가능한가

FFmpeg 자체는 MediaCodec을 지원합니다. 하지만 그 지원은 **Android 플랫폼용으로
빌드된 FFmpeg**에만 존재합니다. 필요한 조건은 다음과 같습니다.

| 조건 | 내용 | Debian rootfs의 상태 |
| --- | --- | --- |
| 빌드 타깃 | `--target-os=android` | Debian 패키지는 `linux` 타깃 |
| C 라이브러리 | bionic | glibc |
| 빌드 플래그 | `--enable-mediacodec --enable-jni` | 미적용 |
| 링크 대상 | 시스템의 `libmediandk.so` | chroot 안에서 미노출 |
| 런타임 | Android 미디어 서비스 접근 | SELinux 도메인이 다름 |
| JVM | JNI 초기화 경로 | chroot 안에 JVM 없음 |

즉 문제는 "옵션을 켜지 않았다"가 아니라 **ABI와 프로세스 컨텍스트가 다르다**는
점입니다. Debian FFmpeg는 glibc 프로세스이고, MediaCodec은 bionic + Android
미디어 서비스 컨텍스트에서만 열립니다.

확인 방법은 다음과 같습니다.

```sh
/usr/bin/ffmpeg -hide_banner -hwaccels
/usr/bin/ffmpeg -hide_banner -encoders | grep -i mediacodec || true
```

두 명령 모두 `mediacodec` 항목을 보여주지 않는 것이 정상입니다.

### Android용 FFmpeg를 직접 넣으면 되지 않는가

이론적으로는 가능하지만 다음이 전부 필요합니다.

- bionic 기반 Android FFmpeg 크로스 빌드
- chroot 안으로 `/system/lib64`와 linker 노출
- MediaCodec에 필요한 SELinux 접근 허용
- JVM 없이 NDK MediaCodec을 초기화(상위 Android 버전에서 특히 불안정)

마지막 두 항목은 DawnShell의 격리 설계와 정면으로 충돌합니다. Debian이 Android
미디어 스택에 직접 붙는 순간, chroot는 더 이상 경계 역할을 하지 못합니다.
그래서 DawnShell은 이 방식을 채택하지 않습니다.

## 2. DawnShell의 방식: 문법은 순정, 실행은 브리지

DawnShell은 명령줄 **문법**을 순정 FFmpeg와 동일하게 받아들이고, 실제 코덱
호출만 Android 앱 프로세스로 넘깁니다.

```text
사용자 명령 (-hwaccel mediacodec / -c:v h264_mediacodec)
        ↓
dawnshell-ffmpeg            명령 해석
        ↓
plan-ffmpeg                 실행 계획 결정
        ↓
dawnshell-hwdecode / hwencode / hwtranscode
        ↓
dawnshell-codec             Unix socket 클라이언트
        ↓
Android 앱 프로세스의 MediaCodec
```

정확히 이해해야 할 두 가지가 있습니다.

- 명령 문법과 결과물은 순정 FFmpeg와 호환됩니다.
- 하지만 `/usr/bin/ffmpeg`가 MediaCodec을 여는 것은 아닙니다. 코덱을 여는
  주체는 Android 앱입니다.

### 래퍼 연결은 기본으로 적용됩니다

Debian 구성 시 `/usr/local/bin/ffmpeg`가 래퍼를 가리키도록 자동 등록됩니다.
기본 PATH에서 `/usr/local/bin`이 `/usr/bin`보다 앞이므로, `ffmpeg`를 이름으로
실행하는 기존 프로그램이 별도 설정 없이 하드웨어 경로를 사용합니다. Debian이
패키지로 설치한 `/usr/bin/ffmpeg` 파일 자체는 변경하지 않습니다.

```sh
command -v ffmpeg
readlink -f /usr/local/bin/ffmpeg
dawnshell-ffmpeg-integration status
```

원래 동작으로 되돌리거나 다시 켜려면 다음을 사용합니다.

```sh
sudo dawnshell-ffmpeg-integration disable
hash -r

sudo dawnshell-ffmpeg-integration enable
hash -r
```

`disable`는 DawnShell이 만든 symlink만 제거하며, 다른 파일이 놓여 있으면
건드리지 않고 종료합니다. 절대 경로로 `/usr/bin/ffmpeg`를 실행하는 프로그램은
연결 상태와 무관하게 항상 순정 FFmpeg를 사용합니다.

## 3. 지원하는 순정 문법

| 순정 FFmpeg 문법 | DawnShell 동작 | 실행 경로 |
| --- | --- | --- |
| `-hwaccel mediacodec` + raw 출력 | 하드웨어 디코드 | `dawnshell-hwdecode` |
| `-c:v h264_mediacodec` | 하드웨어 AVC 인코드 | `dawnshell-hwencode` |
| `-c:v hevc_mediacodec` | 하드웨어 HEVC 인코드 | `dawnshell-hwencode` |
| `-hwaccel mediacodec` + `-c:v h264_mediacodec` | Surface zero-copy 트랜스코드 | `dawnshell-hwtranscode` |
| `-hwaccel mediacodec` + `-c:v libx264` | Surface zero-copy 트랜스코드 | `dawnshell-hwtranscode` |
| `-c:v h264_mediacodec` (입력 앞) | 하드웨어 **디코더** 지정 | 출력 코덱에 따름 |
| `-hwaccel auto`, `-hwaccel none` | 무시(정상 처리) | 출력 코덱에 따름 |

FFmpeg의 옵션 위치 규칙을 그대로 따릅니다. 즉 `-i` **앞**의 `-c:v`는 디코더,
**뒤**의 `-c:v`는 인코더입니다.

### 예시

하드웨어 AVC 인코드입니다.

```sh
sudo ffmpeg -hide_banner -y -i input.mp4 -map 0:v:0 -an \
  -c:v h264_mediacodec -b:v 4M output.mp4
```

Surface zero-copy 트랜스코드입니다.

```sh
sudo ffmpeg -hide_banner -y -hwaccel mediacodec -i input.mp4 \
  -map 0:v:0 -an -c:v h264_mediacodec -b:v 6M output.mp4
```

하드웨어 디코드만 수행합니다.

```sh
sudo ffmpeg -hide_banner -y -hwaccel mediacodec -i input.mp4 output.yuv
```

## 4. 매우 중요한 안전 규칙

명령에 `mediacodec`을 **직접 적었다면**, DawnShell은 이를 요구사항으로
간주합니다. 하드웨어 경로를 만들 수 없으면 조용히 `libx264`로 떨어지지 않고
오류로 종료합니다.

```sh
sudo ffmpeg -i input.mp4 -vf scale=1280:720 -c:v h264_mediacodec out.mp4
# dawnshell-ffmpeg: hardware bridge required but unavailable: ...
# exit 3
```

이 설계 이유는 성능 측정과 배터리 소모 판단이 왜곡되는 것을 막기 위함입니다.
"하드웨어를 쓰라고 명시했는데 실제로는 CPU가 갈리는" 상황이 가장 위험합니다.

소프트웨어 폴백을 원한다면 명시적으로 요청하십시오.

```sh
DAWNSHELL_FFMPEG_BRIDGE=off sudo -E ffmpeg -i input.mp4 \
  -vf scale=1280:720 -c:v libx264 out.mp4
```

## 5. 모드

| 값 | 동작 | `mediacodec` 명시 시 |
| --- | --- | --- |
| `auto`(기본) | 지원되면 하드웨어, 아니면 소프트웨어 | require와 동일하게 강제 |
| `require` | 하드웨어 불가 시 오류 | 동일 |
| `off` | 항상 `/usr/bin/ffmpeg` | 소프트웨어 사용(명시적 우선) |

`off`는 사용자가 직접 끈 것이므로 `mediacodec` 표기보다 우선합니다.

## 6. 자동 하드웨어 경로의 범위

지원합니다.

- 입력 파일 1개, 출력 파일 1개
- 첫 번째 영상 stream
- H.264 또는 HEVC 입력
- AVC 또는 HEVC 출력, 혹은 `.i420`/`.yuv` raw 출력
- 짝수 해상도 16~4096
- 1~240 fps
- bitrate 1000~100000000 bit/s
- `-hide_banner`, `-y`, `-n`, `-an`, `-nostdin`, `-loglevel`, `-v`,
  `-threads`, `-stats_period`, `-pix_fmt`, `-f`, `-r`, 제한된 `-map`,
  `-hwaccel_output_format`, `-hwaccel_device`, `-hwaccel_flags`

지원하지 않습니다(소프트웨어 폴백 또는 오류).

- `-vf`, `-filter` 등 필터·크기 변환
- `-crf`, `-preset` 같은 x264/x265 전용 옵션
- 복수 입력 또는 복수 출력
- `-c:v copy`
- VP9, AV1 등 미지원 코덱
- 오디오 인코드·필터·mapping
- `-hwaccel cuda` 등 다른 가속기

하드웨어 경로는 영상 전용입니다. 오디오를 유지하려면 이후에 다시 mux합니다.

```sh
sudo ffmpeg -y -i input.mp4 -map 0:v:0 -an \
  -c:v h264_mediacodec -b:v 4M video-only.mp4

/usr/bin/ffmpeg -y -i video-only.mp4 -i input.mp4 \
  -map 0:v:0 -map 1:a? -c:v copy -c:a copy final.mp4
```

## 7. 순정 FFmpeg와 다른 점

정확한 기대치를 위해 차이를 명확히 기록합니다.

| 항목 | 순정 Android FFmpeg | DawnShell |
| --- | --- | --- |
| 코덱 호출 주체 | FFmpeg 프로세스 | Android 앱 프로세스 |
| 권한 | 앱 권한 | UID 0 필요(브로커 정책) |
| 오디오 동시 처리 | 가능 | 미지원(별도 mux) |
| 필터와 하드웨어 조합 | 일부 가능 | 미지원 |
| `-hwaccel_output_format` | 실제 의미 있음 | 무시 |
| 실패 시 동작 | 설정에 따름 | 명시 시 오류 종료 |
| 지연 | 프로세스 내부 | socket/공유 메모리 경유 |

`sudo`가 필요한 이유는 브로커가 UID 0 연결만 수락하기 때문입니다. 이는 Debian
안의 임의 프로세스가 Android 코덱을 열지 못하게 하는 보안 경계입니다.

## 8. 실행 전 확인과 문제 해결

미디어를 건드리지 않고 선택 경로만 확인합니다.

```sh
/usr/local/libexec/dawnshell-codec-ffmpeg.py plan-ffmpeg \
  -hwaccel mediacodec -i input.mp4 -map 0:v:0 -an \
  -c:v h264_mediacodec -b:v 6M output.mp4
```

출력 예시입니다.

```text
action=transcode input=input.mp4 output=output.mp4 codec=avc bitrate=6000000 explicit=mediacodec
```

필드 의미는 다음과 같습니다.

| 필드 | 의미 |
| --- | --- |
| `action=decode` | 하드웨어 디코드만 |
| `action=encode` | 하드웨어 인코드만 |
| `action=transcode` | Surface zero-copy 디코드+인코드 |
| `action=passthrough` | 자동 하드웨어 범위 밖 |
| `explicit=mediacodec` | 사용자가 하드웨어를 명시함 |
| `reason=...` | 폴백 사유 |

브로커 상태와 로그를 확인합니다.

```sh
sudo dawnshell-codec health --format json
systemctl status dawnshell-codec-long-run.service --no-pager
journalctl -u dawnshell-codec-long-run.service -n 100 --no-pager
```

| 증상 | 원인과 조치 |
| --- | --- |
| `hardware bridge required but unavailable` | 명령이 자동 범위 밖입니다. `plan-ffmpeg`의 `reason`을 확인하십시오. |
| `Surface transcode only produces H.264` | HEVC 출력에는 `-hwaccel mediacodec`을 제거하십시오. |
| `broker_state`가 `listening`이 아님 | 앱에서 브리지를 켜고 저장한 뒤 Debian 구성을 다시 실행하십시오. |
| `connect @dawnshell.codec.v1 failed` | `sudo`로 실행했는지 확인하십시오. |
| 파일 검사는 통과하지만 명령이 실패 | 코덱이 아니라 socket/공유 메모리 계층을 확인하십시오. |

앱에서는 **하드웨어 영상 가속 → 하드웨어 코덱 보고서 보기**를 확인합니다.

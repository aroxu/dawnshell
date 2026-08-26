# gsmi - 가속기 상태 모니터

[English](gpu-status-tool.md)

[프로젝트 홈](../README.ko.md) · [FFmpeg 하드웨어 코덱](ffmpeg-hardware-codec.ko.md) ·
[사용자 매뉴얼](user-guide.ko.md)

## 요약

`gsmi`는 모든 하드웨어 가속을 GPU 작업으로 표시하지 않고 다음 두 장치를
구분합니다.

- 커널 sysfs에서 읽는 Mali 또는 Adreno **3D GPU**
- 커널이 제공하는 영상 엔진 sysfs와 `/proc`의 DawnShell codec client로 확인하는
  전용 **MediaCodec 영상 가속기**

Debian 구성 시 자동 설치됩니다.

```sh
gsmi
gsmi --loop 1
```

하드웨어 영상 인코딩 중의 출력 예시입니다.

```text
2026-08-26T10:00:00Z   DawnShell accelerator status (gsmi)
+-----------------------------------------------------------------------+
| 3D GPU                 | Mali-G71 20 cores                            |
| 3D utilization         | 0%                                           |
| 3D clock               | idle                                         |
+-----------------------------------------------------------------------+
| Video accelerator      | Android MediaCodec video accelerator         |
| Codec activity         | active                                       |
| Codec clients          | 1                                            |
| Codec workloads        | encode=1 decode=0 transcode=0                |
| Codec utilization      | unavailable                                  |
+-----------------------------------------------------------------------+
Sources: kernel sysfs and DawnShell client processes in /proc.
MediaCodec uses a dedicated video engine, not the 3D GPU.
Codec utilization: unavailable because this kernel exports no VPU busy counter.
```

H.264/HEVC 처리 중에도 3D GPU가 0%와 `suspended`인 것은 정상일 수 있습니다.
Android MediaCodec은 보통 VPU, MFC, Venus 등으로 불리는 전용 영상 블록에서 해당
작업을 실행합니다.

## 각 값이 증명하는 것

| 필드 | 데이터 출처 | 의미 |
| --- | --- | --- |
| `3D utilization` | Mali/Adreno sysfs | Android 전체의 그래픽·연산 GPU 부하 |
| `Codec activity` | DawnShell client와 optional 영상 sysfs | DawnShell encode/decode/transcode 실행 여부 |
| `Codec clients` | `/proc/*/cmdline` | private codec client 수. worker를 중복 집계하지 않음 |
| `Codec workloads` | client 명령 | encode/decode/transcode 작업별 개수 |
| `Codec utilization` | 영상 엔진 sysfs | 커널이 제공할 때만 표시하는 실제 VPU 사용률 |

`active` 상태를 임의의 퍼센트로 바꾸지 않습니다. 커널이 VPU 사용률 counter를
숨기면 DawnShell MediaCodec 작업이 실행 중임을 확인해도 사용률은
`unavailable`로 표시합니다.

## 중요한 한계

| 항목 | `nvidia-smi` | `gsmi` |
| --- | --- | --- |
| 데이터 출처 | 벤더 드라이버 API | 커널 sysfs와 DawnShell `/proc` client |
| 프로세스별 GPU 사용량 | 지원 | 대부분 미지원 |
| DawnShell codec 작업 | 벤더별 지원 | encode/decode/transcode client 개수 |
| VPU 사용률 | 벤더별 지원 | 커널이 counter를 공개할 때만 지원 |
| VRAM | 전용 메모리 할당 | 대개 통합 메모리이며 미노출 |
| 전력·팬 | 자주 제공 | 대부분 미노출·해당 없음 |

3D 사용률은 화면 렌더링을 포함한 Android 기기 전체 값입니다. Codec client 개수는
DawnShell 작업만 나타냅니다. 다른 Android 앱의 MediaCodec session은 Debian의
process namespace에서 열거할 수 없습니다.

## 옵션

| 옵션 | 설명 |
| --- | --- |
| `-l`, `--loop SECONDS` | 1~3600초 간격으로 갱신 |
| `-n`, `--count N` | N회 뒤 종료. `--loop` 필요 |
| `--format table` | 기본 표 형식 |
| `--format csv` | 로그 수집용 CSV |
| `--format json` | 프로그램 연동용 JSON |

```sh
gsmi --loop 2
gsmi --loop 1 --count 10 --format csv > accelerator-log.csv
gsmi --format json
```

기존 GPU JSON 필드는 유지됩니다. 코덱 관련 필드는 `codec_activity`,
`codec_clients`, `codec_encode_clients`, `codec_decode_clients`,
`codec_transcode_clients`, `codec_utilization_percent`, `codec_sysfs_path`입니다.

## 읽는 커널 인터페이스

| 종류 | 경로 또는 이름 예시 |
| --- | --- |
| Qualcomm Adreno | `/sys/class/kgsl/kgsl-3d0` |
| ARM Mali | `/sys/class/misc/mali0/device`, `/sys/class/devfreq/*.mali` |
| 전용 영상 엔진 | 이름에 `mfc`, `venus`, `vpu`, `vcodec`, `venc`, `vdec`가 포함된 devfreq |
| 온도 | `/sys/class/thermal/thermal_zone*` |
| DawnShell codec client | `/proc/[pid]/cmdline` |

커널마다 속성 이름이 다릅니다. `gpu_busy_percentage`, `utilisation`,
`utilization`, `busy_percentage`, `busy_percent` 및 퍼센트 형식의 `load`를
인식합니다. 형식을 확인할 수 없는 값을 사용률로 추정하지 않습니다.

## 문제 해결

| 증상 | 원인과 조치 |
| --- | --- |
| MediaCodec 사용 중 3D GPU가 0% | 정상입니다. 전용 코덱 엔진을 사용하므로 `Codec activity`를 확인합니다. |
| DawnShell 작업 중 `Codec activity`가 `idle` | FFmpeg가 실행되는 동안 다른 셸에서 `gsmi --loop 1`을 실행하고 `/proc` mount를 확인합니다. |
| `Codec utilization`이 `unavailable` | 커널이 VPU busy counter를 공개하지 않습니다. activity와 client 개수는 계속 유효합니다. |
| 3D 필드가 `unavailable` | 지원하는 GPU sysfs가 없거나 `/sys`가 공유되지 않았습니다. |

```sh
gsmi --loop 1
gsmi --format json
ls -l /sys/class/devfreq/ 2>/dev/null
ls -l /sys/class/kgsl/ 2>/dev/null
```

지원하는 MediaCodec 명령은 [FFmpeg 하드웨어 코덱 사용법](ffmpeg-hardware-codec.ko.md)을
참고하세요.

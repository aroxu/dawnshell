# gsmi - GPU 상태 모니터

[English](gpu-status-tool.md)

[프로젝트 홈](../README.ko.md) · [FFmpeg 하드웨어 코덱](ffmpeg-hardware-codec.ko.md) ·
[사용자 매뉴얼](user-guide.ko.md)

## 요약

`gsmi`는 `nvidia-smi`와 비슷한 형태로 GPU 사용률, 클럭, governor, 온도를
보여줍니다. Debian 구성 시 자동 설치됩니다.

```sh
gsmi
```

예시 출력입니다.

```text
2026-08-25T12:04:22Z   DawnShell GPU status (gsmi)
+-----------------------------------------------------------------------+
| GPU                    | Adreno540                                    |
| Utilization            | 37%                                          |
| Clock                  | 710MHz                                       |
| Max clock              | 710MHz                                       |
| Governor               | msm-adreno-tz                                |
| Power state            | active                                       |
| Temperature            | 41.2C                                        |
+-----------------------------------------------------------------------+
```

## 중요한 한계

`nvidia-smi`와 결정적으로 다른 점이 있습니다.

| 항목 | nvidia-smi | gsmi |
| --- | --- | --- |
| 데이터 출처 | 벤더 드라이버 API | 커널 sysfs |
| 프로세스별 사용량 | 지원 | 미지원 |
| VRAM 사용량 | 지원 | 미지원(통합 메모리) |
| 전력(W) | 지원 | 대부분 미노출 |
| 팬 속도 | 지원 | 해당 없음 |
| 표시 대상 | 컨테이너 작업 부하 | 기기 전체 GPU |

특히 **프로세스 단위 GPU 사용량은 표시할 수 없습니다**. Android SoC 커널은
프로세스별 GPU 회계 정보를 sysfs로 공개하지 않습니다.

또한 표시되는 사용률은 Debian 컨테이너만의 값이 아니라 **Android 화면 렌더링을
포함한 기기 전체 GPU 사용률**입니다. Debian은 OpenGL/Vulkan 렌더링을 직접
수행하지 않으므로, 이 수치는 주로 Android UI와 하드웨어 코덱 작업을 반영합니다.

커널이 값을 공개하지 않으면 추정하지 않고 `unavailable` 또는 `null`로
표시합니다.

## 옵션

| 옵션 | 설명 |
| --- | --- |
| `-l`, `--loop SECONDS` | 지정한 주기로 갱신(1~3600초) |
| `-n`, `--count N` | N회 샘플 후 종료(`--loop` 필요) |
| `--format table` | 기본 표 형식 |
| `--format csv` | 로그 수집용 CSV |
| `--format json` | 스크립트 연동용 JSON |

주기 갱신 예시입니다.

```sh
gsmi --loop 2
gsmi --loop 1 --count 10 --format csv > gpu-log.csv
```

JSON 예시입니다.

```sh
gsmi --format json
```

```text
{"timestamp":"2026-08-25T12:04:22Z","name":"Adreno540","utilization_percent":37,
"clock_mhz":710,"max_clock_mhz":710,"governor":"msm-adreno-tz",
"power_state":"active","temperature_c":41.2,
"sysfs_path":"/sys/class/kgsl/kgsl-3d0"}
```

## 읽는 커널 인터페이스

벤더를 가정하지 않고 다음 경로를 순서대로 탐색합니다.

| 종류 | 경로 예시 |
| --- | --- |
| Qualcomm Adreno | `/sys/class/kgsl/kgsl-3d0` |
| ARM Mali | `/sys/class/misc/mali0/device`, `/sys/class/devfreq/*.mali` |
| 일반 devfreq | `/sys/class/devfreq/*gpu*` |
| 온도 | `/sys/class/thermal/thermal_zone*` |

사용률은 Qualcomm의 `gpu_busy_percentage`와 Mali의 `utilisation`을 모두
인식합니다. 클럭은 `cur_freq`, `max_freq`를 MHz로 변환해 표시합니다.

## 문제 해결

| 증상 | 원인과 조치 |
| --- | --- |
| `no GPU sysfs node was found` | 커널이 GPU 노드를 공개하지 않거나 `/sys`가 공유되지 않았습니다. |
| `Utilization`이 `unavailable` | 커널이 사용률 속성을 제공하지 않습니다. 클럭과 온도만 사용하세요. |
| `Temperature`가 `unavailable` | GPU 이름이 포함된 thermal zone이 없습니다. |

직접 확인하려면 다음을 실행합니다.

```sh
gsmi --format json
ls -l /sys/class/devfreq/ 2>/dev/null
ls -l /sys/class/kgsl/ 2>/dev/null
grep -H . /sys/class/thermal/thermal_zone*/type 2>/dev/null
```

GPU 사용률을 낮추는 것이 목적이라면 영상 인코딩·디코딩을 하드웨어 코덱으로
넘기는 것이 효과적입니다.
[FFmpeg 하드웨어 코덱 사용법](ffmpeg-hardware-codec.ko.md)을 참고하세요.

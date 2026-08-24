# DawnShell 하드웨어 코덱 로컬 프로토콜 v1

`dawnshell-codec`은 Debian chroot에서 Android의 별도 `:codec` 프로세스에
접속하는 정적 실행 파일입니다. 연결은 외부 TCP가 아닌 Android abstract Unix
socket `@dawnshell.codec.v1`을 사용합니다. 브로커는 `SO_PEERCRED`의 UID가 0인
Debian 프로세스만 허용합니다. 앱 내부 진단을 위해 동일 앱 UID도 허용하지만 다른
앱 UID는 요청 본문을 읽기 전에 연결을 끊습니다.

abstract socket에는 파일 권한 비트가 없으므로 `0600`인 것처럼 표현하지 않습니다.
대신 UID 검사를 접근 제어로 사용하며, DE의
`files/hardware-codec/broker.status`는 앱 소유자만 읽을 수 있게 저장합니다.

## 고정 헤더

모든 정수는 network byte order(big-endian)입니다. 요청과 응답 헤더는 32바이트입니다.

| 오프셋 | 크기 | 값 |
| --- | ---: | --- |
| 0 | 4 | magic `DSCB` (`0x44534342`) |
| 4 | 2 | protocol version `1` |
| 6 | 2 | message type; 응답은 `type | 0x8000` |
| 8 | 4 | flags; v1에서는 0 |
| 12 | 8 | session ID; create 요청은 0 |
| 20 | 4 | payload length |
| 24 | 4 | 0이 아닌 request ID |
| 28 | 4 | 요청은 0, 응답은 signed status |

잘못된 magic/version/flags/request ID, 알 수 없는 type, 길이 불일치와 상한 초과는
fail-closed합니다. control payload는 1 MiB, media payload는 8 MiB, 전체 session은
4개, peer당 session은 2개로 제한합니다. peer 연결은 30초 idle timeout을 둡니다.

## 메시지

- `HELLO(1)`: protocol과 제한을 JSON으로 반환합니다.
- `CAPABILITIES(2)`: BFU에서 probe한 하드웨어 codec JSON을 반환합니다.
- `CREATE(3)`: decode/encode, AVC/HEVC, 크기, FPS, bitrate, color format으로 실제
  하드웨어 `MediaCodec`을 configure/start하고 session ID를 반환합니다.
- `INPUT(4)`: PTS, flags와 한 packet/frame을 queue합니다.
- `OUTPUT(5)`: bounded timeout으로 output을 dequeue합니다. format change와
  backpressure는 별도 status로 반환합니다.
- `FLUSH(6)`, `EOS(7)`, `CLOSE(8)`: session 상태를 제어합니다.

vendor codec 오류와 잘못된 client 입력은 해당 요청 또는 session에서만 실패하며
Debian PID 1, SSH, Direct Boot supervisor는 종료하지 않습니다. 연결이 끊기면 해당
peer가 만든 모든 session을 자동 release합니다.

## Debian CLI

```sh
dawnshell-codec capabilities
dawnshell-codec probe decode avc 128 128
dawnshell-codec pipe decode avc 1280 720 30 4000000 < packets.bin > frames.bin
```

`pipe`의 stdin/stdout record는 `pts_us:u64`, `flags:u32`, `length:u32`, `data` 순서의
big-endian framing입니다. 이 framing은 M3 고정 test vector와 이후 FFmpeg adapter가
공유합니다. 현재 경로는 bounded socket copy이며 shared-memory/`SCM_RIGHTS` 경로는
후속 성능 단계에서 추가합니다.

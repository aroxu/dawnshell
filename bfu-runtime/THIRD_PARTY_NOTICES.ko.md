# 내장 서드파티 소프트웨어 안내

[English](THIRD_PARTY_NOTICES.md) · [문서 홈](../docs/README.ko.md) · [빌드와 배포](../docs/building.ko.md)

DawnShell 앱 코드는 MIT 라이선스로 배포합니다. APK(Android Package)에는 별도
프로그램과 공개 Debian 키도 포함되며, 각 구성 요소의 원래 라이선스를 그대로
유지합니다.

| 구성 요소 | 라이선스 |
| --- | --- |
| BusyBox 1.38.0 | GPL-2.0-only |
| Debian base-installer 1.226 `pkgdetails` | GPL-2.0-only |
| GnuPG 2.4.9 `gpgv` | GPL-3.0-or-later |
| libgpg-error, libgcrypt, libassuan, libksba, npth | 각 원저작자의 LGPL/GPL 조건 |
| debootstrap 1.0.141 | Expat/MIT 계열 |
| Debian archive keyring 2025.1 | 공개 키 데이터, 패키징 GPL-2.0-or-later |
| AndroidX, Material Components, Kotlin 및 관련 Android 라이브러리 | Apache-2.0 등 각 원래 조건 |
| EdDSA-Java 0.3.0 | CC0-1.0 |

라이선스 전문과 필요한 저작권 고지는 `LICENSES/`에 있습니다. 고정된 대응 소스,
버전과 SHA-256은 `bfu-runtime/sources/`에 있으며 패치와 설정은
`bfu-runtime/patches/`, `bfu-runtime/config/`에 있습니다.

GitHub Release에는 APK와 함께 대응 소스와 라이선스 묶음을 게시합니다. 앱의
**오픈소스 라이선스** 화면에서도 같은 내용을 선택하고 복사할 수 있습니다.

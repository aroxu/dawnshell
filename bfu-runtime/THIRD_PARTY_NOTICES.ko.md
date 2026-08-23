# 내장 서드파티 고지

[English](THIRD_PARTY_NOTICES.md)

> 이 문서는 이해를 돕기 위한 한국어 안내다. 배포·법적 조건은 APK와
> `LICENSES/`에 포함된 영문 원문 및 각 업스트림 라이선스를 따른다.

DawnShell 애플리케이션 코드는 MIT 라이선스다. APK에는 별도 실행되는 명령행
프로그램, Debian 공개 아카이브 키, Android 라이브러리가 포함되며 각각 다음
업스트림 라이선스를 유지한다.

- BusyBox 1.38.0 (`dawnshell-toolbox`): GPL-2.0-only
- Debian base-installer 1.226의 `pkgdetails`: GPL-2.0-only
- GnuPG 2.4.9의 `gpgv`: GPL-3.0-or-later
- `gpgv`는 고정된 libgpg-error, libgcrypt, libassuan, libksba, npth 소스를
  정적으로 연결한다. 관련 LGPL/GPL 전문과 GnuPG/libgcrypt 추가 고지는
  `LICENSES/`에 있다.
- debootstrap 1.0.141: Expat/MIT 계열 라이선스
- Debian archive keyring 2025.1: 공개 키 데이터와 GPL-2.0-or-later 패키징
- AndroidX, Material Components, Kotlin, kotlinx.coroutines, JetBrains
  annotations, Error Prone annotations, Guava listenablefuture: Apache-2.0
- EdDSA-Java 0.3.0: CC0-1.0 Universal

라이선스 전문, 저작권 고지, Android 의존성 요약은 `LICENSES/`에 있으며 모든
APK의 `assets/open_source_licenses/`에도 포함된다.

고정된 대응 소스와 SHA-256은 `bfu-runtime/sources/`, Android 패치와 설정은
`bfu-runtime/patches/` 및 `bfu-runtime/config/`, 전체 빌드·설치 절차는
`scripts/`에 있다.

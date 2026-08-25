#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources_dir="$repo_dir/bfu-runtime/sources"
assets_dir="$repo_dir/app/src/main/assets/bfu"
output_dir="$assets_dir/bin"
bootstrap_assets_dir="$assets_dir/bootstrap"
if [[ -n "${DAWNSHELL_BUILD_JOBS:-}" ]]; then
    jobs="$DAWNSHELL_BUILD_JOBS"
elif command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
elif command -v getconf >/dev/null 2>&1; then
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
else
    jobs=4
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
    echo "DAWNSHELL_BUILD_JOBS must be a positive integer: $jobs" >&2
    exit 2
}

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK 29.0.14206865}"

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1758672000}"

case "$(uname -s)" in
    Linux*) host_tag=linux-x86_64 ;;
    Darwin*) host_tag=darwin-x86_64 ;;
    MINGW*|MSYS*|CYGWIN*) host_tag=windows-x86_64 ;;
    *) echo "Unsupported build host: $(uname -s)" >&2; exit 2 ;;
esac

ndk_properties="$ANDROID_NDK_HOME/source.properties"
if [[ ! -f "$ndk_properties" ]] \
        || ! grep -Fqx 'Pkg.Revision = 29.0.14206865' "$ndk_properties"; then
    echo "Android NDK 29.0.14206865 is required: $ANDROID_NDK_HOME" >&2
    exit 2
fi

toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag"
ndk_bin="$toolchain/bin"

find_ndk_tool() {
    local name="$1"
    local candidate
    for candidate in "$ndk_bin/$name" "$ndk_bin/$name.exe" "$ndk_bin/$name.cmd"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "Missing NDK tool: $name" >&2
    return 1
}

clang="$(find_ndk_tool clang)"
llvm_ar="$(find_ndk_tool llvm-ar)"
llvm_nm="$(find_ndk_tool llvm-nm)"
llvm_ranlib="$(find_ndk_tool llvm-ranlib)"
llvm_strip="$(find_ndk_tool llvm-strip)"
llvm_objcopy="$(find_ndk_tool llvm-objcopy)"
llvm_readelf="$(find_ndk_tool llvm-readelf)"
llvm_strings="$(find_ndk_tool llvm-strings)"

required_host_tools=(
    awk bash chmod gcc grep install make mkdir patch rm sed sha256sum sort tar yes
)
for command_name in "${required_host_tools[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing host build tool: $command_name" >&2
        exit 3
    }
done

verify_source() {
    local hash="$1"
    local filename="$2"
    local path="$sources_dir/$filename"
    [[ -f "$path" ]] || {
        echo "Missing vendored source: $path" >&2
        exit 4
    }
    printf '%s  %s\n' "$hash" "$path" | sha256sum -c -
}

verify_source 34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2 busybox-1.38.0.tar.bz2
verify_source 232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b debootstrap_1.0.141.tar.gz
verify_source 48bd396167f3d592f624e1e9012208a9a2adcb531cf56c90e27f0690a05f170e base-installer_1.226.tar.xz
verify_source dd17ab2e9a04fd79d39d853f599cbc852062ddb9ab52a4ddeb4176fd8b302964 gnupg-2.4.9.tar.bz2
verify_source d2931cdad266e633510f9970e1a2f346055e351bb19f9b78912475b8074c36f6 libassuan-3.0.2.tar.bz2
verify_source 7df5c08d952ba33f9b6bdabdb06a61a78b2cf62d2122c2d1d03a91a79832aa3c libgcrypt-1.12.1.tar.bz2
verify_source a19bc5087fd97026d93cb4b45d51638d1a25202a5e1fbc3905799f424cfa6134 libgpg-error-1.59.tar.bz2
verify_source 0f4510f1c7a679c3545990a31479f391ad45d84e039176309d42f80cf41743f5 libksba-1.6.8.tar.bz2
verify_source 8bd24b4f23a3065d6e5b26e98aba9ce783ea4fd781069c1b35d149694e90ca3e npth-1.8.tar.bz2
verify_source 9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac debian-archive-keyring_2025.1_all.deb
verify_source f376bfae7c864c76483bed094572db5ccb6f0d5f3f79ad021d6f461f0c2af436 debian-archive-keyring_2025.1.dsc
verify_source 2d019c3fa19c42da4d37571e473c296286dad0214cb3bd5cafd99f04a8bf5471 debian-archive-keyring_2025.1.tar.xz

grep -Fq \
    '2d019c3fa19c42da4d37571e473c296286dad0214cb3bd5cafd99f04a8bf5471 138248 debian-archive-keyring_2025.1.tar.xz' \
    "$sources_dir/debian-archive-keyring_2025.1.dsc" || {
    echo "Debian keyring source descriptor does not authenticate the vendored source" >&2
    exit 4
}

namespace_source="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
if grep -Eq 'unshare[[:space:]]*\([[:space:]]*CLONE_NEWIPC' "$namespace_source"; then
    echo "Unsafe CLONE_NEWIPC call is forbidden on legacy 4.4-era kernels" >&2
    exit 6
fi
for marker in \
    'prepare_devices_cgroup_mount(control_dir, host_usb_policy)' \
    'init_moved_to_devices_cgroup' \
    'cgroup_view_devices_bind' \
    'cleanup_cgroup_subtree_failed' \
    'devices_cgroup=delegated' \
    'prepare_unified_cgroup_mount(control_dir, host_usb_policy)' \
    'cgroup_v2_device_bpf_verified' \
    'BPF_F_ALLOW_MULTI' \
    'command_moved_to_cgroup_v2_leaf' \
    'cgroup_requested=auto' \
    'fallback=v1' \
    'cgroup_delegation=delegated' \
    'CGROUP_POLICY_FORCE_V2' \
    'CGROUP_POLICY_FORCE_V1' \
    'HOST_USB_EXCLUSIVE' \
    'reconcile_exclusive_usb' \
    'restore_exclusive_usb' \
    'exclusive_mode_requires_at_least_one_VID:PID'; do
    grep -Fq "$marker" "$namespace_source" || {
        echo "Missing namespace/cgroup invariant: $marker" >&2
        exit 7
    }
done
if grep -Eq 'uname[[:space:]]*\([^)]*-r|/proc/version' "$namespace_source"; then
    echo "Cgroup selection must probe capabilities, not kernel version strings" >&2
    exit 8
fi

build_root="$(mktemp -d "${TMPDIR:-/tmp}/dawnshell-bootstrap-runtime.XXXXXX")"
cleanup() {
    if [[ "${DAWNSHELL_KEEP_BOOTSTRAP_BUILD:-0}" == 1 ]]; then
        echo "Keeping bootstrap build tree: $build_root"
    else
        rm -rf -- "$build_root"
    fi
}
trap cleanup EXIT

configure_static_library() {
    local source_root="$1"
    shift
    local build_triplet
    build_triplet="$("$source_root/build-aux/config.guess")"
    (
        cd "$source_root"
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                # Keep runtime directory macros deterministic while still
                # allowing MSYS to translate temporary include/library paths.
                # shellcheck disable=SC2030
                export MSYS2_ARG_CONV_EXCL='-DLOCALEDIR;-DSYSCONFDIR;-DLOCALSTATEDIR;-DDATADIR'
                ;;
        esac
        ./configure \
            --host="$gnu_host" \
            --build="$build_triplet" \
            --prefix="$prefix" \
            --enable-static \
            --disable-shared \
            "$@"
        # Runtime directory constants must not contain the temporary build
        # prefix. Override them only while compiling; make install must keep
        # using the private staging prefix and never write to host /system.
        make -j"$jobs" \
            localedir=/system/share/locale \
            sysconfdir=/system/etc \
            localstatedir=/system/var \
            datadir=/system/share
        make install
    )
}

validate_elf() {
    local binary="$1"
    local machine_pattern="$2"
    local interpreter="$3"

    # Do not use grep -q here. With pipefail enabled it may close the pipe
    # early, make llvm-* exit on SIGPIPE, and invert a successful validation.
    "$llvm_readelf" -h "$binary" \
        | grep -E "Machine:[[:space:]]+$machine_pattern" >/dev/null
    "$llvm_readelf" -h "$binary" \
        | grep -E 'Type:[[:space:]]+DYN' >/dev/null
    "$llvm_readelf" -l "$binary" \
        | grep -F "$interpreter" >/dev/null
    if "$llvm_readelf" -d "$binary" | grep -F 'Shared library:' \
            | grep -Ev '\[(libc|libdl)\.so\]' >/dev/null; then
        echo "Unexpected Android native dependency in $binary" >&2
        "$llvm_readelf" -d "$binary" | grep -F 'Shared library:' >&2
        exit 5
    fi
    if "$llvm_strings" "$binary" \
            | grep -E '/data/(data|user|user_de)/[^/ ]+' \
                >/dev/null; then
        echo "Forbidden fixed Android data path embedded in $binary" >&2
        exit 6
    fi
    if "$llvm_strings" "$binary" \
            | grep -E 'dawnshell-bootstrap-runtime|[A-Za-z]:/Users/' \
                >/dev/null; then
        echo "Non-reproducible host build path embedded in $binary" >&2
        exit 6
    fi
}

validate_static_elf() {
    local binary="$1"
    local machine_pattern="$2"

    "$llvm_readelf" -h "$binary" \
        | grep -E "Machine:[[:space:]]+$machine_pattern" >/dev/null
    "$llvm_readelf" -h "$binary" \
        | grep -E 'Type:[[:space:]]+EXEC' >/dev/null
    if "$llvm_readelf" -l "$binary" | grep -F 'Requesting program interpreter' \
            >/dev/null; then
        echo "Static codec client unexpectedly has a program interpreter" >&2
        exit 5
    fi
    if "$llvm_readelf" -d "$binary" | grep -F 'Shared library:' >/dev/null; then
        echo "Static codec client unexpectedly has shared dependencies" >&2
        exit 5
    fi
    if "$llvm_strings" "$binary" \
            | grep -E '/data/(data|user|user_de)/[^/ ]+|[A-Za-z]:/Users/' \
                >/dev/null; then
        echo "Forbidden fixed data or host path embedded in $binary" >&2
        exit 6
    fi
}

validate_codec_worker_elf() {
    local binary="$1"
    local machine_pattern="$2"
    local interpreter="$3"

    "$llvm_readelf" -h "$binary" \
        | grep -E "Machine:[[:space:]]+$machine_pattern" >/dev/null
    "$llvm_readelf" -h "$binary" \
        | grep -E 'Type:[[:space:]]+DYN' >/dev/null
    "$llvm_readelf" -l "$binary" | grep -F "$interpreter" >/dev/null
    local dependencies
    dependencies="$($llvm_readelf -d "$binary" \
        | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort -u)"
    local expected=$'libandroid.so\nlibc.so\nlibdl.so\nlibmediandk.so'
    if [[ "$dependencies" != "$expected" ]]; then
        echo "Unexpected Android codec worker dependencies in $binary" >&2
        printf '%s\n' "$dependencies" >&2
        exit 5
    fi
    if "$llvm_strings" "$binary" \
            | grep -E '/data/(data|user|user_de)/[^/ ]+|[A-Za-z]:/Users/' \
                >/dev/null; then
        echo "Forbidden fixed data or host path embedded in $binary" >&2
        exit 6
    fi
}

merge_busybox_config() {
    local source_root="$1"
    local fragment="$repo_dir/bfu-runtime/config/busybox-bootstrap.config"
    (
        cd "$source_root"
        make allnoconfig > busybox-config.log
        while IFS= read -r setting; do
            case "$setting" in
                CONFIG_*=y)
                    local symbol="${setting%%=*}"
                    if grep -Fqx "# $symbol is not set" .config; then
                        sed -i "s/^# $symbol is not set$/$setting/" .config
                    elif ! grep -Fqx "$setting" .config; then
                        printf '%s\n' "$setting" >> .config
                    fi
                    ;;
            esac
        done < "$fragment"

        set +e
        yes '' | make oldconfig >> busybox-config.log
        local oldconfig_status="${PIPESTATUS[1]}"
        set -e
        [[ "$oldconfig_status" -eq 0 ]]
    )
}

build_busybox() {
    local work="$1"
    local stage="$2"
    tar -xf "$sources_dir/busybox-1.38.0.tar.bz2" -C "$work"
    local source_root="$work/busybox-1.38.0"
    (
        cd "$source_root"
        patch -p1 < "$repo_dir/bfu-runtime/patches/busybox/0001-android-mount-without-addmntent.patch"
    )
    merge_busybox_config "$source_root"
    (
        cd "$source_root"
        make -j"$jobs" \
            CC="$cc" HOSTCC=gcc \
            AR="$llvm_ar" NM="$llvm_nm" STRIP="$llvm_strip" \
            OBJCOPY="$llvm_objcopy" \
            EXTRA_CFLAGS='-Wno-ignored-optimization-argument -Wno-unused-command-line-argument'
        "$llvm_strip" --strip-unneeded busybox
        install -m 700 busybox "$stage/dawnshell-toolbox"
    )

    local symbol
    for symbol in \
        BUSYBOX FEATURE_INSTALLER FEATURE_MD5_SHA1_SUM_CHECK \
        FEATURE_STAT_FORMAT ASH AWK CHROOT DPKG_DEB MOUNT SED SHA256SUM \
        STAT TAR UNSHARE WGET ZCAT XZCAT; do
        grep -Fqx "CONFIG_${symbol}=y" "$source_root/.config" || {
            echo "BusyBox output is missing required config symbol: CONFIG_${symbol}=y" >&2
            exit 7
        }
    done
}

build_pkgdetails() {
    local work="$1"
    local stage="$2"
    tar -xf "$sources_dir/base-installer_1.226.tar.xz" -C "$work"
    "$clang" "--target=$clang_target" \
        -std=c17 -Os -fPIE -fstack-protector-strong \
        -Wall -Wextra -Wformat=2 -Wno-format-nonliteral \
        -Wl,-pie,-z,relro,-z,now \
        "$work/base-installer/pkgdetails.c" -o "$stage/pkgdetails"
    "$llvm_strip" --strip-unneeded "$stage/pkgdetails"
    chmod 700 "$stage/pkgdetails"
}

build_gpgv() {
    local work="$1"
    local stage="$2"
    local component
    for component in \
        libgpg-error-1.59.tar.bz2 \
        libgcrypt-1.12.1.tar.bz2 \
        libassuan-3.0.2.tar.bz2 \
        libksba-1.6.8.tar.bz2 \
        npth-1.8.tar.bz2 \
        gnupg-2.4.9.tar.bz2; do
        tar -xf "$sources_dir/$component" -C "$work"
    done

    (
        cd "$work/libgpg-error-1.59"
        patch -p1 < "$repo_dir/bfu-runtime/patches/libgpg-error/0001-skip-deprecated-config-self-test.patch"
    )

    prefix="$work/prefix"
    mkdir -p "$prefix"
    export CC="$cc"
    export AR="$llvm_ar"
    export NM="$llvm_nm"
    export RANLIB="$llvm_ranlib"
    export STRIP="$llvm_strip"
    export CPPFLAGS="-I$prefix/include"
    export CFLAGS='-Os -fPIC -fstack-protector-strong'
    export LDFLAGS="-L$prefix/lib -Wl,-z,relro,-z,now"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    export PATH="$prefix/bin:$PATH"

    configure_static_library "$work/libgpg-error-1.59" \
        --disable-nls --disable-doc --disable-tests \
        --disable-install-gpg-error-config

    configure_static_library "$work/libgcrypt-1.12.1" \
        --disable-doc --disable-asm \
        --with-libgpg-error-prefix="$prefix"

    configure_static_library "$work/libassuan-3.0.2" \
        --disable-doc \
        --with-libgpg-error-prefix="$prefix"

    configure_static_library "$work/libksba-1.6.8" \
        --disable-doc \
        --with-libgpg-error-prefix="$prefix"

    (
        cd "$work/npth-1.8"
        local build_triplet
        build_triplet="$(./build-aux/config.guess)"
        ac_cv_search_pthread_cancel='none required' ./configure \
            --host="$gnu_host" \
            --build="$build_triplet" \
            --prefix="$prefix" \
            --enable-static \
            --disable-shared \
            --disable-tests
        make -j"$jobs"
        make install
    )

    # gpgrt-config recursively invokes itself under MSYS path translation.
    # The legacy, generated config scripts are sufficient for this cross-build.
    rm -f "$prefix/bin/gpgrt-config"

    (
        cd "$work/gnupg-2.4.9"
        local build_triplet
        build_triplet="$(./build-aux/config.guess)"
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                # Preserve the fixed /system paths embedded by GnuPG instead
                # of letting MSYS rewrite -D arguments to a host path.
                # shellcheck disable=SC2031
                export MSYS2_ARG_CONV_EXCL='-DGNUPG_;-DLOCALEDIR'
                ;;
        esac
        export CFLAGS='-Os -fPIE -fstack-protector-strong'
        export GPG_ERROR_CONFIG="$work/libgpg-error-1.59/src/gpg-error-config-old"
        export LIBGCRYPT_CONFIG="$prefix/bin/libgcrypt-config"
        export LIBASSUAN_CONFIG="$prefix/bin/libassuan-config"
        export KSBA_CONFIG="$prefix/bin/ksba-config"
        export NPTH_CONFIG="$work/npth-1.8/npth-config"
        ./configure \
            --host="$gnu_host" \
            --build="$build_triplet" \
            --prefix=/system \
            --disable-nls \
            --disable-doc \
            --disable-tests \
            --disable-gpgsm \
            --disable-scdaemon \
            --disable-dirmngr \
            --disable-keyboxd \
            --disable-tpm2d \
            --disable-gpgtar \
            --disable-wks-tools \
            --disable-ccid-driver \
            --disable-ldap \
            --disable-zip \
            --disable-bzip2 \
            --disable-sqlite \
            --without-libiconv-prefix \
            --without-libintl-prefix \
            --with-libgpg-error-prefix="$prefix" \
            --with-libgcrypt-prefix="$prefix" \
            --with-libassuan-prefix="$prefix"
        make -j"$jobs" -C common
        make -j"$jobs" -C regexp
        make -j"$jobs" -C kbx
        make -j"$jobs" -C g10 gpgv
        "$llvm_strip" --strip-unneeded g10/gpgv
        install -m 700 g10/gpgv "$stage/gpgv"
    )
}

build_namespace_probe() {
    local stage="$1"
    "$clang" "--target=$clang_target" \
        -std=c17 -Os -fPIE -fstack-protector-strong \
        -Wall -Wextra -Werror -Wformat=2 \
        -Wl,-pie -Wl,-z,relro,-z,now -Wl,--gc-sections \
        "$repo_dir/app/src/main/cpp/bfu_namespace_probe.c" \
        -o "$stage/bfu-namespace-probe"
    "$llvm_strip" --strip-unneeded "$stage/bfu-namespace-probe"
    chmod 700 "$stage/bfu-namespace-probe"
}

build_codec_client() {
    local stage="$1"
    "$clang" "--target=$clang_target" \
        -std=c17 -Os -static -fPIE -fstack-protector-strong \
        -Wall -Wextra -Werror -Wformat=2 \
        -Wl,-z,relro,-z,now -Wl,--gc-sections \
        "$repo_dir/app/src/main/cpp/dawnshell_codec_client.c" \
        -o "$stage/dawnshell-codec"
    "$llvm_strip" --strip-unneeded "$stage/dawnshell-codec"
    chmod 700 "$stage/dawnshell-codec"
}

build_codec_worker() {
    local stage="$1"
    "$clang" "--target=$clang_target" \
        -std=c17 -Os -fPIE -fstack-protector-strong \
        -Wall -Wextra -Werror -Wformat=2 \
        -Wl,-pie -Wl,-z,relro,-z,now -Wl,--gc-sections \
        "$repo_dir/app/src/main/cpp/dawnshell_codec_worker.c" \
        "$repo_dir/app/src/main/cpp/dawnshell_codec_ndk.c" \
        -lmediandk -landroid -ldl \
        -o "$stage/dawnshell-codec-worker"
    "$llvm_strip" --strip-unneeded "$stage/dawnshell-codec-worker"
    chmod 700 "$stage/dawnshell-codec-worker"
}

build_architecture() {
    local abi="$1"
    local clang_target="$2"
    gnu_host="$3"
    local debian_arch="$4"
    local machine_pattern="$5"
    local interpreter="$6"
    local work="$build_root/$abi"
    local stage="$work/stage"
    mkdir -p "$stage"

    cc="$clang --target=$clang_target"
    echo "=== Building $abi (Debian $debian_arch) ==="
    build_busybox "$work" "$stage"
    build_pkgdetails "$work" "$stage"
    build_gpgv "$work" "$stage"
    build_namespace_probe "$stage"
    build_codec_client "$stage"
    build_codec_worker "$stage"

    local binary
    for binary in dawnshell-toolbox pkgdetails gpgv bfu-namespace-probe; do
        validate_elf "$stage/$binary" "$machine_pattern" "$interpreter"
    done
    validate_static_elf "$stage/dawnshell-codec" "$machine_pattern"
    validate_codec_worker_elf "$stage/dawnshell-codec-worker" \
        "$machine_pattern" "$interpreter"

    mkdir -p "$output_dir/$abi"
    install -m 700 "$stage/dawnshell-toolbox" \
        "$output_dir/$abi/dawnshell-toolbox"
    install -m 700 "$stage/pkgdetails" "$output_dir/$abi/pkgdetails"
    install -m 700 "$stage/gpgv" "$output_dir/$abi/gpgv"
    install -m 700 "$stage/bfu-namespace-probe" \
        "$output_dir/$abi/bfu-namespace-probe"
    install -m 700 "$stage/dawnshell-codec" \
        "$output_dir/$abi/dawnshell-codec"
    install -m 700 "$stage/dawnshell-codec-worker" \
        "$output_dir/$abi/dawnshell-codec-worker"

    printf '%s\n' \
        "android_abi=$abi" \
        "debian_architecture=$debian_arch" \
        "android_api=24" \
        "busybox=1.38.0" \
        "pkgdetails_base_installer=1.226" \
        "gpgv=2.4.9" \
        "dawnshell_codec_protocol=1" \
        "dawnshell_codec_transport=inherited_memfd_eventfd" \
        "dawnshell_codec_worker=ndk_mediacodec" \
        > "$output_dir/$abi/runtime.properties"

    sha256sum "$output_dir/$abi/"{dawnshell-toolbox,pkgdetails,gpgv,bfu-namespace-probe,dawnshell-codec,dawnshell-codec-worker}
}

mkdir -p "$output_dir" "$bootstrap_assets_dir"
rm -f -- "$output_dir/bfu-namespace-probe-arm64"

requested_abis="${DAWNSHELL_BOOTSTRAP_ABIS:-armeabi-v7a arm64-v8a x86_64}"
for requested_abi in $requested_abis; do
    case "$requested_abi" in
        armeabi-v7a)
            build_architecture \
                armeabi-v7a armv7a-linux-android24 armv7a-linux-androideabi \
                armhf 'ARM' /system/bin/linker
            ;;
        arm64-v8a)
            build_architecture \
                arm64-v8a aarch64-linux-android24 aarch64-linux-androideabi \
                arm64 'AArch64' /system/bin/linker64
            ;;
        x86_64)
            build_architecture \
                x86_64 x86_64-linux-android24 x86_64-linux-androideabi \
                amd64 'Advanced Micro Devices X86-64' /system/bin/linker64
            ;;
        *)
            echo "Unsupported DAWNSHELL_BOOTSTRAP_ABIS entry: $requested_abi" >&2
            exit 8
            ;;
    esac
done

install -m 600 "$sources_dir/debootstrap_1.0.141.tar.gz" \
    "$bootstrap_assets_dir/debootstrap_1.0.141.tgz"
rm -f -- "$bootstrap_assets_dir/debootstrap_1.0.141.tar.gz"
install -m 600 "$sources_dir/debian-archive-keyring_2025.1_all.deb" \
    "$bootstrap_assets_dir/debian-archive-keyring_2025.1_all.deb"
install -m 600 "$sources_dir/SOURCES.lock" \
    "$bootstrap_assets_dir/SOURCES.lock"

echo "Bootstrap runtime source build completed for: $requested_abis"

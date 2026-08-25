cmake_minimum_required(VERSION 3.22.1)
project(dawnshell_codec_socket C)

# Only the broker's socket transport lives here. Android's LocalSocket stream
# API rejects a message carrying an SCM_RIGHTS descriptor with EMSGSIZE, so
# the broker must call recvmsg and sendmsg directly.
add_library(dawnshell_codec_socket SHARED codec_socket_jni.c)

target_compile_options(dawnshell_codec_socket PRIVATE
        -std=c17 -Os -fstack-protector-strong
        -Wall -Wextra -Werror -Wformat=2)

target_link_options(dawnshell_codec_socket PRIVATE
        -Wl,-z,relro,-z,now -Wl,--gc-sections)

find_library(ANDROID_LOG_LIBRARY log)
target_link_libraries(dawnshell_codec_socket ${ANDROID_LOG_LIBRARY})

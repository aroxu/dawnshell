# BFU runtime

This directory will contain the reproducible ARM64 server-only Dropbear build. It
must not import the normal Termux Dropbear package artifact: that package is
dynamic, depends on `termux-auth` and zlib, and embeds the normal Termux prefix.

The APK-native executable and its source/build metadata belong here. Runtime keys,
authorized keys, pids, and logs belong only in Termux:Boot Device Protected Storage
on the device and must never be committed.


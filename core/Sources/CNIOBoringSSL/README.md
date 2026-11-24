# CNIOBoringSSL (vendored)

BoringSSL as packaged by [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) 2.37.6, copied
unchanged from its `Sources/CNIOBoringSSL` (BoringSSL revision in `hash.txt`). Nearside uses only
this C library (TLS 1.3 and SPAKE2 for adb), not swift-nio-ssl's Swift layer, which doesn't build
on Windows; and swift-nio-ssl doesn't publish the C library as a product of its own.

To update: copy `Sources/CNIOBoringSSL` from a newer swift-nio-ssl release over this folder
(keeping this file, `LICENSE.txt` and `NOTICE.txt` from that release), and its target's
`cSettings` into `core/Package.swift`.

Licences: swift-nio-ssl's Apache 2.0 (`LICENSE.txt`, `NOTICE.txt`); BoringSSL's own (OpenSSL,
ISC and others) are in the source files' headers.

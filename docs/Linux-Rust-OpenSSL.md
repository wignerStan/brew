# Rust OpenSSL runtime paths on Linux

Rust's `openssl-sys` build script can discover Homebrew OpenSSL with
`pkg-config`. The resulting executable may need `libssl.so.4` and
`libcrypto.so.4` without recording a runtime search path. Linux does not
search a keg-only Homebrew library directory by default.

On Incus, `cargo --version` and `rustc --version` worked. The separately
built `aw-checker` executable failed before main. Its ELF dynamic section
listed the OpenSSL libraries but contained neither RPATH nor RUNPATH.
Setting LD_LIBRARY_PATH hid the missing runtime search path.

Configure the Rust consumer to record the library path at link time:

```toml
[target.x86_64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-Wl,-rpath,/home/linuxbrew/.linuxbrew/opt/openssl@4/lib"]
```

Use the stable opt path, then rebuild existing binaries. A major OpenSSL
upgrade still requires rebuilding consumers. Do not add Homebrew libraries
to a global LD_LIBRARY_PATH or change unrelated system loader settings.

This is a consumer link configuration issue. Homebrew's own OpenSSL, curl,
Ruby OpenSSL extension and the private overlay's radare2 ran without that
variable. No loader change to the overlay implementation is required.

The 2026-10-17 deployment passed the Rust build and 23 checker tests with
LD_LIBRARY_PATH unset. Rebase validation passed type and style checks,
the overlay shell and runtime boot tests and all 60 keg tests. The full
changed-file online suite still reports host failures in upstream trust,
sandbox and Bootsnap tests. It requires an isolated cache and a short
temporary path on the same Btrfs subvolume to avoid hard-link and Unix
socket path failures.

The rebase also removes obsolete wrapper redirection retained by the fork.
Both failing wrapper regressions pass after removing that block; the full
wrapper test file passes all 14 examples.

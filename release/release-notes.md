## 4.3.3 - 2026-09-08

**Highlights:** Prevent accidental GUI host launches and read Firestaff manifests more safely.

- Refuse CLI-style invocations of Peekaboo.app before capture or Bridge startup, with guidance to use the separate `peekaboo` CLI binary. #706.
- Read immutable Firestaff frames across atomic updates, reject detectable in-place rewrites, and add opt-in byte limits while preserving the unlimited default; thanks @SebTardif for #703.
- Honor `config edit --print-path` without creating a configuration file or launching an editor. #707.
- Fix generated Homebrew formula smoke tests to recognize the v4 `Usage` header. #702.
- Prevent intermittent release verification failures when inspecting universal binaries, and keep release test fixtures out of publication directories.

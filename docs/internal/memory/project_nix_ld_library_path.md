---
name: LD_LIBRARY_PATH for Nix-built Nim binaries
description: Nim binaries on this NixOS box can't find OpenSSL or other dynamic libs at runtime without LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib.
type: project
originSessionId: b148520b-ecfa-4969-897d-69c921fd08fd
---
Compiling Nim binaries with `-d:ssl` (or anything else that pulls in a
nix-managed dynamic library) succeeds at link time but fails at runtime
with errors like `could not find symbol: SSL_library_init`. Setting
`LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib` before running
the binary fixes it.

**Why:** the user's NixOS configuration. nix-ld provides a glibc-style
loader for non-Nix binaries; Nim's compiled output looks for OpenSSL by
soname and the nix-ld lib directory is where those sonames resolve.

**How to apply:** when running any built Nim binary on this machine that
uses chronos HTTP/TLS, websocket TLS, or directly imports
`std/httpclient`/`std/net`, prefix with that env var. CI / deploy on
non-Nix machines wouldn't need it. Two project-level mitigations to
remember:

* `config.nims` does **not** force `-d:ssl`. SSL is opt-in per-binary so
  unit-test binaries don't load OpenSSL at all (they ran fine without
  the env var). The example that uses `chronos/apps/http/httpclient`
  builds with `-d:ssl` explicitly.
* If a future test or example starts hanging or erroring on dynamic
  symbol lookup, the env var is the first thing to try before chasing
  it as a code bug.

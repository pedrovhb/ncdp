# Project-wide build configuration. Loaded for every compilation in this tree.

switch("path", "$projectDir/src")
switch("path", "/app/nws_client/src")
switch("mm", "orc")
# `-d:ssl` is opt-in per-binary: examples that talk to wss:// or fetch
# https:// URLs add `--define:ssl` themselves. Forcing it here drags
# OpenSSL into every test binary, which then needs LD_LIBRARY_PATH set
# at runtime — too much friction for the parser/transport unit tests.

# Strict-by-default style: keep warnings loud during development.
switch("warning", "UnusedImport:on")
switch("hint", "Processing:off")

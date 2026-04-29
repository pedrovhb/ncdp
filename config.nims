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

# chronicles: structured logging. Sink is plain text to stderr (keeps stdout
# clean for example output). Log level is DEBUG in dev builds, INFO in
# release — set per-binary via -d:release.
switch("define", "chronicles_sinks=textlines[stderr,nocolors]")
when defined(release):
  switch("define", "chronicles_log_level=WARN")
else:
  # switch("define", "chronicles_log_level=DEBUG")
  switch("define", "chronicles_log_level=WARN")

# Keep routine compiler chatter out of normal runs; warnings and errors still
# surface, but config/link/success noise does not.
switch("hint", "[Conf]:off")
switch("hint", "[Path]:off")
switch("hint", "[CC]:off")
switch("hint", "[Processing]:off")
switch("hint", "[Link]:off")
switch("hint", "[SuccessX]:off")
switch("hint", "[Exec]:off")

# Examples compile from this subtree; ensure they can find ``ncdp``.
# Path is relative to this config file, so it stays correct regardless of
# the user's working directory.
import std/os
switch("path", thisDir() / ".." / "src")

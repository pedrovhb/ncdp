## Launch and manage Chrome / Chromium for CDP integration.
##
## Two entry points:
##
## * `launch(opts)` — spawn a fresh browser process with a temporary
##   user-data dir, wait for the debugger endpoint to become reachable,
##   and return a handle owning both the process and the discovered
##   browser-level websocket URL.
## * `discover(host, port)` — point at an already-running browser
##   started elsewhere and return its websocket URL only.
##
## A `ChromeProcess` returned by `launch` cleans itself up on
## `terminate`: SIGTERM with a configurable grace period, falling back
## to SIGKILL, then deleting the temporary user-data dir.

import std/[json, os, strformat]
import chronos
import chronos/asyncproc
import chronos/apps/http/httpclient

type
  LaunchOptions* = object
    ## Configuration knobs for `launch`. Sensible defaults mean the
    ## common case — "give me a headless Chrome on a random local
    ## port" — is one zero-arg call away.
    executable*: string
      ## Override the binary path. Empty means "look up via
      ## ``$NCDP_CHROME`` and then PATH".
    host*: string ## Default ``"127.0.0.1"``.
    port*: int    ## Default ``9222``. Pick something else when running
                  ## several browsers in parallel.
    headless*: bool   ## Default ``true``. ``--headless=new`` is passed
                      ## when this is set.
    extraArgs*: seq[string]
      ## Appended verbatim to the chrome command line, after the
      ## defaults.
    userDataDir*: string
      ## Override the user-data dir. Empty means "create a fresh temp
      ## dir and clean it up on terminate".
    bootTimeout*: Duration
      ## How long `launch` waits for the debugger endpoint to come up
      ## before giving up. Default 10 seconds.

  ChromeProcess* = ref object
    handle: AsyncProcessRef
    wsUrl*: string
      ## Browser-level websocket URL (the ``webSocketDebuggerUrl`` from
      ## ``/json/version``). Pass this straight to
      ## ``transport.connect``.
    httpBase*: string
      ## ``http://host:port`` — handy for hitting other endpoints under
      ## ``/json/`` for tab discovery, etc.
    userDataDir: string
      ## Set when launch created a temp dir; cleaned up on terminate.

  ChromeError* = object of CatchableError
    ## Any failure from this module: missing binary, boot timeout,
    ## non-200 response from the discovery endpoint, malformed JSON.

# -------------------------------------------------------- defaults ----------

proc initLaunchOptions*(): LaunchOptions =
  ## Default options — useful as a base when overriding only one or two
  ## fields: ``var o = initLaunchOptions(); o.port = 9333``.
  LaunchOptions(
    host: "127.0.0.1",
    port: 9222,
    headless: true,
    bootTimeout: 10.seconds)

# -------------------------------------------------------- helpers -----------

proc fail(msg: string) {.noreturn.} =
  raise newException(ChromeError, msg)

const ChromeCandidates = [
  "chromium", "chromium-browser",
  "google-chrome", "google-chrome-stable",
  "chrome",
]

proc resolveExecutable(override: string): string =
  ## Pick an executable: explicit override → ``$NCDP_CHROME`` →
  ## first hit in ``$PATH`` from the candidate list.
  if override.len > 0:
    if not fileExists(override):
      fail("chrome executable not found: " & override)
    return override
  let envPath = getEnv("NCDP_CHROME")
  if envPath.len > 0:
    if not fileExists(envPath):
      fail("NCDP_CHROME points at non-existent file: " & envPath)
    return envPath
  for name in ChromeCandidates:
    let p = findExe(name)
    if p.len > 0: return p
  fail("could not find Chrome / Chromium on PATH; " &
       "set NCDP_CHROME or pass LaunchOptions.executable")

proc buildArgs(opts: LaunchOptions; userDataDir: string): seq[string] =
  ## Compose the chrome command line. Most defaults exist to keep the
  ## headless instance from doing anything we didn't ask for: no first-
  ## run UI, no default browser prompt, no network probes for
  ## extensions, no GPU init when we won't render anything.
  result = @[
    &"--remote-debugging-port={opts.port}",
    &"--user-data-dir={userDataDir}",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--metrics-recording-only",
    "--disable-features=Translate,MediaRouter",
    "--mute-audio",
    "--password-store=basic",
    "--use-mock-keychain",
  ]
  if opts.headless:
    result.add "--headless=new"
    result.add "--disable-gpu"
  for a in opts.extraArgs: result.add a
  result.add "about:blank"

proc fetchVersion(host: string; port: int): Future[JsonNode] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## One-shot HTTP GET to ``/json/version``. Returns the parsed body.
  ## Failures are mapped to ``ChromeError`` so callers don't have to
  ## know about chronos's HTTP error hierarchy.
  let session = HttpSessionRef.new()
  defer:
    try: await session.closeWait()
    except CancelledError: discard
  let url = parseUri(&"http://{host}:{port}/json/version")
  var resp: HttpResponseTuple
  try:
    resp = await session.fetch(url)
  except CancelledError as e: raise e
  except CatchableError as e:
    raise newException(ChromeError, "fetch failed: " & e.msg)
  if resp.status != 200:
    fail(&"/json/version returned HTTP {resp.status}")
  var body = newString(resp.data.len)
  for i in 0 ..< resp.data.len: body[i] = char(resp.data[i])
  try: parseJson(body)
  except CatchableError as e:
    raise newException(ChromeError, "/json/version: bad JSON: " & e.msg)

proc waitForBoot(host: string; port: int;
                 timeout: Duration): Future[JsonNode] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Poll ``/json/version`` until it answers or ``timeout`` elapses.
  ## Backoff: 50 ms → 100 ms → 200 ms, capped at 500 ms.
  let deadline = Moment.now() + timeout
  var delay = 50.milliseconds
  var lastErr = ""
  while Moment.now() < deadline:
    try:
      return await fetchVersion(host, port)
    except CancelledError as e: raise e
    except ChromeError as e:
      lastErr = e.msg
    await sleepAsync(delay)
    if delay < 500.milliseconds: delay = delay * 2
  fail("timed out waiting for chrome debugger endpoint" &
       (if lastErr.len > 0: " (last error: " & lastErr & ")" else: ""))

# -------------------------------------------------------- public API --------

proc rewriteAuthority(wireUrl, host: string; port: int): string =
  ## Chrome echoes back whatever ``Host:`` header it received in the
  ## ``webSocketDebuggerUrl``, so when our HTTP client omits the port
  ## (chronos drops the default-looking ``:80`` for HTTP fetches), we
  ## get a URL that's missing it. Patch the authority back from the
  ## known host:port we just talked to.
  const Schemes = ["ws://", "wss://"]
  for scheme in Schemes:
    if wireUrl.startsWith(scheme):
      let rest = wireUrl[scheme.len .. ^1]
      let slash = rest.find('/')
      let pathPart = if slash >= 0: rest[slash .. ^1] else: ""
      return &"{scheme}{host}:{port}{pathPart}"
  wireUrl  # unrecognised scheme — leave it alone

proc discover*(host = "127.0.0.1"; port = 9222): Future[string] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Resolve the browser-level websocket URL from a Chrome started
  ## elsewhere. Equivalent to fetching ``/json/version`` once and
  ## pulling out the ``webSocketDebuggerUrl`` field, with the
  ## host:port restored to what we actually used (Chrome rewrites it
  ## from the request's ``Host:`` header, dropping the default port).
  let info = await fetchVersion(host, port)
  let url = info.getOrDefault("webSocketDebuggerUrl")
  if url.isNil or url.kind != JString:
    fail("/json/version: missing webSocketDebuggerUrl")
  rewriteAuthority(url.getStr(), host, port)

proc launch*(opts = initLaunchOptions()): Future[ChromeProcess] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Spawn a fresh chrome process and return a handle once the
  ## debugger endpoint is responsive. The caller owns the handle and
  ## must call ``terminate`` on it (typically inside a ``try/finally``).
  let exe = try: resolveExecutable(opts.executable)
            except OSError as e:
              raise newException(ChromeError, e.msg)
  let dataDir =
    if opts.userDataDir.len > 0:
      opts.userDataDir
    else:
      let d = getTempDir() / &"ncdp-chrome-{getCurrentProcessId()}-{opts.port}"
      try: createDir(d)
      except CatchableError as e:
        fail("could not create user-data dir: " & e.msg)
      d
  let args = buildArgs(opts, dataDir)
  # Chrome's stderr is left unredirected and prints to the parent's
  # terminal. That's loud but cheap; a future revision can wire
  # stdoutHandle / stderrHandle through `ProcessStreamHandle.init` to
  # capture or discard the output.
  let process = try:
      await startProcess(exe, arguments = args)
    except CancelledError as e: raise e
    except CatchableError as e:
      raise newException(ChromeError, "startProcess failed: " & e.msg)

  result = ChromeProcess(
    handle: process,
    httpBase: &"http://{opts.host}:{opts.port}",
    userDataDir: if opts.userDataDir.len > 0: "" else: dataDir,
  )
  template tearDownAndRaise(err: untyped) =
    # Boot failed — tear the process down before propagating.
    try: discard process.terminate()
    except CatchableError: discard
    try: await process.closeWait()
    except CatchableError: discard
    if result.userDataDir.len > 0:
      try: removeDir(result.userDataDir)
      except CatchableError: discard
    raise err
  try:
    let info = await waitForBoot(opts.host, opts.port, opts.bootTimeout)
    let url = info.getOrDefault("webSocketDebuggerUrl")
    if url.isNil or url.kind != JString:
      fail("/json/version: missing webSocketDebuggerUrl")
    result.wsUrl = rewriteAuthority(url.getStr(), opts.host, opts.port)
  except ChromeError as e:
    tearDownAndRaise(e)
  except CancelledError as e:
    tearDownAndRaise(e)

proc terminate*(p: ChromeProcess; grace = 3.seconds): Future[void] {.
    async: (raises: [CancelledError]).} =
  ## Stop the process. Tries SIGTERM, waits up to ``grace`` for an
  ## exit, falls back to SIGKILL, then closes pipes and (if we created
  ## one) removes the temporary user-data dir. Idempotent and safe to
  ## call from a ``finally`` block; nothing here re-raises beyond
  ## cancellation.
  if p.handle.isNil: return
  try: discard p.handle.terminate()
  except CatchableError: discard
  try:
    discard await p.handle.waitForExit().wait(grace)
  except AsyncTimeoutError:
    try: discard p.handle.kill()
    except CatchableError: discard
    try: discard await p.handle.waitForExit().wait(grace)
    except CatchableError: discard
  except CancelledError as e:
    raise e
  except CatchableError: discard
  try: await p.handle.closeWait()
  except CatchableError: discard
  if p.userDataDir.len > 0:
    try: removeDir(p.userDataDir)
    except CatchableError: discard
    p.userDataDir = ""

## Bindings for the CDP `SystemInfo` domain.
##
## NOTE: this is a hand-written reference module, the second of two
## (after `schema.nim`) used to anchor the codegen design. The shape
## decisions tested here:
##
## * `optional` PDL fields → `Option[T]` Nim fields, default-initialised
##   to `none(T)`. Outbound serialisation strips them via the
##   `dropNullFields` pass in the transport.
## * Named PDL enums → Nim enums with the type-prefix convention:
##   `SubsamplingFormat` members `sfYuv420`, `sfYuv422`, `sfYuv444`.
##   The wire spelling is preserved via `to/fromJsonHook` overloads so
##   generated callers never see the difference.
## * Object-typed fields use the qualified Nim type name as expected.
## * Commands with both `parameters` and `returns` carry the parameters
##   as flat proc arguments and a `*Result` object for the return.
##
## Source PDL: `resources/devtools-protocol/pdl/domains/SystemInfo.pdl`,
## `experimental domain SystemInfo`.

import chronos
import ./jsonhooks
import ./transport

# ---------------------------------------------------------- enum types ----

type
  SubsamplingFormat* = enum
    ## YUV subsampling type of the pixels of a given image.
    sfYuv420
    sfYuv422
    sfYuv444

  ImageType* = enum
    ## Image format of a given image.
    itJpeg
    itWebp
    itUnknown

const
  SubsamplingFormatWire: array[SubsamplingFormat, string] =
    ["yuv420", "yuv422", "yuv444"]
  ImageTypeWire: array[ImageType, string] =
    ["jpeg", "webp", "unknown"]

proc toJsonHook*(v: SubsamplingFormat; opt = initToJsonOptions()): JsonNode =
  newJString(SubsamplingFormatWire[v])

proc fromJsonHook*(v: var SubsamplingFormat; n: JsonNode; opt = Joptions()) =
  if n.kind != JString:
    raise newException(ValueError, "SubsamplingFormat: expected string")
  let s = n.getStr()
  for k, w in SubsamplingFormatWire:
    if w == s: v = k; return
  raise newException(ValueError, "SubsamplingFormat: unknown value " & s)

proc toJsonHook*(v: ImageType; opt = initToJsonOptions()): JsonNode =
  newJString(ImageTypeWire[v])

proc fromJsonHook*(v: var ImageType; n: JsonNode; opt = Joptions()) =
  if n.kind != JString:
    raise newException(ValueError, "ImageType: expected string")
  let s = n.getStr()
  for k, w in ImageTypeWire:
    if w == s: v = k; return
  raise newException(ValueError, "ImageType: unknown value " & s)

# ---------------------------------------------------------- object types --

type
  GPUDevice* = ref object
    ## Describes a single graphics processor (GPU).
    vendorId*: float
      ## PCI ID of the GPU vendor, if available; 0 otherwise.
    deviceId*: float
      ## PCI ID of the GPU device, if available; 0 otherwise.
    subSysId*: Option[float]
      ## Sub sys ID of the GPU, only available on Windows.
    revision*: Option[float]
      ## Revision of the GPU, only available on Windows.
    vendorString*: string
      ## String description of the GPU vendor, if the PCI ID is not available.
    deviceString*: string
      ## String description of the GPU device, if the PCI ID is not available.
    driverVendor*: string
      ## String description of the GPU driver vendor.
    driverVersion*: string
      ## String description of the GPU driver version.

  Size* = ref object
    ## Describes the width and height dimensions of an entity.
    width*: int
      ## Width in pixels.
    height*: int
      ## Height in pixels.

  VideoDecodeAcceleratorCapability* = ref object
    ## Describes a supported video decoding profile with its associated
    ## minimum and maximum resolutions.
    profile*: string
      ## Video codec profile that is supported, e.g. VP9 Profile 2.
    maxResolution*: Size
      ## Maximum video dimensions in pixels supported for this profile.
    minResolution*: Size
      ## Minimum video dimensions in pixels supported for this profile.

  VideoEncodeAcceleratorCapability* = ref object
    ## Describes a supported video encoding profile with its associated
    ## maximum resolution and maximum framerate.
    profile*: string
      ## Video codec profile that is supported, e.g. H264 Main.
    maxResolution*: Size
      ## Maximum video dimensions in pixels supported for this profile.
    maxFramerateNumerator*: int
    maxFramerateDenominator*: int

  GPUInfo* = ref object
    ## Provides information about the GPU(s) on the system.
    devices*: seq[GPUDevice]
      ## The graphics devices on the system. Element 0 is the primary GPU.
    auxAttributes*: Option[JsonNode]
      ## An optional dictionary of additional GPU related attributes.
    featureStatus*: Option[JsonNode]
      ## An optional dictionary of graphics features and their status.
    driverBugWorkarounds*: seq[string]
      ## An optional array of GPU driver bug workarounds.
    videoDecoding*: seq[VideoDecodeAcceleratorCapability]
      ## Supported accelerated video decoding capabilities.
    videoEncoding*: seq[VideoEncodeAcceleratorCapability]
      ## Supported accelerated video encoding capabilities.

  ProcessInfo* = ref object
    ## Represents process info.
    `type`*: string
      ## Specifies process type. Field name backquoted because `type`
      ## is a Nim keyword.
    id*: int
      ## Specifies process id.
    cpuTime*: float
      ## Specifies cumulative CPU usage in seconds across all threads
      ## of the process since the process start.

# ---------------------------------------------------- command results -----

type
  GetInfoResult* = ref object
    ## Result of `SystemInfo.getInfo`.
    gpu*: GPUInfo
      ## Information about the GPUs on the system.
    modelName*: string
      ## A platform-dependent description of the model of the machine.
    modelVersion*: string
      ## A platform-dependent description of the version of the machine.
    commandLine*: string
      ## The command line string used to launch the browser.

  GetFeatureStateResult* = ref object
    ## Result of `SystemInfo.getFeatureState`.
    featureEnabled*: bool

  GetProcessInfoResult* = ref object
    ## Result of `SystemInfo.getProcessInfo`.
    processInfo*: seq[ProcessInfo]
      ## An array of process info blocks.

# --------------------------------------------------------- commands -------

template wrapDecode(domainMethod, body): untyped =
  ## Common wrapper around `jsonTo` calls so a malformed response shape
  ## becomes a `CDPError` rather than escaping as a generic
  ## `ValueError` / `KeyError` from the JSON layer.
  try:
    body
  except CatchableError as wrapDecodeErr:
    raise newException(CDPError,
      domainMethod & ": malformed response: " & wrapDecodeErr.msg)

proc getInfo*(client: CDPClient): Future[GetInfoResult] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Returns information about the system.
  let raw = await client.sendCommand("SystemInfo.getInfo")
  wrapDecode "SystemInfo.getInfo":
    result = jsonTo(raw, GetInfoResult)

proc getFeatureState*(client: CDPClient;
                      featureState: string): Future[GetFeatureStateResult] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Returns information about the feature state.
  let params = newJObject()
  params["featureState"] = newJString(featureState)
  let raw = await client.sendCommand("SystemInfo.getFeatureState", params)
  wrapDecode "SystemInfo.getFeatureState":
    result = jsonTo(raw, GetFeatureStateResult)

proc getProcessInfo*(client: CDPClient): Future[GetProcessInfoResult] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Returns information about all running processes.
  let raw = await client.sendCommand("SystemInfo.getProcessInfo")
  wrapDecode "SystemInfo.getProcessInfo":
    result = jsonTo(raw, GetProcessInfoResult)

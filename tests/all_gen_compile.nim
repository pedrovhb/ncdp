## Compile-acceptance harness for the entire generated corpus.
##
## Imports every module under ``src/cdp/gen/`` in a single file so
## one ``nim check`` walks the whole graph at once — faster than
## checking each module separately, and more accurate (it catches
## linker-style issues like duplicate symbol exports).
##
## This file is **regenerated** by ``tools/regen_all_gen_compile.nim``
## (or by hand, if you prefer; the format is mechanical). The list
## below is the only thing that ever changes.
##
## To run as a test:
##   nim check --hints:off tests/all_gen_compile.nim
##
## A clean exit means every domain compiles.

import cdp/gen/accessibility
import cdp/gen/animation
import cdp/gen/audits
import cdp/gen/autofill
import cdp/gen/background_service
import cdp/gen/bluetooth_emulation
import cdp/gen/browser
import cdp/gen/cache_storage
import cdp/gen/cast_domain
import cdp/gen/console
import cdp/gen/crash_report_context
import cdp/gen/css
import cdp/gen/debugger
import cdp/gen/device_access
import cdp/gen/device_orientation
import cdp/gen/dom
import cdp/gen/dom_debugger
import cdp/gen/dom_snapshot
import cdp/gen/dom_storage
import cdp/gen/emulation
import cdp/gen/event_breakpoints
import cdp/gen/extensions
import cdp/gen/fed_cm
import cdp/gen/fetch
import cdp/gen/file_system
import cdp/gen/headless_experimental
import cdp/gen/heap_profiler
import cdp/gen/indexed_db
import cdp/gen/input
import cdp/gen/inspector
import cdp/gen/io
import cdp/gen/layer_tree
import cdp/gen/log
import cdp/gen/media
import cdp/gen/memory
import cdp/gen/network
import cdp/gen/overlay
import cdp/gen/page
import cdp/gen/performance
import cdp/gen/performance_timeline
import cdp/gen/preload
import cdp/gen/profiler
import cdp/gen/pwa
import cdp/gen/runtime
import cdp/gen/schema
import cdp/gen/security
import cdp/gen/service_worker
import cdp/gen/smart_card_emulation
import cdp/gen/storage
import cdp/gen/system_info
import cdp/gen/target
import cdp/gen/tethering
import cdp/gen/tracing
import cdp/gen/web_audio
import cdp/gen/web_authn
import cdp/gen/web_mcp

# Assessment solutions

RES-101 through RES-107 have been implemented and validated as described
below. Part B F-1 is implemented with automated coverage and documented manual
smoke checks and DevTools captures. Smooth performance with 100+ visible
countdowns and real-app natural-expiry bag removal remain unverified manually.
F-2 and F-3 are not implemented.
Per-ticket test totals are historical checkpoints; the latest verified full
suite passed 56 tests on Flutter 3.27.0. Manual checks and limitations are
identified separately. The retrospective time estimate and remaining work are
summarized at the end.

## RES-101 — Search shows results for the wrong query

### Diagnosis and observed evidence

Every text change starts an asynchronous search. Previously every completed
request assigned its results and cleared loading, regardless of whether a newer
query had been entered. Awaiting one request does not serialize later calls to
the controller. The simulated backend intentionally takes longer for broad
queries, making out-of-order completion likely.

During the manual investigation, the console showed these completion times:

| Completion time | Query |
| --- | --- |
| 00:11:09.803 | sus |
| 00:11:09.838 | sush |
| 00:11:09.866 | sushu (manual typo) |
| 00:11:10.012 | s |
| 00:11:10.046 | su |
| 00:11:11.999 | sushi |

The intended final query was `sushi`. The intermediate `sushu` was my manual
typing mistake, not an application-generated value or evidence of the
stale-response bug. The original observed queries and timestamps are preserved
above. The stale-response diagnosis is supported by older requests completing
after newer ones and the deterministic regression tests described below.
A screenshot showed Thai deals under `sushi`, but the available log
and screenshot timing do not establish which response produced that frame.
Searching also matches store names and tags, so titles alone are insufficient
proof of a mismatch.

### Fix and alternatives

Each query change increments a request version, including clearing the input.
Only the current version can apply results or clear loading. Clearing input
immediately clears results, resets hasSearched, and stops loading. The finally
block is guarded too, because it executes even when a stale request returns
early from try/catch.

Debouncing alone was considered and rejected as the correctness mechanism:
it reduces requests but cannot prevent an already-running old request from
finishing after a newer one. Comparing query strings alone also fails when a
user enters the same query again. Request versions distinguish those requests.
No backend or package changes are needed. Old requests still finish; this fix
ignores their stale outcomes rather than cancelling backend work.

### Edge cases and limitations

- Old success or failure while the latest request is still loading.
- Clearing to empty or whitespace while a request is pending.
- Repeating the same query after clearing it.
- Latest failure followed by a successful retry.
- Existing latest-error handling remains console logging; no new error UI is
  included in this ticket. Existing results can remain after a latest failure.
- Controller disposal while a request is pending is not covered by this patch.

### Validation status

- Added deterministic controller tests using manually completed Futures:
  out-of-order results, stale success/error loading, clear during loading,
  repeated query, and recovery after failure.
- Verified before/after with Flutter 3.27.0 (framework 8495dee1fd, Dart 3.6.0)
  using `flutter test --no-pub` on 2026-09-08 (local time).
- Before: copied the project sources and the unchanged new tests into an
  isolated directory under `build/`, replacing only its search controller with
  `git show HEAD:lib/feature/search/search_deals_controller.dart`. Original HEAD:
  `e5ee445d11d07b216879880687991b6b57f0effe`. The active production file was
  never reverted. Five of the six new tests failed; recovery after failure
  and the existing model test passed (2 passed, 5 failed; exit code 1).
- The primary regression failed with `Expected: <2>, Actual: <1>` after the
  older response completed: direct evidence of stale results replacing the
  latest results. Other failures covered stale success/error loading,
  clearing during loading, and repeated queries.
- After: ran the same suite against the current working tree. All seven
  tests passed (six search tests plus the existing model test; exit code 0).
  The logged latest-request exception is deliberately injected by the recovery
  test and is not a suite failure.
- A later screenshot shows sushi deals for `sushi`. Repeated fast typing and
  clear-during-loading checks on the emulator were not recorded. No new manual
  emulator run was performed during this before/after validation.

## RES-102 — Crash after leaving My orders

### Reproduction and root cause

Manual reproduction procedure derived from the code: start a fresh app session,
open My orders from Home, wait until an Active order's countdown is visible,
then navigate back and wait 2–3 seconds after the route transition. The seed
contains active orders with pickup starts 18, 47 and 132 minutes after API
initialization. Leaving before data loads might not create a countdown and
therefore might not reproduce this crash. This manual procedure was not run
on the emulator during this ticket's validation.

The crash was reproduced deterministically in a widget test: mount
PickupCountdown, remove it from the tree before its first tick, then advance
test time by one second. Original code throws `setState() called after dispose()`
from the timer callback in `pickup_countdown.dart:22` and leaves a periodic
timer pending at test teardown.

The State created a periodic timer in initState but did not retain or cancel
it. Disposing the widget did not stop the timer; its closure continued to
reference the disposed State and invoke setState every second.

### Fix and rejected alternative

Keep the Timer in a `late final` State field, assign it in initState, and call
cancel in State.dispose before super.dispose. The widget owns this resource,
so it must release it when that particular State is removed. Cancellation
prevents both callbacks after disposal and the continuing periodic work.
No changes to the orders controller, backend, dependencies or toolchain are
needed.

A mounted guard alone was rejected: it can suppress setState after disposal,
but the timer would continue waking up and retaining its callback. The widget
test binding's pending-timer check also protects against that incomplete fix.

### Edge cases and known limitations

- Disposal before the first tick is explicitly tested.
- A second test verifies timer-triggered rebuilds while mounted and cleanup
  over two mount/dispose cycles, including disposal after a tick.
- Tests use simulated timer time and a fixed future pickupStart. The rebuild
  check compares the newly built Text widget, not elapsed countdown text:
  advancing widget-test time does not itself advance DateTime.now().
- Multiple simultaneous countdowns each own their own timer; this is not
  separately exercised by the current tests.
- The timer still runs while the pickup window is already open. Optimizing
  that existing behavior and exact countdown formatting are outside this fix.
- Exiting while the orders API call is pending is not the cause of this
  setState crash and is not changed here.
- These are isolated widget tests, not a full route/navigation or emulator
  integration test.

### Verification evidence

Verified on 2026-09-08 (local time) with Flutter 3.27.0, framework 8495dee1fd,
Dart 3.6.0.

- Before: copied sources and the new test into `build/res102_before_validation/`
  and replaced only that copy's countdown file with the version from HEAD
  `41d44607e29570fbebdc644c89aff16d0a82373b`. Ran
  `flutter test --no-pub test/pickup_countdown_test.dart`: 0 passed, 2 failed,
  exit code 1. Output included the disposed-State error and pending timer
  assertion. The working production file was not reverted.
- After: ran `flutter test --no-pub` against the working tree: all 9 tests
  passed, exit code 0 (2 countdown tests, 6 RES-101 tests, 1 model test).
- Production changes are restricted to timer ownership and cancellation in
  `lib/feature/order/widget/pickup_countdown.dart`.

## RES-103 — Requests pile up the longer you browse

### Reproduction

Manual procedure derived from the code: start a fresh session, open deal A
from Home, go back and wait for the transition to finish, repeat for B, then
open C and add one item so the cart count actually increases. Watch
`re-checking availability for deal ...` and `GET /deals/<id>` logs. Before the
fix, closed controllers for A and B still request availability alongside C.
Reopening the same deal repeatedly can also accumulate requests for one ID.
This procedure was not performed on the emulator during this validation;
the leak was reproduced deterministically with controller lifecycle tests.

### Root cause and resource ownership

Each DealDetailsController.onInit calls ever on the session-wide CartService's
itemCount. GetX's ever creates a stream subscription and returns a Worker that
can cancel it. The original controller discarded that Worker and had no
onClose cleanup. Deleting the controller from GetX did not cancel the external
subscription. Its callback retained the old controller and kept calling
_recheckAvailability, which calls DealRepo.fetchById for that controller's deal.

The subscription is owned by each DealDetailsController, while CartService
intentionally outlives the detail routes. Store the Worker in a nullable field
and dispose it in onClose before super.onClose. Nullable cleanup also tolerates
initialization ending before the Worker is created. This does not fix missing
route arguments; that separate issue was subsequently addressed in RES-107.

### Alternatives considered

- Debouncing or throttling does not release the stale subscriptions, so it
  would only reduce symptoms rather than fix ownership.
- Making CartService short-lived would change shared bag behavior and does
  not assign cleanup to the controller that created the subscription.
- Checking isClosed only inside the callback would suppress requests but
  leave the subscription registered. Worker.dispose removes the listener.
- Moving cleanup to a widget would split ownership unnecessarily; this
  Worker is created by the controller and belongs in its onClose.

### Edge cases and performance

- Tests cover closed controllers, active stock updates, reopening the same
  deal three times, and cart changes after all controllers are closed.
- Adds that hit the stock limit might not change itemCount; reproduction must
  use an actual count change. The tests also use clear after deletion.
- Cancellation prevents future subscription events, but does not cancel an
  already-started fetchById Future. Completion after closure, overlapping
  active requests and async error handling remain unchanged.
- A route covered by another route is not necessarily disposed; legitimately
  active controllers may still listen. Tests use Get.delete, not route pops.
- Before the fix, each count event fans out to historical controller instances;
  after it, fan-out is limited to controllers whose subscriptions remain active.
  Cancelling subscriptions removes their retained callback references. No
  heap snapshot, frame timing or memory reduction was measured, so no numeric
  memory/performance improvement is claimed.

### Verification evidence

Verified on 2026-09-08 (local time) with Flutter 3.27.0, framework 8495dee1fd,
Dart 3.6.0. Tests use real Get.put/Get.delete lifecycle and a shared real
CartService, with a recording DealRepo returning deterministic stock values.
Route arguments are supplied through Get.routing.args; no HTTP/API latency,
snackbar, or full screen navigation is involved.

- Before: ran `flutter test --no-pub test/deal_details_controller_test.dart`
  in `build/res103_before_validation/`, with the identical final test file and
  the controller restored only in that copy from HEAD
  `6cdec4502c11b6c1eb448e643065f828ecbc93ab`. Both tests failed (exit 1).
  Closed-controller case: expected requested IDs `[3]`, actual `[1, 2, 3]`.
  Reopen case on the second visit: expected `[42, 42]`, actual `[42, 42, 42]`.
- After: `flutter test --no-pub` in the working tree passed all 11 tests
  (2 RES-103, 2 RES-102, 6 RES-101, 1 model; exit 0). The active controller
  refreshed stock from 10 to 7, and clearing the cart after controller deletion
  produced no additional repository calls.
- Working production code was never reverted for the before run. Only the
  Worker field, assignment and onClose cleanup changed in production.

## RES-104 — Duplicate deals in the home feed

### Reproduction and root cause

Manual procedure derived from the ticket and code: load Home with Pickup today
off, trigger load-more at the bottom, then pull-to-refresh before that request
finishes. Load another page afterward and inspect IDs in Nearby deals (excluding
the separate flash rail). Backend latency makes this gesture sequence timing
dependent; no emulator reproduction was performed during this validation.

The deterministic reproduction holds page 2 in flight, completes refresh page 1
first, then completes the old page 2. The original controller appends that old
response without checking request ownership. Refresh has already reset _page to
1, so a subsequent load-more requests page 2 again. Data and the page counter
then disagree, producing repeated pages and potentially more entries than the
catalog contains. Conversely, an old response arriving before refresh finishes
can temporarily append and then be overwritten. The backend's skip/take logic
is not the source of duplicate data.

_isFetchingMore only prevented simultaneous load-more calls; it did not
coordinate refresh. An old failure could also execute _page-- against a newer
feed. Footer completion methods schedule post-frame callbacks, which can
overwrite a newer request's footer even after the earlier Future has finished.

### Fix and alternatives

HomeController now uses a monotonically increasing request version. Starting a
refresh invalidates older page requests, and starting each accepted load-more
also invalidates queued footer updates from the preceding request. This single
token covers the refresh generation boundary and completion ownership without
requiring separate feed and footer counters.

Only the current request can accept data/metadata, handle errors, clear flags
or update the footer. Load-more is blocked during refresh. _page begins at zero
(no accepted page) and changes only when a current response succeeds. Requests
use a local nextPage; no speculative increment or rollback is needed.

Refresh keeps the previous accepted data and pagination until success. Failure
retains that coherent snapshot, reports refreshFailed, and permits retry or
continued pagination. Successful refresh replaces the snapshot. The footer is
set to idle when more pages exist, or noMore otherwise, including after a
previous noMore state. Post-frame footer updates check their request version
at execution time. Closing the controller invalidates pending pagination work.

Rejected alternatives: deduplicating by ID after append would hide corrupted
pagination; resetting flags alone would leave stale callbacks able to mutate
state; ignoring refresh during load-more would discard the user's action;
waiting for old requests would delay refresh unnecessarily. No backend change,
package change, Home UI/Obx restructure or RES-105 optimization was included
in the RES-104 change; the later rendering work is documented under RES-105.

### Deterministic tests and verification evidence

Tests instantiate the real HomeController and use a controlled DealRepo with
Completers, explicit page metadata and distinct IDs for old/new snapshots.
They call pagination methods directly, rather than exercising initial flash
loading or mounting HomeScreen. The Flutter test binding explicitly schedules
frames to execute footer callbacks. Futures and frames are controlled; no
random delays or real-time sleeps are used.

Before validation used an isolated copy under `build/res104_before_validation/`
with HomeController replaced only in that copy by HEAD
`e22b8d5261763d8e97287bcd84640fb667917ec3`. The same final test file was used in
both runs; the working production file was not reverted.

- Before: `flutter test --no-pub test/home_controller_test.dart` produced
  10 failed / 1 passed, exit 1. Primary stale-page assertion expected
  `[10, 20]`, actual `[10, 20, 3, 4]`. Refresh from noMore expected an idle
  footer but remained noMore. A queued older completion changed a newer
  loading footer to idle. The empty-catalog case passed before the fix.
- After: all 11 HomeController tests passed. `flutter test --no-pub` then
  passed all 22 tests (11 RES-104 plus the existing 11), exit 0, using Flutter
  3.27.0, framework 8495dee1fd, Dart 3.6.0.
- Cases cover stale page completion before/after refresh, old success/error
  while a new load is pending, failed refresh preserving accepted pages,
  overlapping refreshes, blocked load-more during refresh, noMore reset,
  failed-page retry, deferred footer ownership, and an empty refreshed catalog.
- Injected refresh/page failures intentionally produce error logs. Those logs
  are not suite failures. No manual navigation, memory or frame-rate claim is
  inferred from the controller tests.

### Edge cases and limitations

- Old requests still finish; their results/errors are ignored, not cancelled.
- Repeated refreshes accept only the latest request's result. A latest refresh
  failure preserves the snapshot accepted before those requests.
- Footer state is deliberately updated after a frame, matching the package's
  completion timing. Tests verify stale callbacks cannot overwrite newer work.
- Pagination assumes the supplied backend's page/totalPages contract. This
  patch does not repair malformed metadata or an independently unstable remote
  catalog that moves items between offset-based pages.
- Pagination callbacks are guarded after close, but controller disposal is not
  separately tested here. Initial flash-load lifecycle behavior is unchanged.
- Gesture/indicator animation integration still needs manual emulator checking;
  these tests inspect RefreshController state without mounting SmartRefresher.
- Failed initial refresh now reports refresh failure locally and leaves zero
  accepted pages. Full initial-loading UX is not covered by this test suite.

## RES-105 — Home feed rebuilds and oversized decoded images

### BEFORE evidence (collected manually by the candidate)

Curated captures: [profile performance](docs/res105/RES-105_before_performance_profile.png),
[447 rebuilds](docs/res105/RES-105_before_rebuild_stats_447.png), and
[image cache at page 7](docs/res105/RES-105_before_image_cache_end_full.png).

The candidate supplied these real pre-RES-105 DevTools observations. Codex
did not collect these captures independently. Device, exact capture duration
and baseline revision were not recorded alongside the numeric summary,
limiting reproducibility of the timing comparison. The curated images show
endpoint cache values, final rebuild counts and representative FPS. Initial
rebuild counts, AFTER start-cache and heap samples also rely on the reported
manual observations; not every sample appears in these six images.

| Scenario | Start | After scrolling |
| --- | --- | --- |
| Debug Rebuild Stats: root Obx, Scaffold, SmartRefresher, AppBar and related widgets | approximately 143 builds | approximately 447 builds, increasing together |
| Debug imageCache.currentSize | 6 | 13 at page 7 / No more data |
| Debug imageCache.currentSizeBytes | 46,080,000 (reported 43.95 MB) | 99,840,000 (reported 95.21 MB) |
| Profile Dart memory | approximately 12.7 MB | approximately 12.9 MB at page 7 |
| Profile scrolling performance | frequent visible jank / slow frames | representative capture approximately 42 FPS average |

The cache's reported MB values correspond to binary MiB conversions. The
Dart memory observations do NOT show a ballooning Dart heap. No OS kill,
unbounded memory leak, exact frame-time distribution or measured improvement
is inferred from these samples.

### Root causes and causal chain

1. HomeController published the raw scroll offset on every scroll event.
   HomeScreen's root Obx read it as well as feed/filter/loading state, then
   recreated the entire Scaffold subtree. AppBar needs only offset > 4 and
   the top button needs only offset > 800. Rebuilding the feed for every
   intermediate offset also repeated visibleDeals filtering/list copying
   and recreated the flash section. The supplied correlated rebuild counts
   support this causal path; the new regression test also fails on the old
   Scaffold recreation.
2. FakeApiService supplies 1600 x 1200 catalog images. TheNetworkImage set
   layout width/height but no decode dimensions, so even small cards/rail
   images could cache full-resolution decoded pixels. At four bytes per
   pixel that is 7,680,000 bytes per image: exactly consistent with both
   supplied cache totals divided by image count. Unnecessarily large image
   decodes contribute memory and decode/upload work. This is not evidence
   that compressed disk-cache bytes or Dart heap grew by the same amount.
3. The vertical feed eagerly constructed the entire DealCard widget list via
   a spread/map on every rebuild; the work grew with loaded item count.
   ListView(children: ...) still mounts/layouts elements lazily, so this does
   NOT mean every card/image was simultaneously mounted/downloaded. This
   widget-construction overhead is code-supported; its separate FPS cost
   has not been measured.

The horizontal flash rail already uses ListView.builder. Home owns and
disposes its ScrollController/RefreshController; no additional subscription
leak was found here. Shimmer placeholders animate while images load, but no
capture isolates them as an additional root cause. Existing image caching
is bounded; approaching its budget alone does not establish a leak. Native/
external/total-process memory needs separate measurement from Dart memory.

### Fixes and rejected alternatives

Publish two boolean threshold states instead of raw offset. Scope their Obx
listeners to the AppBar and top button; keep Scaffold outside reactive
builders. The feed observes only loading/data/filter changes. GetX suppresses
unchanged boolean notifications. Pagination/request-generation logic from
RES-104 is unchanged.

Use ListView.builder for header/optional flash rail/cards/trailing spacing.
Snapshot reactive lists and filter state inside the body Obx, before the
deferred itemBuilder runs, so list/filter updates still register dependencies.
Cards have deal-ID keys and are created on demand. The refresh controller,
callbacks, loading placeholders and existing layout/content are preserved.

Use actual constrained image size and device pixel ratio to request a decoded
width via memCacheWidth. For this catalog's 4:3 source and BoxFit.cover,
width is ceil(max(boxWidth, boxHeight * 4/3) * DPR), capped at source width
1600. Set only width, preserving the decoded aspect ratio; the height term
avoids undersampling square thumbnails. Infinite layout dimensions are not
converted to integers. Without a usable bounded dimension the provider keeps
its original-size behavior. Original URLs, disk cache, fit and placeholders
are unchanged. The shared helper also sizes existing cart/order/detail
images consistently; those callers were not edited.

Rejected: clearing the image cache during scroll or reducing its global
budget (eviction/redecode churn rather than fixing oversized pixels); using
layout width alone (does not control decode size); forcing both decode
dimensions (can distort aspect ratio); using logical pixels without DPR
(blur); throttling whole-feed rebuilds (still unnecessary work); shrinkWrap
or mounting all cards; redesigning Home or changing backend image URLs.

### Automated verification

Flutter 3.27.0, no package upgrades, flutter test --no-pub:

- The 5 new focused widget tests all fail against an unmodified production
  archive of pre-RES-105 HEAD 77f584d0d76c1102c62daa9fb4bec44f800fb2f4,
  with only these test files added. Failures: new Scaffold on scroll,
  SliverChildListDelegate instead of builder, and absent decode-width hints.
  Temporary copy/log: build/res105_before_tests (not committed).
- After: all 5 focused tests pass (exit 0). They cover stable feed/root widget
  instances across scrolling, AppBar threshold updates, top button behavior,
  deferred children, filter/data/flash changes including empty lists, and
  image sizing for DPR/layout changes, square thumbnails, flash rail and
  the source-size cap.
- Full suite: all 46 tests pass (exit 0), including the prior pagination,
  lifecycle, date and deep-link tests. dart format on only the five RES-105
  Dart files reports 0 further changes.
- Image tests inspect provider configuration; they do not download images,
  measure actual decode allocations, or establish FPS/memory improvements.

### AFTER DevTools evidence (collected manually by the candidate)

Curated captures: [profile performance](docs/res105/RES-105_after_performance_profile.png),
[rebuild stats](docs/res105/RES-105_after_rebuild_stats.png), and
[image cache at page 7](docs/res105/RES-105_after_image_cache_end.png).

The candidate subsequently supplied real AFTER observations for the same
scrolling scenario, following implementation commit
f162df5255fece9819c01be69b6676d37ba5b603. These are reported manual captures,
not measurements generated by Codex or a deterministic performance benchmark.

| Metric | AFTER start | AFTER end / capture |
| --- | --- | --- |
| Debug Rebuild Stats | not separately supplied | Scaffold 1; main feed Obx 7; SmartRefresher 7; AppBar 2 |
| Debug imageCache.currentSize | 7 | 22 at page 7 / No more data |
| Debug imageCache.currentSizeBytes | 17,998,848 (reported 17.17 MB) | 102,795,264 (reported 98.03 MB) |
| Profile memory | Total approximately 13.9 MB / Dart heap 13.8 MB | Total approximately 13.9 MB / Dart heap 13.8 MB |
| Profile representative average FPS | not separately supplied | approximately 55 FPS |

Root/feed rebuilds no longer rise into the hundreds during this scenario.
Seven feed/refresher builds are consistent with data-driven pagination,
rather than per-scroll-offset rebuilding. Representative FPS increased from
approximately 42 to 55; timing, image/network/cache state and device load can
affect individual captures, so this is directional evidence, not a guaranteed
percentage speedup or proof that all slow frames are gone. AFTER Dart heap
was stable within its run. Do not compare absolute heaps across separate runs
as if they were a controlled allocation benchmark. The supplied "Total"
label is not assumed to mean total Android process memory.

### Image-cache audit and completion assessment

Read the pinned Flutter 3.27.0 source in
packages/flutter/lib/src/painting/image_cache.dart: default maximumSize is
1000 entries and maximumSizeBytes is 100 << 20 = 104,857,600 bytes (100 MiB).
ImageCache._touch accounts for a completed entry and _checkCacheSize evicts
least-recently-used entries while either budget is exceeded. Eviction is by
whole entry, so occupancy need not equal the budget exactly. No app override
of these limits was found. The actual runtime limit was not supplied as a
manual measurement; the default and absence of app overrides were verified
in source.

END bytes did NOT decrease: 99,840,000 BEFORE versus 102,795,264 AFTER.
Both are below the default budget. Smaller decodes allow more entries to
fit: 13 BEFORE versus 22 AFTER. The end-snapshot arithmetic mean per cached
entry is 7,680,000 bytes BEFORE versus 4,672,512 bytes AFTER. This is an
aggregate comparison with different entry mixes, not a same-image paired
measurement. START bytes were lower (46,080,000 versus 17,998,848), despite
7 rather than 6 entries. These results support smaller per-entry storage and
expected budget filling, not a reduction in total end-cache occupancy or a
claim that all image-memory growth is fixed.

Also traced installed cached_network_image 3.4.1 through OctoImage 2.1.0 to
ResizeImage.resizeIfNeeded. The width hint reaches the decoder; ResizeImageKey
includes provider key and resize dimensions. A feed image and its smaller
flash-rail variant can legitimately occupy separate entries. Current sizing
uses layout constraints and DPR, preserves the 4:3 source ratio using only
one decode dimension, and caps width at 1600. Fixed layout/DPR gives stable
keys; there is no scroll-offset-dependent image size in the feed. Runtime
per-image decoded dimensions/DPR were not included in the manual evidence,
so no particular device image dimensions are asserted here.

currentSizeBytes accounts for keepAlive cache entries, not all resident image
memory. Live images can overlap that cache, or remain referenced after LRU
eviction; pending decodes and native/GPU memory are not bounded by this single
number. The supplied data therefore does not prove the absence of every
possible native-memory issue or reproduce/resolve an OS kill. No additional
avoidable retention/decode root cause was found in this audit. Lowering the
global budget only to make the endpoint smaller is not warranted; it could
increase eviction/redecode work and would not release images still in use.
A lower budget can be a legitimate separately measured low-memory-device
policy, but is not a substitute for appropriate decode sizing.

Assessment: the diagnosed RES-105 causes and required before/after evidence
are addressed; no further production change is justified by these samples.
No additional measurement is required to explain this endpoint. Optional
confidence check: record runtime maximumSizeBytes, decoded dimensions/DPR,
liveImageCount/pendingImageCount and native/process memory across repeated
scroll cycles. Investigate further if live references or process memory keep
growing after returning to the same viewport with pending loads settled.

### Edge cases and process

Automated coverage does not establish visual quality on every orientation or
high-DPR screen, or all refresh/load-more animations and detail/cart images.
The sizing contract assumes existing 1600 x 1200
catalog photos; arbitrary future aspect ratios need source metadata or a
revised sizing policy. A high-density/large viewport can still require the
full source image. Features/countdowns and backend behavior are unchanged.

The implementation and evidence were committed separately: the code was
validated automatically first, and the manual AFTER captures were documented
when available. No additional production change was justified by the cache
endpoint measurements.

## RES-106 — Pickup times and Pickup today

### Root cause and reproduction

The API sends correct UTC instants. DateTime.parse preserves that timezone,
but the original label formatted UTC hour fields directly. For the supplied
market (Asia/Bangkok, UTC+7), 23:00Z–02:30Z must display 06:00–09:30. The
original isToday compared only start.day with DateTime.now().day, mixing UTC
and device-local calendar fields and ignoring month/year. Early morning pickup
can start on the previous UTC date; equal day numbers in different months or
years can also be incorrectly accepted.

### Fix and alternatives

Keep the original start/end instants unchanged. Convert UTC fields to the
catalog's market wall time only for display and calendar comparisons. Compare
year, month and day in the same market timezone. isToday delegates to
isTodayAt(DateTime.now()); the explicit-instant method is a deterministic test
seam and is also used by the parsed-deal filter test.

Device toLocal() was rejected because a traveller's device timezone must not
change the store's pickup hours. The backend explicitly documents this catalog
as Asia/Bangkok (UTC+7 with no DST); a timezone database is unnecessary for this
contract. Changing the stored instants or offsetting duration comparisons
would corrupt actual time semantics. No backend, assets or package changes.

### Verification evidence

Flutter 3.27.0 / framework 8495dee1fd / Dart 3.6.0 were used. Java was checked
as Temurin 17.0.20.1. Baseline source commit:
bd5f0d4a992d721db82b03fa690d0e5379964416.

- Original model in build/res106_before_validation: all 3 label tests failed
  (exit 1), including expected `06:00 – 09:30`, actual `23:00 – 02:30`.
- For deterministic before-date validation ONLY, the baseline copy received
  isTodayAt(now) returning the exact old expression start.day == now.day.
  This supplies a fixed clock input without correcting the comparison. It is
  a test adapter, not an unmodified-original-model run. The 6 date tests then
  yielded 5 failures / 1 pass (exit 1), including the parsed-deal filter
  expecting ID 1 but selecting ID 2.
- After: all 31 tests passed with flutter test --no-pub (exit 0): 9 new
  pickup-window tests plus the previous 22. The tests use fixed UTC instants
  and explicit ISO offsets, independent of host timezone/current wall clock.
- Tests cover early mornings, exact market midnight, overnight labels, month/
  year differences, new year, leap day, equivalent offsets, and parsing deals
  before applying the same date predicate that the Home getter delegates to.
- Test formatting changed whitespace only after the baseline runs. No emulator
  reproduction or performance measurement is claimed.

### Limitations

The tests exercise model/parsed-deal filtering, not the actual Home filter
gesture. Design Q3 below explains the clock seam and boundary cases.

Today retains the existing documented meaning "pickup starts today", not any
overlap with today. isOpenNow/untilStart still compare original instants and
are unchanged. Multiple market timezones/DST would require a store timezone
contract and a different conversion strategy. No automatic midnight refresh
of an already visible UI is added. Invalid ISO input handling is unchanged.

The pre-RES-105 source was preserved under build/res105_baseline_bd5f0d4
before this time-formatting change, keeping a separate performance baseline.

## RES-107 — Deep link opens to a crash

### Reproduction and root cause

Home's Simulate deep link dialog converts
`rescu://open/deal?id=42&source=push` to `/deal?id=42&source=push` and
calls Get.toNamed without arguments. Home deal cards pass a DealModel.
Both paths reach the same route, binding and DealDetailsController, whose
original onInit blindly casts Get.arguments to DealModel. The null cast
crashes before a deep-linked deal can load. DealRepo.fetchById already
supports ID lookup; catalog ID 42 exists. Neither backend nor data need changes.

### Fix, ownership and alternatives

The route controller snapshots ID/source, uses a matching supplied model
immediately, or loads the ID through DealRepo. The screen waits for that model
before building the existing full details UI, including Add to bag. It does
not substitute an error screen for a successfully fetched valid deal.
Missing/nonpositive/noninteger IDs show an invalid-link message without a
request. A failed fetch shows an explicit retry action; concurrent retries
are prevented. A mismatched argument cannot override the route's explicit ID.

The controller owns loading and the cart Worker. Initialization of stock,
view analytics and Worker happens only after obtaining the model. A response
arriving after onClose cannot create a late subscription. The RES-103
onClose Worker disposal is preserved, as are its existing regression tests.
The loading guard protects this new async lifecycle; it does not replace
fetching the missing data. The repository Future itself is not cancellable.

Rejected: catching the null-cast exception and leaving a fallback screen;
fabricating a partial model from ID would leave required content/actions
without their data; push callers cannot supply an existing in-memory model;
fetching again when Home already supplied the matching deal adds unnecessary
latency. Loading through the repository handles both entry paths.
No Home UI, route declarations, bindings or backend changes were needed.

### Verified evidence

- Baseline: archive of commit 2906a854ffb74b64ddc8a917f80cd1d4bc4a37a7
  under build/res107_before_validation/source, with the new test copied in.
  Production files in that copy were unmodified HEAD versions.
- Final focused tests against that baseline: 9 failed / 1 passed (exit 1).
  The valid no-argument route reproduced the null-to-DealModel cast error;
  normal Home argument navigation passed. No baseline production adapter
  was required for this ticket.
- At RES-107 verification: all 10 focused widget tests passed (exit 0).
- At that checkpoint: all 41 tests passed with Flutter 3.27.0 using
  flutter test --no-pub (exit 0), including the RES-103 lifecycle tests.
- Tests use controlled repository Completers, the actual deal route/binding/
  screen and real CartService. They verify ID 42 content, stock, pickup label,
  source analytics, Add to bag, immediate Home navigation, full rescu URI as
  an initial named route, invalid IDs, failure/retry, leaving during fetch,
  and mismatched arguments. The successful cart action triggers one stock
  recheck for the active deal.
- dart format on the three changed Dart files reported 0 further changes.

### Limitations

These are deterministic widget tests, not a physical Android push/ADB
end-to-end run. They substitute a controlled repository and do not validate
image downloads or real network transport. Android manifest deep-link intent
configuration was inspected; device dispatch still merits a manual smoke
test. The existing post-add availability-request error handling is unchanged.
An unknown positive ID uses the same retryable load-error UI as other fetch
failures. Multiple simultaneous detail routes of the same controller type
remain outside this ticket's scope.

## F-1 — Live flash-sale countdowns

### Design and correctness

The model already supplies an expiry instant, but the rail displayed static
text and the local bag had no expiry check. `FlashSaleClock`, owned by the
session-wide CartService, supplies one shared one-second timer and an
injectable `now` function. Labels use deadline minus current time, rounded up
to the next second: `mm:ss` below an hour, `hh:mm:ss` from one hour, and
`Expired` at or after the deadline. Comparing instants leaves RES-106's Bangkok
calendar/pickup formatting and stored timestamps unchanged.

The rail, shared feed/search card and details use the same countdown widget.
Expired cards are dimmed and ignore pointer/focus actions; the details Add
button is disabled. CartService also checks actual time on every add, so a
tap between ticks cannot bypass expiry. The details controller only shows
its success snackbar if the add succeeds.

The bag subscribes while it contains flash deals, independently of mounted
cards. Expiry removes all quantities of expired lines in one batch, recounts
totals and shows a snackbar naming the removed deals. Non-flash lines remain.
Checkout checks again before sending; if it removes expired lines, it stops
so the user can review the changed bag before trying again.

### Performance and lifecycle

Only each countdown's ListenableBuilder/Text rebuilds per second. The expiry
wrapper observes the clock but calls setState only when its expired boolean
changes; its prebuilt card child is reused. At expiry the small wrapper or
details button changes once. Home's list, scroll reactivity, image sizing and
pagination are unchanged. Tick work scales with mounted listeners and bag
lines, not all catalog entries; there is one periodic timer, not one per card.

Widgets remove listeners on dispose and replace subscriptions when deadlines
change. The clock stops after the last listener is removed, including removal
inside a notification, and releases its timer/lifecycle observer with its
owner. It pauses on background `paused`/`detached` and checks actual time on
resume, so missed ticks do not extend a sale. An injected clock remains owned
by its caller and must be disposed there.

### Rejected alternatives

- A Timer per card duplicates scheduling and cleanup; one timer serves both
  countdowns and offscreen bag expiry.
- A clock-dependent Obx around cards or Home repeats RES-105's broad rebuild
  problem. Text listens separately from the one-time expiry transition.
- Widget-only expiry callbacks miss bag items after navigation. CartService
  owns bag validity, and add-time validation closes the gap between ticks.
- Decrementing a seconds counter drifts across delayed ticks/backgrounding.
  Subtracting absolute instants gives the current remaining duration instead.

### Verified automated evidence

On Flutter 3.27.0, `flutter test --no-pub test/flash_sale_test.dart` passed all
10 tests; `flutter test --no-pub` passed all 56 tests (46 existing plus 10 F-1).
Coverage includes formatting boundaries, fractional seconds and UTC offsets;
batch/offscreen bag removal; between-tick add and checkout rejection;
mixed-bag checkout review; resume/disposal; deadline replacement; and the
real details disabled button and visible snackbar.

With 120 mounted countdowns, text changes while measured parent and expiry
builder counts remain unchanged before expiry. Expiry updates wrappers once.
Real rail/feed Card widget instances and the details Scaffold are reused
across ticks. Unmounting releases listeners, and the test framework detects
leftover timers. The manual stress target is also mounted in a widget test
to check all 120 countdowns render and clean up.

These are implementation tests, not a claimed pre-F-1 before/after benchmark.
Formatting is limited to touched Dart files. Diff/constraint review checks
backend/data, dependencies and toolchain remain unchanged.

### Manual functional smoke checks

Manual checks in the normal app, in profile mode, confirmed countdowns in
the flash rail, home-feed card and details screen, and successful Add to bag
before expiry. The [bag screenshot](docs/f1/F-1_bag_before_expiry.png) shows
Mystery Thai Feast with quantity 1 and a total of ฿150; it does not prove
expiry removal or independently capture every preceding navigation step.
Rail/feed visibility is a reported manual observation, not a separate image
in this curated set.

The same details countdown reads [22:01 before background](docs/f1/F-1_before_background.png)
and [21:34 after resume](docs/f1/F-1_after_resume.png). Together with the
reported background/resume sequence, this supports accounting for elapsed
real time rather than freezing the remaining duration. It is not a measured
resume-latency benchmark or evidence of crossing expiry while backgrounded.

In the reported manual check, the normal app was left running until flash-sale
countdowns expired. The [real-app natural-expiry screenshot](docs/f1/F-1_real_app_natural_expiry_state.png)
shows dimmed flash-sale cards labeled `Expired` and a dimmed nearby-feed deal
card also labeled `Expired`. The image records the resulting visual state;
the elapsed wait is the reported manual observation. It does not demonstrate
bag removal/notice or smooth performance with 100+ countdowns.

Real-app bag removal and its notice at natural expiry were **not** separately
observed. Those behaviors have automated coverage above and remain manually
unverified.

### DevTools and profile evidence

**Synthetic stress fixture.**

The stress target is `test/support/flash_sale_profile.dart`, with 120 mounted
countdowns. The supplied [debug rebuild-stats capture](docs/f1/F-1_debug_rebuild_stats_30s.png)
shows overall counts of 1 for GetMaterialApp, FlashSaleProfile, Scaffold and
AppBar, supporting the reported observation that root/container widgets did
not rebuild every second. FlashSaleCountdown totals 120 and FlashSaleExpiry
totals 240 across instances; these are aggregate widget counts, not 120 or
240 builds per individual countdown. The capture is debug-mode evidence of
rebuild scope, not release/profile performance.

The [profile overview](docs/f1/F-1_profile_performance_overview.png) still
contains frequent slow frames. A [representative frame detail](docs/f1/F-1_profile_raster_jank_detail.png)
reports Build 1.4 ms and Raster 59.6 ms, with "Raster Jank Detected". These
values describe that selected frame only. Scoped rebuilds therefore do not
establish smooth raster performance, and the screenshots do not identify
the underlying raster bottleneck or establish a repeatable FPS benchmark.

Additional selected frames show [frame 484](docs/f1/F-1_profile_slow_frame_484.png)
with Build 0.3 ms / Raster 56.5 ms and [frame 501](docs/f1/F-1_profile_slow_frame_501.png)
with Build 0.2 ms / Raster 64.0 ms. These captures show sustained raster-side
jank despite low build times in the selected frames. They do not establish
that the production countdown design causes the same pattern in normal use.

All 120 labels reached [Expired in the stress fixture](docs/f1/F-1_profile_expired_state.png).
The [mass-expiry performance capture](docs/f1/F-1_profile_mass_expiry_performance.png)
still shows slow frames; it is not evidence that simultaneous expiry is
jank-free. The compact fixture uses fitted text and no feed photos, so it
does not substitute for a real-feed scrolling profile. RES-105 measurements
remain historical Part A evidence and are not reused as F-1 results.

**Real-app profile captures.**

The [idle/home capture](docs/f1/F-1_real_app_profile_idle.png) displays about
57 FPS average. The [normal-scrolling capture](docs/f1/F-1_real_app_profile_scroll.png)
displays 52 FPS; the reported scrolling observations were approximately
52–53 FPS. The [real-app slow-frame capture](docs/f1/F-1_real_app_slow_frame.png)
displays 53 FPS and flags frame 1494 as raster jank, but its detailed raster
duration is unavailable. Occasional slow frames remain, without the sustained
all-red raster pattern visible in the supplied synthetic-fixture captures.
These are representative manual captures, not deterministic benchmarks,
guarantees of 60 FPS, or evidence of jank-free behavior.

**What the evidence establishes.**

Automated tests and debug rebuild stats support tightly scoped widget
rebuilds with 120 countdowns. The selected profile frames show low build
cost relative to raster cost, and the synthetic fixture exhibits a much
heavier raster burden than the supplied normal-app captures. This comparison
does not isolate the underlying cause: fitted text, simultaneous updates,
rendering setup and other differences have not been measured independently.
No production fix is justified by these screenshots alone.

### Remaining limitations

Functional implementation and automated checks pass, but the brief's smooth
100+ countdown performance requirement is **not established** by these
captures. Normal-app results are encouraging but do not demonstrate that
100+ countdowns were simultaneously visible during those runs. The rebuild
requirement has supporting evidence; smoothness at that load remains qualified.
Follow-up should investigate raster cost under a documented device/setup and
repeat comparable 100+ countdown measurements. Neither the stress fixture
alone proves normal production performance is bad, nor the normal-app FPS
captures prove the 100+ countdown smoothness requirement is satisfied.
Natural-expiry bag removal/notice, including expiry while backgrounded,
still needs a normal-app manual check. A manual over-one-hour display check
was not reported; its formatting boundaries are covered by automated tests.
Do not restart mid-expiry scenario: the fake backend creates relative sale
deadlines at init.

UI expiry can lag the deadline until the next one-second tick (longer if the
UI isolate is blocked); add and checkout validate immediately. Device time
is not a trusted server offset; anti-tampering and persisted bags are outside
scope. Expired-only mounted widgets can keep the single clock active until
unmounted. Very long labels, large text settings and real lifecycle transitions
merit device checks. An already-submitted checkout cannot be recalled by this
client; the backend result remains authoritative. Reservation rollback is F-3.

## AI usage log

I used Codex to inspect unfamiliar code, form hypotheses, propose focused
regression tests and minimal fixes, review diffs, and help document findings.
I initially edited the search controller in VS Code, then authorized Codex to
implement and commit ticket-scoped work. Each ticket was reviewed separately.

The working pattern was: read the problem, reproduce or define a reliable
reproduction, inspect the causal path, build a regression test, apply the
smallest fix, run focused and full tests, review the diff and constraints,
then commit. Some tests were written after implementation and run against an
isolated pre-fix version; the per-ticket evidence records those comparisons
rather than claiming a strict test-first sequence throughout.

AI output was checked against compiler errors, test failures, runtime logs,
source code and repository diffs. Flutter 3.27.0/Dart supplied test and format
results; Git preserved baseline versions and ticket history. For RES-105,
I collected BEFORE/AFTER DevTools measurements and screenshots manually.
Codex interpreted them alongside the source; automated tests alone were not
used to claim performance improvements. The cache endpoint increased, and
that result is retained in the diagnosis.

Two concrete AI mistakes illustrate the validation process:

1. **RES-103 — awaiting a void API.** Codex generated `await Get.reset()`.
   The compiler rejected it because Get.reset returns void in the installed
   GetX version. Codex removed await and ran the corrected tests against both
   original and fixed production code. This compile error was not evidence
   of the production subscription leak.
2. **RES-104 — an incomplete frame-pumping harness.** Codex's controller-only
   tests used pump without scheduling a frame when no screen was mounted.
   Three footer assertions failed because post-frame callbacks had not run.
   Codex added `tester.binding.scheduleFrame()` before pumping and revalidated
   the same corrected tests before/after. The production code was not changed
   to satisfy an incorrect harness.

These mistakes were surfaced by compiler/tests and corrected by Codex, not
independently discovered by me. They were not deliberately introduced. Test
failures against the original production bugs are reported separately.

During F-1, a new test exposed a lifecycle mistake in Codex's initial clock:
checking ChangeNotifier.hasListeners while removing the last listener inside
notification left the timer running because the notifier defers updating its
count. Codex tracked registrations explicitly; the same offscreen-expiry test
then passed without a leftover timer. An incomplete pickup-window fixture and
snackbar test pumping were also corrected in the harness, not treated as
production failures.

## Design questions

**Q1 — Controller versus widget lifecycle.** GetX manages controller
initialization and onClose according to DI/route configuration. Flutter
creates and disposes each widget State with its element. One controller can
serve several States, and a child can disappear while its controller remains.
In RES-102, PickupCountdown's State created the timer, so State.dispose must
cancel it; OrdersController.onClose is not its owner. In RES-103, the controller
created the cart Worker, so onClose must dispose it. Neither lifecycle
automatically cancels externally registered callbacks: cleanup follows ownership.

**Q2 — Scope of Obx.** A large Obx hurts when a frequently changing value
affects only a small part of its subtree. RES-105 rebuilt the feed on every
scroll-offset change just to update elevation or the top button. Separate
those observers and publish boolean thresholds; let the feed observe its
data/loading/filter state. Read reactive lists inside Obx before a deferred
itemBuilder so dependencies are registered. Scope by what changes together,
then verify rebuild counts and profile timings; more observers are not
automatically better.

**Q3 — Catching RES-106 before release.** Parse fixed UTC API fixtures and
assert Bangkok labels and full year/month/day comparisons at an explicit
current instant. For example, 2026-01-01T23:00Z–2026-01-02T02:30Z must display
06:00–09:30. Test both sides of 17:00Z (Bangkok midnight), month/year boundaries
and matching day numbers in different months. Extracting isTodayAt(now) makes
these tests independent of host timezone and wall clock; isToday remains a
thin DateTime.now() wrapper. Stored instants stay unchanged. Existing tests
cover model/parsed-deal filtering; actual Home filter interaction with a
controlled clock would be an additional UI test.

## Time spent and next steps

I did not track time continuously. These are retrospective rough estimates
of active work, excluding breaks and waiting time, rather than exact logged
durations. Profiling and documentation are listed separately from debugging
and tests to avoid double counting. The total is an overall retrospective
estimate, not an exact sum of the category range endpoints.

| Activity | Approximate active time |
| --- | --- |
| Setup / reading the brief / getting the app running | About 1–2 hours |
| RES-101 through RES-107, including debugging and tests | About 6–8 hours |
| RES-105 DevTools profiling, measurements and screenshots | About 2–3 hours |
| Documentation / solutions.md / final review before F-1 | About 1–2 hours |
| Previous estimate: Part A / RES-105 profiling / Part C before F-1 | Approximately 12–14 hours |
| F-1 implementation, automated tests and review | About 1.5–2 hours |
| F-1 manual profiling, screenshots and performance investigation | About 1.5–2 hours |
| Additional F-1 documentation / final evidence review | About 0.5–1 hour |
| Additional F-1 work, rounded retrospective estimate | Roughly 3–5 hours |
| Revised overall retrospective estimate | Approximately 15–19 active hours |

The previous 12–14 hour estimate covered Part A, RES-105 profiling and Part C
before F-1. F-1 added roughly 3–5 active hours, giving a revised overall estimate
of approximately 15–19 active hours. The F-1 subtotal is rounded; these ranges
are retrospective estimates, not exact logs, and exclude breaks and waiting.

With one more day, I would first finish F-1's device and profile validation,
including simultaneous countdowns, expiry notices and background/resume, and
smoke-test deep links, search, orders and refresh/load-more. I would then inspect
live images and native/process memory across repeated scrolling cycles and
address failures before starting another feature. F-2 and F-3 remain
unimplemented; automated coverage alone does not finish F-1's performance gate.

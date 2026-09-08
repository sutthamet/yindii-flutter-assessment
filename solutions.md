# Assessment notes — work in progress

Only RES-101 has been worked on so far. This document is not yet a complete
submission. Automated RES-101 validation is complete; final written
deliverables and candidate review remain pending.

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
| 00:11:09.866 | sushu |
| 00:11:10.012 | s |
| 00:11:10.046 | su |
| 00:11:11.999 | sushi |

These logs demonstrate older requests completing after newer ones. The last
query was corrected from `sushu` to `sushi`; these are the actual observed
queries. A screenshot showed Thai deals under `sushi`, but the available log
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
  clear-during-loading checks on the emulator are still pending. No new manual
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

### Q1 relevance

OrdersController uses GetX's onInit to load data; GetX manages its onClose when
the route-associated dependency is deleted. PickupCountdown is a separate
StatefulWidget whose State is initialized and disposed by Flutter's widget
tree. A single controller can serve several countdown States, and a State can
be removed independently of the controller. Controller deletion does not
automatically cancel timers created by child widgets. RES-102 demonstrates
why resources must be cleaned up in their owner's lifecycle: this timer belongs
in State.dispose, not OrdersController.onClose.

### Process note

Codex implemented the approved minimal fix, wrote the widget tests, ran the
before/after checks, and drafted this RES-102 section. Candidate review and an
honest time estimate remain pending. Earlier overview/next-step notes above
are retained from the RES-101 checkpoint; this section records the subsequent
RES-102 work without revising unrelated sections.

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
route arguments (RES-107).

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

### Q1 relevance

RES-103 complements RES-102: the countdown timer belongs to Widget State and
is cancelled in dispose, whereas this Worker belongs to GetxController and
is disposed in onClose. Neither widget removal nor deleting a controller
automatically cancels every externally registered subscription. Cleanup must
follow the resource owner's lifecycle.

### Process and AI correction

Codex implemented the approved fix, tests and this section. Its first test
draft incorrectly used `await Get.reset()`; compilation reported that the
expression has type void. Codex removed await and reran the identical corrected
tests before/after. That compilation failure is not counted as proof of the
production bug. This is an actual AI error caught by the compiler and corrected
by Codex, not a claim that the candidate independently caught it. Candidate
review and the actual time estimate remain pending. Earlier document sections
are retained as prior checkpoints, per the RES-103-only documentation scope.

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
package change, Home UI/Obx restructure or RES-105 optimization is included.

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

### Design question relevance and process

Q2: Home's broad Obx scope is relevant to RES-105, not the cause of this race;
it is unchanged. Q3: controlled dependencies make asynchronous tests repeatable,
but these pagination tests do not answer the RES-106 time-zone question.

Codex implemented the approved HomeController change and tests, ran the
before/after validation, and wrote this section. Its first test harness used
pump without requesting a frame while no screen was mounted, so three footer
assertions did not observe scheduled callbacks. Codex corrected the harness to
request frames, then used that corrected file for both before/after runs. This
was a test-harness error caught during execution, not proof of a production
failure or a claim of independent candidate discovery. Candidate review and
an honest time estimate remain pending. Other document sections are retained
as earlier checkpoints under the RES-104-only documentation scope.

## AI usage log

Used Codex to explain architecture, interpret logs, propose request-version
guards, inspect the local diff, draft deterministic tests, and draft these
notes. The candidate applied the initial controller changes manually in VS
Code. Codex subsequently created the test file and this draft, then ran the
authorized before/after validation and updated the evidence. The candidate
must review and explain the submitted code.

Two verified examples of wrong or misleading AI advice, including how the
candidate caught each and what was done instead, still need to be reviewed
and recorded from the actual conversation. Do not invent examples to meet
the requirement. Accidental typing into the Flutter SDK is not, by itself,
an incorrect AI code suggestion.

## Design questions

Q1, Q2 and Q3: pending code investigation and candidate discussion. These
answers are required before submission.

## Time spent and next steps

- Setup time: pending the candidate's honest estimate.
- RES-101 investigation, implementation and verification time: pending the
  candidate's honest estimate. Screenshot clock times do not establish active
  working duration.
- Next: review validation findings with the candidate, complete the
  RES-101 notes, then prepare one logical commit with the `[RES-101]` prefix.
- With one more day: provisional priority is lifecycle bug investigation and
  regression coverage; revisit this answer at submission time.

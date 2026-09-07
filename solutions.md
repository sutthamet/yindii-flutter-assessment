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

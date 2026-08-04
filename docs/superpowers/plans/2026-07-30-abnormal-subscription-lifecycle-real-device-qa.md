# Abnormal Subscription Lifecycle Real-Device QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify PaymentKit converges safely through billing failures, refund revocation, account and Family Sharing changes, multiple devices, adverse networks, and clean reinstall without manual diagnostic refresh or duplicate delivery.

**Architecture:** Use deterministic `StoreKitTest` cases first to validate state mapping, then run real Sandbox scenarios on physical devices against App Store infrastructure. Preserve one active shareable subscription until account, family, multi-device, offline, and reinstall checks finish; run destructive refund revocation last. Record every real-device result with an `.xcresult`, screenshot, or explicit state/count observation.

**Tech Stack:** Swift 6.2, StoreKit 2, StoreKitTest, XCTest/XCUIAutomation, App Store Sandbox, iPhone SE, paired iPhone 12 Pro Max.

## Global Constraints

- Use the `Examples Sandbox` scheme for App Store Sandbox and `Examples Local` only for deterministic StoreKitTest.
- Never call `AppStore.sync()` automatically; only the user-visible “恢复购买” action may call it.
- Do not click the diagnostic refresh button during automatic-convergence acceptance checks.
- Current entitlement and automatic renewal are separate: cancellation must not remove access before expiration.
- Every accepted transaction state must finish only after the mock backend records it durably.
- A repeated signed event may increase audit count, but the same business state must not produce a second business delivery.
- Do not record JWS payloads, account credentials, full transaction identifiers, or Apple authentication text.
- Use account aliases in evidence: A is the current purchaser, B is a second existing tester, and C is a dedicated fresh billing-failure tester.
- Preserve A’s active shareable subscription until Tasks 2–6 complete; run approved refund revocation in Task 8.
- No Git commit or push is part of this QA run unless the user asks for one.

---

### Task 1: Deterministic Abnormal-State Mapping

**Files:**
- Verify: `Examples/ExamplesTests/ExamplesTests.swift`
- Verify: `Sources/PaymentKit/PaymentStoreGateway.swift`
- Verify: `Sources/PaymentKit/PaymentClient.swift`
- Evidence:
  - `/private/tmp/PaymentKit-Abnormal-Lifecycle-Local-20260730.xcresult`
  - `/private/tmp/PaymentKit-Abnormal-Network-Retry-20260730.xcresult`

**Interfaces:**
- Consumes: `PaymentRenewalState`, `PaymentRenewalInfo`, `Transaction.updates`, SQLite outbox.
- Produces: a deterministic baseline proving billing retry/grace mapping, refund redelivery, and network-error behavior before Sandbox timing is involved.

- [x] **Step 1: Run the billing retry and grace-period StoreKitTest**

```sh
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan 'Examples Local' \
  -destination 'id=00008030-001E69322223802E' \
  -resultBundlePath /private/tmp/PaymentKit-Abnormal-Lifecycle-Local.xcresult \
  -only-testing:'ExamplesTests/PaymentKitStoreKitTests/observesBillingRetryAndGracePeriod()' \
  test
```

Expected: the subscription status becomes `.inGracePeriod` or `.inBillingRetryPeriod`.

- [x] **Step 2: Run deterministic refund and StoreKit network-failure tests**

```sh
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan 'Examples Local' \
  -destination 'id=00008030-001E69322223802E' \
  -only-testing:'ExamplesTests/PaymentKitStoreKitTests/processesRefundRevocation()' \
  -only-testing:'ExamplesTests/PaymentKitStoreKitTests/mapsSimulatedLoadProductsError()' \
  test
```

Expected: a refund with the same transaction ID but a newer signed state is delivered once as a new business state; a network failure maps to `.storeKitFailed` without sensitive text.

Result (2026-07-30, iPhone SE): billing retry/grace and refund revocation
passed. The network test first exposed a stale assertion for the old generic
message; after updating the contract to the intended safe diagnostic
`App Store 网络错误（-1009）`, the focused true-device rerun passed.

### Task 2: Clean Reinstall While Subscription Is Still Valid

**Files:**
- Verify: `Examples/ExamplesUITests/ExamplesUITests.swift`
- Evidence: `/private/tmp/PaymentKit-Sandbox-Reinstall-20260730.xcresult`

**Interfaces:**
- Consumes: account A’s current valid, non-renewing annual subscription.
- Produces: proof that launch reconstructs StoreKit entitlement/status without automatic `AppStore.sync()`.

- [x] **Step 1: Record the pre-uninstall state**

```text
subscription state = 有效
automatic renewal = 不会自动续订
billing plan = 预付
pending transactions = 0
```

- [x] **Step 2: Uninstall only `com.paymentkit.examples` from the iPhone SE**

```sh
xcrun devicectl device uninstall app \
  --device 00008030-001E69322223802E \
  com.paymentkit.examples
```

Expected: only the example app and its local container are removed; Sandbox purchase history remains at Apple.

- [x] **Step 3: Reinstall and launch the signed Sandbox build**

```sh
xcrun devicectl device install app \
  --device 00008030-001E69322223802E \
  /private/tmp/PaymentKit-Diagnostics-Device/Build/Products/Debug-iphoneos/Examples.app
xcrun devicectl device process launch \
  --device 00008030-001E69322223802E \
  com.paymentkit.examples
```

Expected within 30 seconds without “恢复购买”: annual entitlement is present, status remains “有效 / 不会自动续订 / 预付”, and pending is 0.

Result (2026-07-30, iPhone SE): after deleting the app and local container,
reinstalling, and launching without “恢复购买”, the existing annual lifecycle,
“不会自动续订”, and pending count 0 were reconstructed. The UI acceptance test
then passed the same assertions across two cold launches.

### Task 3: Offline, Weak-Network, and Recovery Behavior

**Files:**
- Verify: `Sources/PaymentKit/PaymentClient.swift`
- Verify: `Examples/Examples/ContentView.swift`
- Evidence:
  - `/private/tmp/PaymentKit-Sandbox-Offline-ColdLaunch-Console-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-Network-Recovery-10s-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-NLC-100-Loss-10s-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-NLC-Very-Bad-Network-30s-20260731.png`

**Interfaces:**
- Consumes: the reinstalled account A state from Task 2.
- Produces: proof that failed refreshes preserve the last complete snapshot and later lifecycle signals recover.

- [x] **Step 1: With the app foregrounded and stable, enable Airplane Mode**

```text
Do not terminate the app and do not click diagnostic refresh.
```

Expected after foreground/background round trip: the last complete entitlement and subscription snapshot remains visible; no entitlement is revoked and pending remains 0.

- [x] **Step 2: Terminate and cold-launch while still offline**

```sh
xcrun devicectl device process launch \
  --device 00008030-001E69322223802E \
  --terminate-existing \
  com.paymentkit.examples
```

Expected: the app remains responsive and reports unavailable StoreKit data honestly; it must not crash, fabricate renewal status, finish unknown transactions, or show a successful restore.

Result (2026-07-31, iPhone SE): **failed availability semantics**. The app
remained responsive for more than 10 seconds and pending stayed at 0, but an
offline cold launch rendered “当前权益（0）/订阅状态（0）” instead of reporting
that StoreKit data was unavailable. Root-cause trace: `performInitialStartup`
calls the full `refresh()`, which requires `reloadProducts()` before querying
entitlements; the product load error leaves the initial in-memory snapshot
empty, and startup logs rather than surfaces the error.

- [x] **Step 3: Reenable networking and foreground the app**

```text
Do not click diagnostic refresh or “恢复购买”.
```

Expected within 30 seconds: products and the account A entitlement/status converge again, pending remains 0, and there is no duplicate business delivery.

Result (2026-07-31, iPhone SE): passed without diagnostic refresh or restore.
Products reappeared within 10 seconds and the annual status converged to the
now-correct “已过期 / 不会自动续订”; current entitlement and pending counts
were both 0.

- [x] **Step 4: Repeat with iOS Network Link Conditioner if available**

```text
Profile: 100% Loss for 20 seconds, then Wi-Fi with 200 ms latency for 30 seconds, then Off.
```

Expected: loading operations return or time out with stable public errors; the last complete snapshot is not replaced by partial data.

Result (2026-07-31, iPhone SE): passed with both `100% Loss` for 10 seconds
and `Very Bad Network` for 30 seconds. The last complete annual status remained
present and pending stayed at 0 throughout.

### Task 4: Sandbox Account Switching

**Files:**
- Verify: `Sources/PaymentKit/PaymentAutomaticRefresh.swift`
- Verify: `Sources/PaymentKit/PaymentClient.swift`
- Evidence:
  - `/private/tmp/PaymentKit-Sandbox-Account-B-Very-Bad-Network-30s-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-Account-B-Normal-Network-10s-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-Account-B-ColdLaunch-10s-20260731.png`
  - `/private/tmp/PaymentKit-Sandbox-Account-A-Foreground-40s-20260731.png`
  - `/private/tmp/PaymentKit-Account-A-Diagnostics-20260731`

**Interfaces:**
- Consumes: two Sandbox testers with different purchase histories.
- Produces: proof that foreground refresh replaces account-scoped entitlements/statuses instead of merging them.

- [x] **Step 1: Sign out account A and sign in account B**

```text
Settings > Developer > Sandbox Apple Account > Sign Out, then sign in as B.
```

Expected after returning to the app without diagnostic refresh: A’s purchased entitlement is absent unless B receives it through Family Sharing; no A status is misattributed to B.

Result (2026-07-31, iPhone SE): current entitlement remained 0, so access was
never granted to B. However, A’s expired annual status remained visible after
30 seconds on `Very Bad Network` and another 10 seconds on normal networking.
After a cold launch, B correctly showed current entitlement 0, subscription
status 0, and pending 0. StoreKit’s running Sandbox session therefore did not
emit/return the negative account-state transition needed to remove A’s status.

Root cause and fix (2026-07-31, terminology corrected 2026-08-04): A’s
verified subscription status event remained in the process-local update cache.
A successful empty query for B was conservatively reconciled with that cached
event because StoreKit exposes no account identifier that could prove an
account switch. `PaymentClient` exposes `reloadStoreSession()` for known
StoreKit system presentations; it rebuilds the lifecycle and clears only
session-level caches without calling `AppStore.sync()` or deleting the SQLite
outbox.

The no-process-exit rerun found a second, lower boundary: A had the
`paymentkit.demo.lifetime` entitlement, and after switching to B both a normal
foreground refresh and `reloadStoreSession()` still returned that A entitlement.
Restarting StoreKit sequences alone therefore cannot guarantee account rebinding.
The production account-switch path is the existing user-visible “恢复购买”
action. After its explicit `AppStore.sync()` succeeds, PaymentKit now stops the
old session, clears subscription-event and raw-transaction caches, rebuilds all
long-lived StoreKit listeners, replays unfinished/outbox work, and performs a
generation-bound full refresh.

Explicit-sync rerun (v4, 2026-07-31, iPhone SE): after A → B, the ordinary
foreground refresh still displayed A’s expired annual status, confirming the
public StoreKit account-boundary limitation. The user then tapped “恢复购买”.
Without a cold launch, B converged to current entitlement 0, subscription
status 0, and pending 0. Read-only App Group copies showed outbox 0, signed
event 0, and business delivery 0. No A state was attributed to B and no
unrelated transaction was delivered.

- [x] **Step 2: Sign out B and sign back in as A**

```text
Return directly to the app; do not click “恢复购买”.
```

Expected within 30 seconds: A’s valid annual entitlement and non-renewing status return, pending remains 0, and the backend records no duplicate delivery for unchanged business state.

Initial result (v3, 2026-07-31, iPhone SE): B → A restored the now-expired
annual status without a cold launch. StoreKit also exposed transaction
`…615941` through `Transaction.unfinished`, but pending remained 1 for more
than 60 seconds. Read-only App Group copies showed outbox 0 and backend
delivery 0. A cold launch then showed pending 0. Root cause: the application
activity path performed a full state refresh, and `refresh()` intentionally
only reconciles pending transactions; it does not initiate new business
delivery. The transient unfinished item was therefore displayed but never
entered the reliable delivery path before StoreKit stopped returning it.

Fix and rerun (v4, 2026-07-31, iPhone SE): foreground automatic-refresh
batches are now explicitly marked to replay newly discovered unfinished and
persisted outbox work before the full refresh. Public diagnostic `refresh()`
remains read-only, and no automatic path calls `AppStore.sync()`. The new
regression test
`foregroundActivationReplaysNewlyDiscoveredUnfinishedTransactions` first
failed against the old behavior and passes after the fix.

On the physical iPhone SE, B → A again restored the expired annual status
without a cold launch. Current entitlement was 0, pending remained 0, and the
backend view showed transaction `…615941` processed. Read-only databases
reported outbox 0, one signed event, and one business delivery. A second
background/foreground cycle left both counts at 1, proving the replay is
idempotent and does not duplicate business delivery.

### Task 5: Sandbox Family Sharing Gain and Revocation

**Files:**
- Modify only if observability is missing: `Examples/Examples/ContentView.swift`
- Test only if UI changes: `Examples/ExamplesTests/ExamplesTests.swift`
- Evidence: B’s `familyShared` ownership, sharing removal, revocation, and pending state.

**Interfaces:**
- Consumes: a Sandbox Test Family containing purchaser A and recipient B in the same storefront; the annual product must have Family Sharing enabled.
- Produces: proof that family access gain maps to `.familyShared` and loss arrives as a new revoked transaction state.

- [x] **Step 1: Create or verify the Sandbox Test Family**

```text
App Store Connect > Users and Access > Sandbox > Family Sharing
Organizer = A
Member = B
Share Purchases = enabled for A and B
```

Expected: both accounts use the same country/region.

Executed 2026-07-31 in App Store Connect. Tester C was configured as purchaser A and
family organizer, and the fresh recipient tester as member B; both use the China mainland
storefront and both have purchase sharing enabled. The annual subscription configuration
was also verified to state that everyone in the family group can share the subscription.

- [x] **Step 2: Sign in as B on the iPhone SE and launch the app**

```text
Settings > Developer > Sandbox Apple Account > B
```

Expected: B receives the annual entitlement with ownership type `familyShared`; pending returns to 0 after reliable delivery.

Executed 2026-07-31 on iPhone SE (`00008030-001E69322223802E`) with the fresh
member B account. After organizer A purchased the family-enabled annual product,
B's shared signed-event count advanced from 25 to 35 and business-delivery count
from 19 to 29; the app reported the new annual transactions delivered and finished,
and the pending-transaction database remained at 0. Because B had no purchase
history and received the annual state only while joined to A's Sandbox Test Family,
the gain and the later family-removal revocation provide causal evidence of
`familyShared` ownership even though the demo UI does not print the ownership enum.

- [x] **Step 3: Stop sharing purchases with B**

```text
Settings > Developer > Sandbox Apple Account > Manage > Account Settings >
Family Sharing > B > Stop Sharing Purchases
```

Expected after returning to the app: B loses the entitlement, receives a transaction with revocation information, the revoked business state is delivered once, and pending returns to 0.

Executed 2026-07-31. App Store Connect first saved B as not sharing. After the
documented Sandbox propagation delay did not deliver the revocation, B was removed
from the test family (the account itself was not deleted), which Apple documents as
the definitive access-loss path. A user-initiated restore then completed and the app
delivered and finished transaction `…121488`: signed events advanced from 35 to 37,
while business deliveries advanced exactly once from 29 to 30. A temporary read-only
UI probe passed with no annual subscription state, no annual entitlement, counts
37/30, and `待处理交易（0）`; the probe was removed immediately after execution.
Evidence: `/private/tmp/PaymentKit-Family-After-Successful-Restore.png` and
`/private/tmp/PaymentKit-Family-Restore/Logs/Test/Test-Examples Sandbox-2026.07.31_18-37-26-+0800.xcresult`.

### Task 6: Two Physical Devices

**Files:**
- Verify: `Examples/ExamplesUITests/ExamplesUITests.swift`
- Evidence: iPhone SE and paired iPhone 12 Pro Max screenshots/logs.

**Interfaces:**
- Consumes: iPhone SE plus physical iPhone 12 Pro Max, both unlocked and available to Xcode.
- Produces: proof that changes made on one device converge on the other through StoreKit infrastructure.

- [x] **Step 1: Install the same signed Sandbox build on both devices**

```sh
xcrun devicectl device install app --device 00008030-001E69322223802E \
  /private/tmp/PaymentKit-Diagnostics-Device/Build/Products/Debug-iphoneos/Examples.app
xcrun devicectl device install app --device 77ECF120-A82A-56BA-9D02-03378D00FC8D \
  /private/tmp/PaymentKit-Diagnostics-Device/Build/Products/Debug-iphoneos/Examples.app
```

Expected: both devices launch successfully and use the intended Sandbox tester.

Executed 2026-07-31 with the signed build at
`/private/tmp/PaymentKit-Billing-Retry-Device/Build/Products/Debug-iphoneos/Examples.app`.
The build launched on iPhone SE (`00008030-001E69322223802E`) and iPhone 12 Pro Max
(`00008101-000A54D23422001E`), both signed into tester C. The second device restored
the existing monthly entitlement and converged with pending transactions at 0.

- [x] **Step 2: Change renewal state on device 1 and observe device 2**

```text
On device 1, reenable annual renewal from Manage Subscriptions.
On device 2, foreground the app without diagnostic refresh.
```

Expected within 30 seconds: device 2 changes from “不会自动续订” to “将自动续订”.

Executed against the active monthly subscription because tester C's annual
subscription was no longer active. Reenabling renewal on iPhone SE propagated to
iPhone 12 Pro Max after foreground/cold launch without tapping the diagnostic refresh:
the second device showed “有效”, “将自动续订”, and pending 0.

- [x] **Step 3: Reverse the change from device 2**

```text
On device 2, disable annual renewal.
On device 1, foreground the app without diagnostic refresh.
```

Expected within 30 seconds: device 1 changes to “不会自动续订”; both devices show pending 0.

Disabling monthly renewal on iPhone 12 Pro Max propagated back to iPhone SE after
foreground/cold launch without tapping the diagnostic refresh. The iPhone SE showed
“有效”, “不会自动续订”, “下期续订：无”, and pending 0. A transient black first frame
was observed during the device-tool cold launch; the process remained alive and the UI
rendered normally on relaunch, so it did not affect the StoreKit convergence result.
Final read-only App Group exports confirmed `pending_transactions = 0` on both
devices. The iPhone SE ledger contained 25 signed events and 19 distinct business
deliveries; the iPhone 12 Pro Max ledger contained 6 signed events and 6 distinct
business deliveries. The different historical totals are device-local history, while
both devices converged on the same current StoreKit entitlement and renewal state.

### Task 7: Real Sandbox Billing Retry, Grace Period, and Recovery

**Files:**
- Verify: `Examples/Examples/ContentView.swift`
- Verify: `Sources/PaymentKit/PaymentStoreGateway.swift`
- Evidence: subscribed → grace → retry → recovered screenshots and transaction counts.

**Interfaces:**
- Consumes: dedicated tester C, monthly product `paymentkit.demo.monthly`, Sandbox Billing Grace Period enabled for this app, renewal rate “每 3 分钟”.
- Produces: real App Store Sandbox evidence for billing failure and recovery.

- [x] **Step 1: Enable Billing Grace Period only for Sandbox**

```text
App Store Connect > app > Subscriptions > Billing Grace Period >
Set Up Billing Grace Period > apply to all renewals > Only Sandbox Environment
```

Result (2026-07-31 15:32 +0800): enabled a 3-day Billing Grace Period for
all renewals in the Sandbox environment only. Production remains disabled.
App Store Connect displayed the saved configuration as “3 days / all
renewals / Sandbox only”. Apple notes that product-metadata changes can take
up to one hour to appear in Sandbox, so tester C purchase/renewal timing starts
only after the device prerequisite below is complete.

- [x] **Step 2: Configure C and purchase the monthly subscription**

```text
Settings > Developer > Sandbox Apple Account > Manage > Account Settings
Subscription Renewal Rate = Every 3 Minutes
Allow Purchases & Renewals = On
```

Expected after purchase: state “有效”, current entitlement present, automatic renewal on, pending 0.

Partial result (2026-07-31 15:47 +0800): tester C purchased
`paymentkit.demo.monthly` on the iPhone SE in the real Sandbox. The app
converged to “有效” with the current entitlement present and automatic renewal
on. The shared device ledger moved from 1 to 2 signed events and from 1 to 2
business deliveries; both new rows were created at 15:47:20, and a later
cold-launch export remained at 2/2 with zero rows in `pending_transactions`.
The purchase UI test's post-relaunch Section-header label assertion timed out
even though the framework log reported `entitlementCount=1 pendingCount=0
subscriptionCount=1` and both independent ledger exports reported pending 0.
Treat that assertion as a QA-harness observability failure, not as evidence of
a duplicate or unfinished product transaction. The device account settings
show “Every 3 Minutes” with Allow Purchases & Renewals on, completing Step 2.

- [ ] **Step 3: Disable purchases and renewals before the next renewal**

```text
Allow Purchases & Renewals = Off
```

Expected at the renewal boundary: state “宽限期”, entitlement remains available, a grace-period expiration date is present in `renewalInfo`, and pending remains 0.

- [ ] **Step 4: Let grace period expire**

```text
Keep Allow Purchases & Renewals off for the configured 3-minute grace period.
```

Expected: state “账单重试”, entitlement is unavailable after grace expires, `isInBillingRetry == true`, and no failed renewal is incorrectly delivered as a completed transaction.

Attempt 1 result (2026-07-31 15:55–16:02 +0800): confirmed tester C
remained at “Every 3 Minutes” and disabled Allow Purchases & Renewals at
15:55:03. A read-only device UI probe observed “账单重试” at 15:58:00
without first observing “宽限期”. A second read-only probe confirmed the
runtime current entitlement was empty and the shared counters remained at
4 signed events / 4 business deliveries; an independent device-ledger export
reported zero `pending_transactions`. At 16:01:57 the state had become
“已过期”, matching the documented 6-minute Sandbox retry window. The two
additional successful records that raised the baseline from 2/2 to 4/4 were
both processed at 15:55:35 before the failed renewal state was observed.

The Sandbox-only Billing Grace Period configuration had been saved for only
about 26 minutes when the failed renewal occurred, within Apple's documented
“up to one hour” metadata propagation window. Classify the missing grace
state as BLOCKED on Sandbox configuration propagation, not as a PaymentKit
failure. Steps 3–5 remain open and require a fresh purchase/retry cycle after
16:32 +0800; the first retry window expired before recovery was enabled.

Attempt 2 result (2026-07-31 16:40–16:51 +0800): after the Billing Grace
Period configuration had been saved for more than one hour, tester C
repurchased the monthly subscription. The device ledger baseline was 5 signed
events / 5 business deliveries with zero pending transactions at 16:40:06.
Allow Purchases & Renewals was disabled at 16:41:15. The same transaction
entered “账单重试” directly at about 16:44 without ever exposing “宽限期” or
retaining a current entitlement. This rules out the earlier metadata
propagation hypothesis; the missing grace state is now BLOCKED on the saved
App Store Connect grace-period configuration or Apple Sandbox behavior and
must not be claimed as a PaymentKit pass.

Allow Purchases & Renewals was enabled again near the end of the retry window,
but a 16:50 read-only StoreKit probe reported “已过期 / 不会自动续订 / 下期续订：
无”. The exported ledger remained at 5 distinct business deliveries and zero
pending transactions. It contained one extra signed-event audit row at
16:43:18 whose delivery digest matched the 16:40:06 purchase; the backend
correctly classified this as a duplicate replay instead of creating a sixth
business delivery. Apple generated no recovered-renewal transaction before the
window ended, so Step 5 remains unverified rather than failed. Evidence:
`/private/tmp/PaymentKit-Sandbox-Billing-C-Retry2-Recovery-Missed-20260731-165117.jpeg`
and
`/private/tmp/PaymentKit-Billing-C-Retry2-Recovery.pVpaEX/Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`.

Attempt 3 result (2026-07-31 16:56–17:06 +0800): tester C
repurchased the monthly subscription at 16:56:00. The baseline was 8 signed
events / 6 distinct business deliveries / zero pending transactions. Allow
Purchases & Renewals was confirmed off by 16:57:55. At 16:59:18 a read-only
device probe observed the subscription enter “账单重试” directly, with no
current entitlement, no new business delivery, and zero pending transactions.
The failure-stage UI probe passed:
`/private/tmp/PaymentKit-Sandbox-Billing-C-Retry3-Failure-ReadOnly-20260731-1658.xcresult`.
The third direct transition to billing retry confirms that Billing Grace
Period remains an App Store Connect / Apple Sandbox blocker; Steps 3–4 stay
open.

Allow Purchases & Renewals was confirmed on by 17:00:45. The read-only StoreKit
probe observed “有效” and the monthly current entitlement again at about 17:02.
The independent SQLite ledger then contained two new, distinct, first-delivery
states: one at 17:01:51 and one at 17:02:15. Based on their positions relative
to the failed 16:59 renewal and the 3-minute renewal cadence, the first is the
recovered billing period and the second is the immediately following normal
renewal. Both were accepted exactly once and pending remained zero.

The recovery UI probe's absolute-count assertion expected 7 but read a stale
on-screen backend count of 6, while the same device ledger already contained
8 distinct deliveries. Treat this as a QA-harness snapshot-refresh
false-negative, not a missing or duplicate delivery. A later 17:06 normal
renewal raised the ledger to 9 distinct deliveries; two immediately adjacent
cold-launch exports then both remained at 13 signed-event audit rows / 9
distinct business deliveries / zero pending transactions, proving that cold
launch did not duplicate business delivery. Evidence:
`/private/tmp/PaymentKit-Billing-C-Retry3-Recovery.qyvvma/Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`,
`/private/tmp/PaymentKit-Billing-C-Retry3-Cold1.rJmTAj/Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`,
and
`/private/tmp/PaymentKit-Billing-C-Retry3-Cold2.PtPdQn/Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`.

Attempt 4 configuration recheck (2026-08-03 10:24–10:31 +0800): the active
App Store Connect session loaded the `PaymentKit Sandbox MP8Z` subscription
page after about 10 seconds. Billing Grace Period still displayed
`3 days / all renewals / Sandbox only`; no setting was changed. The temporary
blank app list was page-loading latency rather than an authentication failure.
Steps 3–4 remain open and can proceed with a fresh monthly purchase/failure
cycle on the physical device.

Attempt 5 result (2026-08-03 10:47–10:57 +0800): fresh tester
`sandboxdemo6@qq.com` purchased the monthly subscription with the 3-minute
renewal rate. Before relaunch the UI converged to a current monthly entitlement,
“有效”, “将自动续订”, and zero pending transactions. The purchase acceptance
test then failed its cold-launch assertion because pending did not return to
zero. At about 10:51, Allow Purchases & Renewals was confirmed off before the
next observation launch.

The normal cold launch resurfaced transaction suffix `117714` with
`entitlementCount=0`, `pendingCount=1`, and `subscriptionCount=1`; PaymentKit
then delivered/finished that transaction and the visible backend counters
settled at 40 signed events / 31 business deliveries. At the same time,
`Product.SubscriptionInfo.Status.all` repeatedly produced a current-snapshot
event and ended. In the attached 133-line sample, PaymentKit logged 43 listener
reconnects and issued 43 `subscription-status` refresh requests. Because every
short-lived sequence produced an update, the reconnect loop reset its delay to
250 ms on every pass and never reached the intended 4-second backoff. This is a
production robustness failure in addition to the malformed Apple Sandbox
`autoRenewStatus` data recorded in Task 8: the app performs continuous status
queries and cannot present a trustworthy grace-period or billing-retry snapshot.
Steps 3–4 remain open. Evidence:
`/private/tmp/PaymentKit-Grace-PostFailure-Launch-40-31-20260803.jpeg` and
`/private/tmp/PaymentKit-Grace-SubscriptionStatus-Reconnect-Loop-20260803.log`.

Robustness fix verification (2026-08-03 11:03–11:10 +0800): PaymentKit now
keeps exponential reconnect backoff even when each short-lived status stream
produces one value, ignores structurally equivalent status results before
requesting another refresh, and emits the unexpected-termination warning only
once per client lifecycle. Two regression tests cover the short-lived-stream
and duplicate-update paths; the complete 169-test Swift package suite and an
`Examples Sandbox` generic iOS Simulator build passed. On the same physical
device and malformed Sandbox account state, the final build ran for about
30 seconds with one reconnect warning, one `subscription-status` refresh, zero
duplicate-event log lines, and a stable 14-line console instead of continuous
refresh/reconnect work. The client busy loop is fixed; Steps 3–4 remain open
only for a fresh Apple grace-period state transition. Evidence:
`/private/tmp/PaymentKit-SubscriptionStatus-Listener-Fix-RealDevice-20260803.jpeg`.

Root-cause correction (2026-08-03): the malformed Sandbox
`missingValue(... "autoRenewStatus" ...)` remains valid evidence for a separate
StoreKit data failure, but it is not required to explain the warning observed on
otherwise normal cold launches. `Product.SubscriptionInfo.Status.all` is a
finite current-status sequence and normally ends after enumerating its snapshot;
PaymentKit had incorrectly treated that completion as an unexpected termination.
The production adapter now loads current groups with `status(for:)` and reserves
the long-lived reconnect loop for `Status.updates` only.

Attempt 6 result (2026-08-03 11:23–12:15 +0800): tester C completed another
monthly Sandbox purchase with Allow Purchases & Renewals disabled before the
renewal observation. Apple reported the operation complete, but the read-only
probes again skipped the configured grace-period state and settled directly at
“已过期”, with no current entitlement. This does not satisfy Steps 3–4 and must
not be recorded as a grace-period pass.

The cycle also exposed two independent acceptance-harness issues. First, an
equivalent StoreKit re-signing could interleave with finish/outbox cleanup and
briefly re-enter the in-memory pending snapshot; PaymentKit now records the
completed business state immediately after the durable delivered mark, before
awaiting finish or cleanup. Three focused race regressions passed. Second, the
read-only UI test scrolled away from the pending section after proving the
runtime entitlement set was empty; correcting the direction removed that false
negative. The final physical-device cold-launch test passed with “已过期”, no
current entitlement, and `待处理交易（0）`. The SQLite outbox exported from the
device was empty, and the complete Swift package suite passed 172 tests.
Evidence:
`/private/tmp/PaymentKit-Sandbox-Pending-Race-Fix2-Stable3-20260803-1215.xcresult`.

Attempt 7 result (2026-08-03 14:57–15:42 +0800): tester C repurchased the
monthly subscription. Apple's purchase return was delayed beyond the UI
probe's 120-second window, but transaction `…224130` subsequently arrived
through the normal update stream and completed reliable delivery. Allow
Purchases & Renewals was then confirmed off. The 15:07 read-only probe again
observed “账单重试” directly, with no monthly current entitlement and zero
pending transactions; the configured grace-period state was not exposed on
this seventh independent cycle. Steps 3–4 therefore remain BLOCKED on the
saved App Store Connect Billing Grace Period configuration or Apple Sandbox
behavior, not on PaymentKit.

Allow Purchases & Renewals was confirmed on before the retry window ended.
Recovery transaction `…231222` returned the subscription to an active state
and added exactly one signed audit payload and one distinct business delivery.
The immediately following normal renewal added two signed audit payloads but
only one distinct business delivery, confirming equivalent re-signings did not
duplicate backend work.

The first long recovery/relaunch probes crossed later legitimate 3-minute
renewal boundaries. Their diagnostics revealed a separate in-process snapshot
bug: StoreKit could commit a newer JWS/signedDate for one business state, then
deliver a finishable older handle for the same state. `finish` and outbox
cleanup succeeded, but the snapshot cleanup retained the newer equivalent JWS
as pending until a full refresh. PaymentKit now removes snapshot entries by
the transaction's stable `deliveryState`, while continuing to preserve a newer
revocation, upgrade, expiration, or ownership change. Two focused positive and
negative regressions cover that distinction; the complete Swift package suite
passed 174 tests.

The final short physical-device probe intentionally avoided subscription-state
scrolling so it could not cross another renewal boundary. Its first launch
replayed two normal monthly transactions accumulated during the long probes
(`…252321` and `…250662`), delivered and finished both in about 1.5 seconds,
and converged to `entitlementCount=1 pendingCount=0 subscriptionCount=1`.
The second cold launch attempted zero unfinished transactions and again
reported pending 0. The UI test passed in 31.884 seconds with zero failures.
Evidence:
`/private/tmp/PaymentKit-Sandbox-Pending-Resign-Fix-ColdLaunch-20260803.xcresult`.

Attempt 8 result (2026-08-03 16:27–16:37 +0800): tester C completed a new
monthly Sandbox purchase. As in Attempt 7, Apple's transaction delivery was
later than the purchase probe's 120-second entitlement wait, but the next
short cold-launch snapshot at 16:31:52 converged to “有效 / 将自动续订 /
权益：有 / 待处理交易（0）”. Allow Purchases & Renewals was confirmed off
with the account still configured for a 3-minute renewal rate. A 16:34:17
probe still read “有效”, proving the switch was disabled before the next
failed-renewal transition rather than after it.

The second failure probe observed “账单重试” at 16:35:41, directly from the
active state, with no monthly entitlement and zero pending transactions. It
passed without ever exposing the configured “宽限期”. This eighth independent
cycle therefore leaves Steps 3–4 BLOCKED on the saved App Store Connect
Billing Grace Period configuration or Apple Sandbox behavior; it is not a
PaymentKit product failure and must not be claimed as a grace-period pass.
Evidence:
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt8-PostPurchase-Snapshot2-20260803.xcresult`
and
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt8-Failure-Probe2-20260803.xcresult`.

Allow Purchases & Renewals was reenabled before the Sandbox retry window
ended. The first short cold-launch recovery snapshot at 16:37:37 already read
“有效 / 将自动续订 / 权益：有 / 待处理交易（0）”, verifying prompt automatic
recovery without crossing the next normal renewal boundary. Evidence:
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt8-Recovery-Probe1-20260803.xcresult`.
The subsequent two-launch pending-only probe passed in 33.541 seconds: both
launches observed `待处理交易（0）`, so the recovered renewal left no
unfinished work and the second cold launch did not replay a completed state.
Evidence:
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt8-Recovery-ColdLaunch-20260803.xcresult`.

Attempt 9 result (2026-08-03 16:45–16:55 +0800): the existing monthly
subscription provided a clean active baseline at 16:46:01: “有效 / 将自动续订 /
权益：有 / 待处理交易（0）”. Allow Purchases & Renewals was confirmed off
while the account remained at the 3-minute renewal rate. A 16:50:19 probe still
read “有效”, proving the setting was disabled before the observed failed
renewal rather than after it. One preceding Runner launch ended with a
CoreDevice socket EOF before the test started and is excluded as transport
noise, not counted as subscription evidence.

The next completed probe observed “账单重试” at 16:52:58, with no monthly
entitlement and zero pending transactions. It again skipped “宽限期” entirely.
Allow Purchases & Renewals was then reenabled inside the retry window; the
first recovery snapshot at 16:55:06 read “有效 / 将自动续订 / 权益：有 /
待处理交易（0）”. Attempt 9 therefore reproduces the same externally blocked
grace-period transition with a clean before/after boundary and successful
recovery. Evidence:
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt9-Preflight-20260803.xcresult`,
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt9-Failure-Probe2-20260803.xcresult`,
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt9-Failure-Probe3-20260803.xcresult`,
and
`/private/tmp/PaymentKit-Sandbox-Grace-Attempt9-Recovery-Probe1-20260803.xcresult`.

- [x] **Step 5: Recover billing**

```text
Settings > Developer > Sandbox Apple Account > Manage > Account Settings >
Allow Purchases & Renewals = On
```

Expected before the 6-minute retry window ends: state returns to “有效”, entitlement returns, the successful renewal is delivered exactly once, and pending returns to 0.

### Task 8: Approved Refund Revocation and Relaunch

**Files:**
- Verify: `Examples/ExamplesUITests/ExamplesUITests.swift`
- Evidence: `/private/tmp/PaymentKit-Sandbox-Refund-Revocation.xcresult`

**Interfaces:**
- Consumes: an active purchased subscription after Tasks 2–7.
- Produces: proof that approved refund revocation removes entitlement, delivers one new business state, and survives cold launch.

- [x] **Step 1: Run the existing refund UI acceptance test**

```sh
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme 'Examples Sandbox' \
  -destination 'id=00008030-001E69322223802E' \
  -resultBundlePath /private/tmp/PaymentKit-Sandbox-Refund-Revocation.xcresult \
  -only-testing:ExamplesUITests/ExamplesUITests/testYearlyRefundRevocationConvergesWithoutManualRefresh \
  test
```

On the system refund sheet, select any normal reason and submit. Do not enter `DECLINE`.

Expected: state “已撤销”, entitlement removed, pending 0, at least one new
signed audit event, and exactly one new business delivery. StoreKit may issue a
new signature for an equivalent transaction state; this is retained for audit
without duplicating business delivery.

Blocked attempt (2026-07-31 17:11–17:18 +0800): the current tester C
account held an active monthly entitlement after Task 7 but no yearly
entitlement, so an equivalent temporary monthly refund probe opened Apple's
system refund sheet for `paymentkit.demo.monthly`. The application reached the
system-presentation state successfully. The Apple sheet then remained on
“正在载入”, changed to “无法连接”, and after one manual “重试” returned to
loading without ever displaying a reason list or submit action.

The probe waited the full 300-second revocation window. The entitlement
remained present and no refund was submitted, so this is BLOCKED on the Apple
Sandbox refund service rather than a PaymentKit failure or pass. The
post-attempt device ledger reported zero pending transactions. Its only two new
business deliveries were normal accelerated subscription renewals at 17:15:02
and 17:17:32; there was no partial revocation state. Evidence:
`/private/tmp/PaymentKit-Sandbox-Monthly-Refund-Sheet-Blank-20260731-171543.jpeg`
and
`/private/tmp/PaymentKit-Refund-Monthly-Blocked.bZ9fYs/Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`.
The temporary monthly probe was removed after the attempt. Steps 1–2 remain
open until Apple's refund sheet can load and accept a Sandbox submission.

Retry result (2026-08-03 10:08–10:26 +0800): the tester reported that the
physical-device refund UI was available again and requested a cold launch.
The normal launch retained zero current subscription entitlement and the
shared backend counters remained stable at 38 signed events / 30 business
deliveries throughout this observation window. The existing Step 1 UI test
could no longer enter the refund sheet because its annual-entitlement
precondition was absent. The Step 2 cold-launch test also did not find an
annual subscription state of “已撤销”, so neither test is a refund-revocation
pass.

The normal Xcode launch then exposed a repeatable StoreKit status failure for
subscription group `22255725`:
`missingValue(... "autoRenewStatus" ..., expected: StoreKit.BackingValue)`.
`Product.SubscriptionInfo.Status.all` ended after the malformed group update;
PaymentKit repeatedly treated the finite snapshot event as a state-refresh
request and rebuilt the subscription-status listener. Each refresh took about
80–90 ms and the UI remained at “PaymentKit 已启动并监听交易” instead of
rendering a complete subscription snapshot. This is no longer solely an Apple
refund-sheet availability blocker: Apple supplied malformed Sandbox renewal
status, while PaymentKit failed the production robustness requirement to
preserve the last complete snapshot and avoid repeated refresh/reconnect work.
Keep Steps 1–2 open until a new revocation transaction is observed, delivered
exactly once, and survives two cold launches. Evidence:
`/private/tmp/PaymentKit-Refund-PostRestart-Counters-38-30-20260803.png` and
`/private/tmp/PaymentKit-Refund-SubscriptionStatus-MissingAutoRenewStatus-20260803.png`.

Payment-plan preflight (2026-08-03 12:16–12:23 +0800): the annual product now
offers two materially different plans under the same product ID: up-front annual
billing and monthly billing with a 12-month commitment. The refund acceptance
test now records and validates the entitlement transaction's actual billing plan;
the commitment path additionally requires a `/12` progress value. Apple documents
that each commitment month is an independent transaction: refunding a prior month
does not end the commitment, while refunding the current entitlement month ends
the commitment immediately. The QA plan continues to target the original up-front
annual scenario rather than silently substituting the commitment plan.

Two read-only preflights confirmed there is currently no annual entitlement. A
dedicated purchase probe explicitly selected the up-front plan and opened the
Sandbox confirmation sheet, but the sheet did not close within the 180-second
human-confirmation window. A post-timeout read-only preflight again found no
annual entitlement, so no purchase or refund success is claimed. Evidence:
`/private/tmp/PaymentKit-Sandbox-Yearly-UpFront-Refund-Probe-Purchase-20260803-1230.xcresult`
and
`/private/tmp/PaymentKit-Sandbox-Yearly-Refund-PostPurchaseTimeout-Preflight-20260803-1235.xcresult`.
Step 1 remains open pending a human-confirmed up-front annual purchase followed
by a submitted refund request.

Completed retry (2026-08-03 14:30–14:47 +0800): a human-confirmed purchase
created the original up-front annual plan, and the read-only preflight verified
the active entitlement with `账单计划：预付`. The normal refund request was
submitted at 14:30:40. The interactive acceptance test exhausted its original
300-second revocation wait while Apple still reported the entitlement as
active; this was propagation latency, not a client-side failure. Apple documents
that a successful refund-request return value only means the App Store received
the request, and gives no separate Sandbox timing guarantee.

The refund transaction arrived approximately 15 minutes after submission. The
delayed cold-launch probe then observed `已撤销`, no annual entitlement, and
`待处理交易（0）` on two consecutive launches. Shared counters were stable at
47 signed audit events / 34 business deliveries across both launches. Relative
to the 45 / 33 baseline captured immediately before the request, StoreKit
produced two new signed audit payloads while PaymentKit delivered the revoked
business state exactly once. The acceptance assertion now permits one or more
new signed audit events while retaining the exact +1 business-delivery
requirement. The delayed probe also no longer depends on an unrelated lifetime
entitlement.

Evidence:
`/private/tmp/PaymentKit-Sandbox-Yearly-UpFront-Refund-Probe-Purchase-Retry3-20260803-1435.xcresult`,
`/private/tmp/PaymentKit-Sandbox-Yearly-Refund-PostSuccess-Preflight-20260803-1440.xcresult`,
`/private/tmp/PaymentKit-Sandbox-Yearly-UpFront-Refund-Revocation-20260803-1445.xcresult`,
and
`/private/tmp/PaymentKit-Sandbox-Yearly-Refund-Delayed-Relaunch-Final-20260803-1450.xcresult`.
After the audit-count assertion was generalized, the same delayed relaunch test
was recompiled and passed again in 97.787 seconds with 0 failures; evidence:
`/private/tmp/PaymentKit-Sandbox-Yearly-Refund-Delayed-Relaunch-PostAssertionFix2-20260803.xcresult`.

- [x] **Step 2: Verify revocation cold launch**

```sh
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme 'Examples Sandbox' \
  -destination 'id=00008030-001E69322223802E' \
  -only-testing:ExamplesUITests/ExamplesUITests/testDelayedYearlyRefundRevocationSurvivesRelaunch \
  test
```

Expected: two cold launches retain the revoked state and unchanged signed-event/business-delivery counts.

### Task 9: Final Evidence and Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-27-automatic-payment-state-refresh-design.md`
- Modify: this plan’s checkbox states and result notes.

**Interfaces:**
- Consumes: all test outputs and screenshots.
- Produces: an evidence-backed production-readiness report with explicit passes, failures, environmental blockers, and untested gaps.

- [x] **Step 1: Run final automated regression**

```sh
swift test
git diff --check
```

Expected: all Swift tests pass and no whitespace errors exist.

Result (2026-07-31): `swift test` passed 167 tests in 7 suites with 0
failures. `git diff --check` completed with exit code 0.

Final rerun (2026-08-03 16:41 +0800): `swift test` passed 174 tests in 7
suites with 0 failures after the production listener, equivalent re-sign
snapshot, and refund-test updates; `git diff --check` completed with exit code
0.

- [x] **Step 2: Record only observed results**

```text
For each scenario record: device, account alias, setup, timestamps, observed
state transitions, entitlement/pending counts, xcresult path, and whether a
manual system action was required.
```

Result (2026-08-03): Tasks 1–8 now record the actual device/account alias,
setup and manual system action, observed timestamps and state transitions,
entitlement/pending or signed/business counts, and available evidence paths.
No unobserved Billing Grace Period transition is presented as a pass.

- [x] **Step 3: Separate product failures from unavailable prerequisites**

```text
FAIL = observable behavior violates an acceptance criterion.
BLOCKED = required Sandbox configuration, account, paired/unlocked device, or
Apple propagation is unavailable.
NOT RUN = intentionally deferred; never report it as pass.
```

Final classification (2026-08-03): every observed acceptance violation is
recorded as `FAIL` at the point where it occurred; the listener reconnect loop
and pending snapshot races discovered during the matrix were fixed and then
rerun with focused regressions and physical-device evidence. Task 7 Steps 3–4
remain `BLOCKED`, not `FAIL` or `PASS`: nine independent cycles with the saved
Sandbox-only Billing Grace Period configuration all transitioned directly to
billing retry. Refund revocation and its delayed cold launch passed. No other
scenario in this plan remains intentionally `NOT RUN`.

## Official References

- [Testing failing subscription renewals and In-App Purchases](https://developer.apple.com/documentation/storekit/testing-failing-subscription-renewals-and-in-app-purchases)
- [Testing refund requests](https://developer.apple.com/documentation/storekit/testing-refund-requests)
- [Testing Family Sharing](https://developer.apple.com/documentation/storekit/testing-family-sharing)
- [Manage Sandbox Apple Account settings](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings/)
- [Testing In-App Purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)

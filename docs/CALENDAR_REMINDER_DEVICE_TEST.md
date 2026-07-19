# Calendar Reminder — Physical Device Test Plan

Local calendar reminders are delivered on-device by
`flutter_local_notifications` via timezone-aware `zonedSchedule()` calls using
`AndroidScheduleMode.inexactAllowWhileIdle`. Because scheduling is **inexact**,
Android may batch the alarm to save power: delivery is expected *around* the
target time (typically within a few minutes, longer in Doze), not to the exact
second. Record both the expected trigger time and the actual delivery time for
every run.

These scenarios must be executed on real hardware — an emulator/simulator does
not reproduce Doze, reboot alarm restoration, or package-replacement behaviour.
**Do not mark any scenario below as passed unless it was actually performed on a
physical device.**

## Preconditions (all devices)

- A signed-in Calee account with at least one connected calendar.
- The app built from this branch installed on the device.
- Ability to create a calendar event whose start is far enough in the future
  that its `T-minus-10-minutes` reminder is also in the future.

The reminder candidate time is `event start − 10 minutes` (unchanged by this
work). To inspect what the plugin has actually scheduled, use the app's pending
notification diagnostics (`LocalCalendarNotificationService.collectDiagnostics`)
which reports only safe counts — pending platform count, tracked manifest count,
and the two mismatch counts — never event content.

---

## Android physical device

Test on at least one of Android 13, 14, or 15 where available. Note the exact OS
version used for each run.

1. Grant notification permission when prompted (Settings → toggle *Calendar
   reminders* on).
2. Confirm reminders are enabled in Calee Settings.
3. Create an event ~30–60 minutes in the future so its T-10 reminder is a few
   minutes out.
4. Confirm the reminder appears in the plugin's pending requests
   (`pendingPlatformCount` increments; `pendingButUntrackedCalendarCount` == 0).
5. Verify delivery in each app state:
   - Calee foregrounded.
   - Calee backgrounded (home button).
   - Calee removed from recent apps (swipe away).
   - Device locked.
6. Reboot the device with a future reminder still pending.
7. After reboot (do **not** open Calee first), confirm the reminder still fires
   at its scheduled time — this exercises `RECEIVE_BOOT_COMPLETED` +
   `ScheduledNotificationBootReceiver`.
8. Install an updated build over the existing app (package replacement).
9. Confirm future reminders remain scheduled / are restored after the update —
   this exercises the `MY_PACKAGE_REPLACED` intent action.
10. Change the device timezone, reopen Calee so reconciliation runs, and confirm
    reminders re-anchor to the new local time.
11. Record the actual delivery time vs. the expected T-10 trigger time.
12. **Force-stop caveat:** Do not treat Android *Force stop* (Settings → Apps →
    Force stop) as a normal delivery test. Force-stopping cancels the app's
    alarms until the app is next launched; this is OS behaviour, not a Calee
    defect. Document force-stop results separately from the normal scenarios.

### Android result log

| OS ver | App state | Expected (T-10) | Actual delivery | Pass/Fail | Notes |
| ------ | --------- | --------------- | --------------- | --------- | ----- |
|        |           |                 |                 |           |       |

---

## iPhone physical device

1. Grant notification permission when prompted.
2. Confirm foreground presentation: with Calee open, a due reminder is presented
   (uses the existing Darwin presentation options; the app registers the
   `UNUserNotificationCenter` delegate at launch).
3. Test background delivery (Calee backgrounded).
4. Test with Calee terminated normally (swipe up from the app switcher).
5. Test while the device is locked.
6. Change the device timezone, reopen Calee so reconciliation runs, and confirm
   reminders re-anchor.
7. Record expected vs. actual delivery time.

### iOS result log

| iOS ver | App state | Expected (T-10) | Actual delivery | Pass/Fail | Notes |
| ------- | --------- | --------------- | --------------- | --------- | ----- |
|         |           |                 |                 |           |       |

---

## Exact alarms — future product/release decision

This PR intentionally keeps **inexact** scheduling
(`AndroidScheduleMode.inexactAllowWhileIdle`) and does **not** add
`SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`. Moving to exact alarms is a separate
decision that should weigh:

- **User benefit:** exact-to-the-minute delivery vs. the current "around 10
  minutes before" behaviour. For a soft event reminder, inexact is usually
  acceptable.
- **Android version behaviour:** on Android 12 (API 31)+ exact alarms require
  the `SCHEDULE_EXACT_ALARM` permission; on Android 13 (API 33)+ that permission
  is **not** granted by default for most apps and `USE_EXACT_ALARM` is reserved
  for alarm-clock-class apps.
- **Permission UX:** `SCHEDULE_EXACT_ALARM` sends the user to a system settings
  screen to grant "Alarms & reminders"; this adds friction and can be revoked.
- **Play Console declaration:** using `USE_EXACT_ALARM` requires a Play policy
  declaration that the app is an alarm/clock/calendar-with-exact-timing app and
  is subject to review; misuse risks rejection.
- **Fallback:** any exact-alarm path must gracefully fall back to inexact
  scheduling when permission is unavailable, so reminders still work.

Recommendation: ship the correctly-configured inexact path first (this PR), then
revisit exact alarms as a deliberate, separately-reviewed change.

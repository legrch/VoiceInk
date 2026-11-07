# Automatic audio recovery

The r3 candidate uses an availability-oriented recovery policy. The published r2 retains its earlier explicit-reset behavior.

## Capture and effect lifetimes

Capture activity is tracked independently of ducking, restoration and transcription. The recorder reports capture end immediately after hardware stop, even if a restoration waiter is cancelled. Session identifiers fence stale Stop and teardown callbacks.

A failure suppresses further writes for that cycle. An issued setter keeps its ordinary bounded observation window. Recovery does not interrupt a live capture or an actively pending app write. Once capture is idle and the failed runtime has retired its pending operation, recovery preserves the original journal record in an acknowledgment receipt with reason `automatic_idle_recovery`. It does not relabel the old operation as confirmed or cancelled.

After durable archival and stable UID/control/mute/value checks, the service retires the cycle's timers, listeners and event token, releases only that UID's process-local fence, and creates a fresh runtime and recovery coordinator. The next recording captures the actual output level as its baseline. No guessed old baseline is written during this reset. Missing or unreadable outputs/evidence defer effects; recording and preference editing remain available.

Switching Lower Audio While Recording off/on also attempts idle recovery. It never prevents saving the desired mode. Device-specific retained percentages and transition settings are not reset.

## Tradeoff

macOS property notifications and matching readbacks are not request-specific completion receipts. An old hardware effect may still arrive after the app has retired its cycle; automatic recovery does not prove otherwise. This policy intentionally prioritizes retrying subsequent recordings over keeping a UID indefinitely blocked. It preserves evidence and never treats elapsed time alone as proof of cancellation. A new route or failure is fenced again within its own cycle.

## Diagnostics

The first failed cycle observation is stored in a private `failure-<cycle>.json` sidecar, independently of the active recovery record. It records reason, time, original intent and the before/target/observed levels when available. These sidecars cannot authorize writes or remove a recovery record. `scripts/personal-audio-diagnostics.sh` reads them without changing volume. User data, identifiers and diagnostic files do not belong in release assets or Git history.

## Qualification

Pure lifecycle/journal tests and a signed application build establish source preparation. Speaker/AirPods trials establish only the hardware behavior actually observed. The r3 candidate is not a published release until its separate review and release workflow completes.

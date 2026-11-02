# JamfMigrator: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Jamf Pro 11.34 exception (Jamf, noted 2026-10-28, widened 2026-11-02):** Jamf Pro 11.34.0, the beta and the release, drops a macOS profile’s Self Service `notification` settings on save (11.33 keeps them), so Verify reports such a copy as different. The live check accepts only that field, only on an 11.34.x destination, and Preview and the run report warn on such a profile copied to 11.34.x (`ClassicTransformer.dropsSelfServiceNotifications`). Recheck with every 11.34.x and 11.35; remove when fixed (the exception and the warning).
- **Benchmarks deleted on a beta instance (Jamf):** a Jamf Pro beta instance was seen deleting newly created benchmarks about 3 minutes after creation. That’s a Jamf-side issue, not an app bug. Recheck on the next Jamf Pro release.
- **Computer static group create without `assignments` (Jamf, seen 2026-10-28):** `pro/v3/computer-groups/static-groups` answers 500 without `assignments`, so a create sends `"assignments": []`. Recheck after Jamf Pro updates.

# Google Health fixtures

These are **synthetic examples built from the official v4 reference schemas**, not captured
responses and not copied official example values. Values, names and timestamps were invented for
deterministic tests. Optional fields unrelated to mapping are omitted. `empty-responses.json`
includes omitted collections, empty collections, empty records and rollup buckets without measured
values.

References checked on 2026-11-12:

- [REST reference](https://developers.google.com/health/reference/rest)
- [v4 discovery document](https://health.googleapis.com/$discovery/rest?version=v4)
- [Data types and supported operations](https://developers.google.com/health/data-types)
- [Data point schemas](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints)
- [List filters and pagination](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list)
- [Daily rollup request and response](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/dailyRollUp)
- [Sleep guide](https://developers.google.com/health/data-types/sleep)

Every real-account assumption is marked `// UNVERIFIED:` in the adapter code:

1. `google.ts`: `users/me/identity` returns `healthUserId` for the connected account.
2. `google.ts`: daily rollups accept the nested civil date range and return one-day buckets;
   Google's recorded civil dates agree with the profile timezone, including after travel.
3. `google.ts`: activity intervals do not extend beyond the one-day query lookback.
4. `google.ts`: snake_case filter identifiers, physical sleep end-time filters, exercise civil
   start-time filters and page tokens work as documented. The discovery document uses
   `daily_heart_rate_variability.date`; the HTML reference currently shows
   `dailyHeartRateVariability.date`. The implementation follows discovery and the data type table,
   with no silent fallback that might hide errors.
5. `mapping.ts`: sleep summaries, `metadata.mainSleep` and stage summaries are supplied as
   documented. Choose the longest marked main session ending on the profile's local date, or the
   longest session if no main flag is supplied.
6. `mapping.ts`: sleep efficiency is `minutesAsleep / minutesInSleepPeriod * 100`; compare this
   derived value with the official app before claiming equivalence.
7. `mapping.ts`: activity intervals represent elapsed time in each activity level. Union
   moderately/very-active intervals across sources, clip to the profile's local date, and round
   total elapsed minutes to an integer.
8. `mapping.ts`: exercise resources represent distinct sessions; count by local start date and
   deduplicate identical resource names. Check cross-source duplicates.
9. `mapping.ts`: daily record date and units match the schemas (beats/minute, milliseconds,
   percent). If multiple daily records match, use the first valid one in API order. Check source
   multiplicity and ordering on a real account.
10. `mapping.ts`: rollup buckets use `civilStartTime.date` and documented camelCase payload fields.
    Integer database columns round supplied numeric values.
11. `mapping.ts`: AZM zone sums are earned minutes, already weighted by Google; add the three
    supplied sums without applying another cardio/peak multiplier.

No real-account validation has been completed. Replace or supplement these fixtures with scrubbed
device captures when an account and device are available.

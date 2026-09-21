# Upstream drift review

Review tgstation and Nova guidance after every upstream batch merge, or monthly when no merge occurs. Review the paired Dogmos Rust revision whenever bindings, native artifacts, byondapi, BYOND, or atmosphere ownership changes. Automation reports drift and never rewrites policy.

Record:

```text
Reviewed on:
Reviewer:
Local HEAD:
Nova revision:
Rust revision and bindings digest:
Guide paths/upstream references checked:
Changed authoritative rules:
Retained Meridian/Dogmos deltas and reasons:
Markers or downstream patches now removable:
Follow-up issues or PRs:
```

Compare [.github/guides](../../.github/guides), the [Nova handbook](../../modular_nova/readme.md), build/deployment entry points, and every external source named by [source authority](source-authority.md). Preserve a pinned historical source when its upstream is unavailable and document that limitation.

Dogmos' atmosphere exception is reviewed path by path during upstream merges. Do not use it to discard upstream machinery/gameplay fixes or to restore removed Auxmos algorithms automatically. Contract changes update Rust, generated bindings, native artifacts, game checks, and verification together.

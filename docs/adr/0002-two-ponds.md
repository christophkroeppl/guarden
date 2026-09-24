# Two ponds, never a database container per bed

All production beds share one Postgres (`pond-production`, snapshotted). All staging and preview beds share one other Postgres (`pond-staging`, rebuildable, not snapshotted). A bed gets a database and a role inside the right pond; it never gets its own pond.

Why: running N databases means N containers, N backups, N sets of credentials to restore, and N places for a snapshot ladder to go wrong. Two instances is the smallest number that still separates "this data is irreplaceable" from "this data can be rebuilt from a dump".

Consequences: `weedr` mints one role + one password per bed and reassigns ownership on restore. Production database drop is manual only. Preview database drop is automatic. `pond-staging` loss is recoverable by re-running the extract/restore path from a pinned `pond-production` snapshot. Restoring a dump brings data, never secrets.

Considered: one pond total (loses the production/staging snapshot split), one container per bed (rejected above), sqlite per bed (breaks the "shared state" plugin shape and cross-bed queries).

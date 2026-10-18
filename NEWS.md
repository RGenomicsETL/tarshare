# tarshare 0.2.0

- Migrate all authored tests to native installed tinytest scripts.
- Resolve external `context` at graph construction; add `branch_context` for
  upstream target and dynamic branch expressions. The raw factory requires a
  context value rather than a quoted ambient-state expression.
- Add `shared_context()` for explicit file/model/tool, option, environment,
  locale and method/provider identities.
- Split computation-key records from content-addressed output objects. Identical
  outputs from distinct actions deduplicate without weakening action identity.
- Add public targets CAS callbacks and copy-based file localization so moving
  repositories cannot move another consumer's cache-owned files.
- Add retained owners, reference inspection, explicit retention/release and
  quiescent garbage collection with previews and byte accounting.
- Add bounded visibility retries, failure-injection coverage, and an installed
  two-host filesystem qualification harness. Same-host CI is not NFS evidence.
- Start a versioned v2 layout; do not alter or collect prototype cache entries.

# tarshare 0.1.0

Initial standalone filesystem computation cache and targets factories.

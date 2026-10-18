# Review resolution

This records the implementation in PR #1, not an assertion that every deployment
has been qualified. The package name and GPL-3 license are unchanged.

## #2: declared context and both invalidation layers

`tar_shared(context = ...)` resolves external state while constructing the graph.
Its canonical identity enters both the local command and the shared key.
`branch_context` keeps target-derived expressions visible to targets. The raw
factory rejects quoted external context, which previously could stay unevaluated
when local targets skipped the wrapper.

`shared_context()` snapshots selected file contents or established content IDs,
options, nonsecret environment values, locale and provider identities. Explicit
method definitions use the existing identity walker. Tests cover undeclared
option staleness, declared invalidation in existing/fresh stores, unchanged
resource paths/version labels with replaced bytes, actual dynamic method dispatch,
and branch/seed identities. This does not claim automatic hermeticity.

## #3: retention and collection

Persistent owner references are registered before returning a shared result.
They survive local store deletion and preserve history until explicitly released.
An independent reader can retain an action under its own owner. Successful native
CAS lookup also registers a store that imported compatible metadata and skipped
execution. Writer completion does not imply the reader is finished.

`shared_gc()` previews paths/reasons/bytes, uses the union of references, requires
explicit quiescence for deletion, and excludes active operations with a maintenance
lock. It validates retained metadata before deletion, removes actions before
objects, collects abandoned staging with a grace period, and never deletes lock
paths. Tests cover two owners, history, retained readers, corruption, interrupted
collection, partial publication and active writers. Online GC is intentionally
not the supported contract.

## #4: public CAS composition and ownership

Action records now map to separate content-addressed result objects. Distinct
actions producing the same value can share an object; uploading an object alone
does not publish a successful action. Missing/corrupt data invalidates reuse.

`shared_repository()` uses public `targets::tar_repository_cas()` callbacks.
Native keys have a separate namespace and copy semantics. File factories also
work with a moving native local CAS backend by exporting a private copy first.
Incomplete sidecar exports are rejected. Integration tests exercise both backends,
fresh stores, directory/sidecar ownership, partial upload and orphan recovery.
The native CAS + unchanged metadata example demonstrates when tarshare is not
needed. Copy and verification costs are explicit; this is not zero-copy storage.

## #5: filesystem behavior and qualification

Lock and visibility waits are separately bounded. Hard I/O errors are not retried
as ordinary absence. The installed two-role harness tests shared-key exclusion,
different-key overlap, writer crashes before/after publication, visibility and
retained-reader maintenance, recording host/system/package/profile identities.
CI tests this harness on one host only. **Real multi-host NFS/SMB qualification
remains open until that exact profile is run and its reports inspected.**

## Corrections retained from the initial review

Native CAS and metadata sharing already exist. A computation-key index is a
different capability, not a replacement for them. `consistent = FALSE` controls
read-after-write visibility handling, not distributed mutual exclusion. The native
single-store collector warns about historical and colleagues' objects and cannot
be substituted for cross-owner retention. Files still need compatible readers;
Nextflow tasks are not universally hermetic or pinned to immutable image digests.

Upstream contracts:
- https://docs.ropensci.org/targets/reference/tar_repository_cas.html
- https://docs.ropensci.org/targets/reference/tar_repository_cas_local_gc.html
- https://docs.ropensci.org/targets/reference/tar_meta_sync.html
- https://docs.seqera.io/nextflow/cache-and-resume
- https://r-lib.github.io/filelock/

## Validation ownership

Current tests are under `inst/tinytest/`; CI runs the exact branch revision on
Linux, Windows and macOS. Check artifacts contain executed test and package logs.
`validation/original/` preserves the prototype record only. Passing CI is not a
multi-host qualification result or a throughput benchmark.

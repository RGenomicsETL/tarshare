# Initial implementation review

This review separates the implementation in this pull request from follow-up
work. No CAS adapter, garbage collector, or distributed-lock protocol is claimed
to exist here.

## Findings accepted

**Computation identity, not another scheduler.** `targets` already supplies
content-addressable output storage and metadata synchronization. The additional
lookup here is from an expression, its referenced inputs, and declared context
to a result, even when the receiving store has no metadata. The output target's
name is excluded. Input symbols and expression structure are not normalized;
this is not a test of arbitrary semantic equivalence.

**Undeclared state can return stale results.** Static R analysis cannot establish
that a command has no undeclared inputs. Options, locale, environment variables,
external executable builds, resource revisions, database snapshots, dynamically
selected methods, and relevant hardware settings must be explicit inputs or
context. Package versions are not proof of binary or model identity. The README
now demonstrates stale reuse and the declared-context alternative. Context also
needs to participate in local `targets` invalidation: a hidden-state lookup only
inside a skipped wrapper is never evaluated.

**Files first for large, portable artifacts.** File bundles retain their byte
identity and sidecars without relying on serialization of a live R object.
Self-contained R values remain supported within the keyed R/package environment.
Neither files nor RDS promise arbitrary cross-version semantic compatibility;
saving a version-sensitive R object to a file does not make it portable.

**Retention must be implemented before an unmanaged shared deployment.** The
current backend has no garbage collector. Cache-owned file paths outlive a
single wrapper call and can remain referenced by several stores and external
consumers. Age-based deletion or one-store reachability alone is unsafe.

**Distributed behavior is unqualified.** Two-process tests on one host are not
cross-host evidence. Lock support, visibility, rename behavior, process failure,
and readers retaining paths all need testing on the actual shared filesystem.
The current backend has no NFS visibility retry protocol.

## Corrections to the external review

- `tar_repository_cas()` is an experimental storage interface, not a
  pre-execution action-result lookup. It cannot by itself replace the action
  index needed by a fresh store. A thin integration still needs an explicit
  mapping and tested publication/restore behavior.
- `tar_repository_cas_local_gc()` uses one store's current `tar_meta()$data`.
  Its documentation explicitly warns that historical and colleagues' objects
  may be deleted. It is not automatically a safe collector for independent
  stores, and must not be pointed at this backend's `entries/` directory.
- `consistent = FALSE` concerns read-after-write visibility. It is not a
  distributed mutex, a writer fencing mechanism, or a fix for an unsupported
  filesystem lock. NFS locking support varies; it is not universally absent.
- Nextflow is not automatically hermetic merely because inputs are declared.
  Its task hash includes a container image **if applicable**, as well as other
  task metadata. Its documentation also discusses mutable inputs and
  nondeterminism. Do not claim that every task uses a pinned container digest.
- Keep the chosen package name and GPL-3 license. Renaming and relicensing are
  owner decisions, not correctness fixes.

## Implementation work still open

1. A public-API CAS integration with an action index distinct from object hashes.
   In particular, do not just remove the `repository = "local"` restriction:
   a backend may move a returned file, invalidating the shared entry that owns it.
2. Coordinated retention across stores and active file consumers, with a
   non-destructive preview and orphaned-stage cleanup. Do not delete lock files
   while another process may still hold or acquire locks on them.
3. A clearer declared execution-context interface and regression coverage of
   hidden state, method providers, and local skipping. An explicit declaration
   is a user contract, not proof that an arbitrary R expression is hermetic.
4. Deployment-specific multi-host qualification, including simultaneous
   writers, killed writers, stale reads, and readers spanning cleanup.

## Sources checked

- https://docs.ropensci.org/targets/reference/tar_repository_cas.html
- https://docs.ropensci.org/targets/reference/tar_repository_cas_local.html
- https://docs.ropensci.org/targets/reference/tar_repository_cas_local_gc.html
- https://docs.ropensci.org/targets/reference/tar_meta_sync.html
- https://r-lib.github.io/filelock/
- https://docs.seqera.io/nextflow/cache-and-resume
- https://seqera.io/blog/nextflow-global-cache/

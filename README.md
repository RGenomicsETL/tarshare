# tarshare

Reuse a computation across independent `targets` stores without copying their
pipeline metadata. A new store, or a renamed output target, can retrieve an
existing result when the declared computation identity is unchanged.

`targets` already provides content-addressed output storage and metadata sharing.
For compatible copies of the same pipeline, those features may be sufficient.
`tarshare` adds an **action-key lookup before the wrapped computation executes**;
it does not replace the scheduler, dependency graph, or local target metadata.
The runnable [native CAS example](inst/examples/native-cas-metadata.R) demonstrates
the upstream alternative without using tarshare.

## Start with an ordinary pipeline

```r
library(targets)
library(tarshare)

cache <- shared_cache("/shared/r-cache")

summarise_values <- function(x) {
  message("Computing")
  c(mean = mean(x), spread = stats::sd(x))
}

list(
  tar_target(values, c(3, 5, 8, 13)),
  tar_shared(summary, summarise_values(values), cache)
)
```

Two fresh stores can reuse the wrapped computation:

```r
targets::tar_make(store = "_targets_a")
targets::tar_make(store = "_targets_b")
```

The wrapper is still dispatched and its dependencies loaded on a shared hit.
The target's own name and local store are excluded from the action key; arbitrary
renaming or rewriting of command symbols is not semantic-equivalence analysis.
See [independent-stores.R](inst/examples/independent-stores.R) for an executable
example which verifies the number of actual computations.

`shared_run(expression, cache)` provides the same reuse directly from R.

## Declare external state at graph construction

Arbitrary R code is not automatically hermetic. Code analysis captures referenced
R values and helper functions, but cannot discover every environment variable,
option, dynamic method, executable, network response, or database state.

There are two invalidation decisions: local `targets` decides whether to dispatch
the wrapper; the shared cache then decides whether its action key exists.
Since 0.2.0, `tar_shared(context = ...)` is evaluated **when the graph is built**.
Its canonical identity is embedded in the command, so changed declarations affect
both decisions, including when the old local target would otherwise be skipped.

```r
tar_shared(
  result,
  getOption("analysis.scale"),
  cache,
  context = shared_context(options = "analysis.scale")
)
```

Without this declaration, changing that option can return a stale result. Prefer
passing resolved values directly into your computation instead of reading ambient
state again after the snapshot. Resources must remain immutable during execution.

`shared_context()` accepts named values and snapshots selected options, nonsecret
environment variables, locale, provider packages, and file contents:

```r
execution <- shared_context(
  image = "immutable-image-digest",
  database = "immutable-database-snapshot",
  files = list(model = "model.rds", executable = "tool"),
  options = "analysis.scale",
  env = "MODEL_VARIANT",
  locale = TRUE
)
```

Ordinary files are hashed once per snapshot; `shared_file(path, id = immutable_id)`
reuses an established identity without reading the bytes. Directory resources
require explicit immutable IDs. A filename or unchanged version string does not
identify a replaced model or executable. Declare dynamic S3/S4 method definitions
or their provider packages explicitly. `packages` includes installed package and
hard-dependency identities, not proof that same-version source was never altered.
Never use credentials as scientific inputs or write them into context.

Target-derived values are separate: use **`branch_context`** for upstream targets
and dynamic branches. It remains an unevaluated expression visible to `targets`.

```r
tar_shared(
  draws, stats::rnorm(2), cache,
  pattern = map(replicate_id),
  branch_context = list(replicate = replicate_id)
)
```

For `tar_shared_raw()`, pass a resolved value to `context` and a quoted expression
to `branch_context`. R version/platform, implementation version, declared provider
identities, code, referenced inputs, and seed all participate in reuse. RNG uses
a deterministic action-derived stream and restores the caller's state. Distinct
replicates require distinct inputs, branch context, or seeds.

## File bundles and R values

For large portable artifacts, write the files and sidecars below `shared_path()`
and return their paths or the complete bundle directory:

```r
tar_shared(
  bundle,
  {
    writeLines("data", shared_path("data.txt"))
    writeLines("index", shared_path("data.idx"))
    shared_path()
  },
  cache,
  format = "file"
)
```

Returned cache files are **immutable**: downstream steps write new outputs, never
modify these paths. Relative layout, names, empty directories and sidecars are
preserved. Symbolic links and outputs outside staging are rejected. Staging paths
embedded inside file contents are not rewritten.

`format = "rds"` supports self-contained R values in the keyed execution
environment. Live environments, external pointers, connections and output
functions are rejected. Package-dependent objects still require compatible
readers and method providers; neither RDS nor a file format guarantees that.
An R object containing a temporary path does not preserve that file.

Plain character inputs remain ordinary values. `shared_file()` opts into
content identity rather than physical-location identity. Only use that when
output semantics do not depend on the filename; put meaningful labels in context.

## Action index and content-addressed objects

The v2 filesystem layout separates:

- `actions/`: computation identity to content-object mapping;
- `objects/`: immutable R values or complete file bundles addressed by content;
- `native/`: a separate namespace for native targets CAS keys;
- `refs/`: retained owner references; `locks/`: persistent lock paths;
- `exports/`: disposable file copies supplied to external repositories.

Distinct actions producing identical serialized values or identical bundles can
share one content object. The action is published only after its object is
complete and readable. A crash between object and action publication leaves an
unreferenced object, not a successful action. Missing or corrupt data cannot be a
shared hit. Hard storage failures propagate rather than becoming successful work.

The public adapter composes with `targets::tar_repository_cas()`:

```r
repository <- shared_repository(cache, consistent = FALSE)
tar_shared(bundle, make_bundle(), cache, format = "file", repository = repository)
```

Other public CAS repositories are also accepted. A nonlocal file result is copied
to private export staging before upload because a repository may move its input.
Return the bundle directory or every sidecar; an incomplete export is rejected.
The original shared object remains in place for other consumers.

This ownership protection has an I/O cost: export localization reads and writes a
full bundle; the copy-based adapter also copies it into native storage. Native
keys are not silently equated with tarshare object hashes, so those namespaces can
retain separate copies. This is not a zero-copy backend. `verify = TRUE` hashes
cached file bytes on lookup. Disable it only when immutability is enforced
externally; record integrity and bundle completeness are still checked.

## Retention and explicit maintenance

Every successful shared result is pinned for its owner before returning. The
default owner is the running targets store, or the working directory for a
standalone call; `shared_run(owner = ...)` can give another explicit identity.
Native CAS lookup also registers a consumer when compatible metadata skips work.

References accumulate deliberately, including history. Deleting a store does
**not** prove that a report or another reader has finished with its files. Inspect
`shared_references(cache)` and use `shared_retain(cache, keys, owner)` to preserve
an action for an independent consumer before releasing its previous owner.

```r
shared_references(cache)

# Stop pipelines and external readers first. Release only obsolete references.
shared_release(cache, shared_owner(store = "/old/store"), quiescent = TRUE)
plan <- shared_gc(cache) # preview: paths, reasons, bytes; deletes nothing
removed <- shared_gc(cache, dry_run = FALSE, quiescent = TRUE)
attr(removed, "removed_bytes")
```

Deletion requires explicit quiescence, not just a writer lock. The exclusive
maintenance gate excludes in-flight operations; persistent references protect
paths used after a wrapper returns. The assertion cannot detect unmanaged readers.
Do not release an owner while its retained history still needs the outputs.

Collection uses the union of owner references, aborts on invalid retained
metadata, removes actions before unreachable objects, and can resume after
interruption. Unpublished stages and export copies have an age grace. Lock files
are never removed. The native single-store collector must not be pointed at this
cache: it cannot see tarshare's retained references. Capacity monitoring and the
maintenance schedule remain operator responsibilities; there is no automatic
quota eviction or online garbage collector.

## Shared filesystems and failure behavior

All consumers of cache-owned paths need the same mounted path. The selected
filesystem must support the locks and same-filesystem atomic rename used here.
`timeout` bounds lock acquisition; `visibility_timeout` and `poll_interval` bound
retries for a missing/incomplete entry. Atomic namespace publication is not a
power-loss durability guarantee. NFS/SMB behavior depends on the actual server,
client and mount configuration; one-host subprocess tests do not qualify it.

The [two-host qualification harness](inst/qualification/README.md) exercises
competing writers, different-key overlap, killed writers before/after publication,
visibility and retained-reader maintenance. CI exercises the harness on one host
and labels that result **same-host diagnostic only**. A real multi-host profile
still needs its own execution record; no universal NFS safety is claimed.

Use only a cache shared with trusted collaborators. R deserialization is not a
sandbox, and filesystem permissions determine who can publish or alter objects.
Cloud object storage, hostile-writer isolation and online reader leases are not
implemented.

## Migrating from the initial 0.1.0 prototype

Recreate configurations with `shared_cache()`. The new backend uses `v2/`, leaving
old `entries/` and locks untouched; it neither imports nor collects the old layout.
Retire old cache data separately only when its consumers no longer require it.
Move target/branch expressions from `context` to `branch_context`. External
context now takes resolved graph-time values, including in the raw factory.

## Development

Tests are native **tinytest** scripts installed under `inst/tinytest/`, with the
standard `tests/tinytest.R` entry point. No active testthat suite or compatibility
wrapper remains. After installing the package:

```r
tinytest::test_package("tarshare")
```

Regenerate help from the R sources with `roxygen2::roxygenise()`, then run
`R CMD build .` and `R CMD check --no-manual --as-cran tarshare_0.2.0.tar.gz`.
CI checks Linux, Windows and macOS, verifies generated help is committed, and
retains check artifacts. Historical prototype logs under `validation/original/`
are not results for the current revision. See [REVIEW.md](REVIEW.md) for the review
resolution and [NEWS.md](NEWS.md) for interface changes.

License: GPL-3.

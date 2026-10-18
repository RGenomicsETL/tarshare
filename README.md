# tarshare

**Reuse declared computations across independent `targets` stores.**

Avoid rerunning the same expensive preprocessing or model-building step in a
second project, even when its local store is empty or its output target is
renamed. This is an experimental, opt-in computation cache, not a claim that
arbitrary R expressions can be cached soundly without declared inputs.

`tarshare` is a GPL-3 R package for a shared filesystem cache. A cache entry is
selected by a computation and its inputs, so changing a target name or starting
with an empty `_targets` directory can still reuse the result. It supports R
values and bundles of output files, with an explicit `tar_shared()` target
factory and a standalone `shared_run()` interface.

The motivation is the cross-run reuse described in
[Seqera's Nextflow Global Cache announcement](https://seqera.io/blog/nextflow-global-cache/).
`tarshare` implements an opt-in R interface. It does not replace the `targets`
scheduler, import another pipeline's metadata, or provide Nextflow's cloud
integration.

## Install from source

From a source checkout with the dependencies in `DESCRIPTION` installed:

```sh
R CMD INSTALL .
```

Repository: `RGenomicsETL/tarshare`. The initial implementation is under review;
there is no released or production-qualified version yet.

## Use with targets

Create `_targets.R`:

```r
library(targets)
library(tarshare)

cache <- shared_cache("/shared/r-cache")

summarise_values <- function(x) {
  message("Computing the summary")
  c(mean = mean(x), spread = stats::sd(x))
}

list(
  tar_target(values, c(3, 5, 8, 13)),
  tar_shared(summary, summarise_values(values), cache = cache)
)
```

Run it with two independent local stores:

```r
targets::tar_make(store = "_targets_a")
targets::tar_make(store = "_targets_b")
```

The second store still dispatches the target wrapper and loads its dependencies.
The wrapper can retrieve the shared result before running `summarise_values()`.
A shared hit is therefore distinct from a native `targets` skipped target.
Each store retains its own ordinary target metadata.

All participating workers need access to the same cache path. Choose a cache
directory outside disposable per-run work directories.

## Use directly from R

```r
library(tarshare)

cache <- shared_cache(tempfile("shared-cache-"))
values <- c(3, 5, 8, 13)

first <- shared_run(mean(values), cache = cache)
second <- shared_run(mean(values), cache = cache)
stopifnot(identical(first, second))
```

Changing `values`, the command, or a referenced helper changes the computation's
key. `shared_run()` captures the expression you pass; use the same expression
when you want to look up the same computation.

## File inputs and output bundles

A plain character path is an ordinary R value. Wrap an input in `shared_file()`
to declare that its content identifies the input independently of its location:

```r
input <- shared_file("data/measurements.txt")

files <- shared_run(
  {
    x <- scan(input, quiet = TRUE)
    summary <- c(n = length(x), mean = mean(x))
    rds <- shared_path("summary.rds")
    text <- shared_path("summary.txt")
    saveRDS(summary, rds)
    writeLines(format(summary), text)
    c(rds = rds, text = text)
  },
  cache = cache,
  format = "file"
)
```

With no `id`, `shared_file()` hashes the file's content. If an input registry or
upstream transfer already provides an immutable content identifier, reuse it:

```r
input <- shared_file(local_path, id = registered_sha256)
```

Supplying `id` avoids another input hashing pass. The caller owns the assertion
that the identifier denotes the current bytes. IDs must be unambiguous within
the cache; include the source/key when using provider-local version IDs.
Use the same identifier for
identical content at another path and a different identifier when content
changes. Keep the `shared_file` value intact until the command consumes it.

Location independence is an explicit contract. If a program uses a basename,
sample label, directory name, or other path-derived information in its result,
include that information in `context` or pass it as an ordinary dependency.

For `format = "file"`, create outputs under `shared_path()` inside the command
and return the complete character vector of paths needed by consumers. Include
indexes and sidecars so local targets tracking can observe their loss. Directory
outputs and all files beneath them are retained together. Existing files
elsewhere cannot be imported by returning their paths, and arbitrary paths
embedded inside R objects or file contents are not rebased.

Hits return the cache's own files. Treat them as immutable; downstream commands
write their own outputs. Files are not copied into each local targets store.
Prefer `format = "file"` for large artifacts and complete portable file formats.
Their byte identities do not depend on R serialization, but interpreting the
bytes still requires compatible tools and schemas. An RDS written as a file
is still an R-serialized object.

Use `format = "rds"` for self-contained values in the keyed R/package environment,
not as a cross-version persistence format. S3/S4 class and method providers
must be declared in `packages` or `context` when not statically discovered. Live environments, connections
and external pointers are unsupported as dependencies or outputs. Cached R
outputs also cannot contain functions.

## What determines reuse?

The action key combines:

- The captured command and statically discovered referenced dependency values.
- Referenced helper definitions and their captured dependency values.
- R runtime information and declared package identities.
- Explicit `context`, output format, and the computation's `seed` argument.

The target's own name, its local store name, and a `shared_file()` input's locator
are excluded. An unchanged action can be reused by another target or store.
This is syntactic and dependency-based equivalence; mathematically equivalent
expressions need not produce the same key. Renaming input symbols can also
change the key; only the output target name is excluded automatically.

External state needs an explicit input. Declare relevant package names using
`packages`, and use `context` for a container image digest, executable or model
release, environment settings, or other information not represented by the R
command and its dependencies:

```r
tar_shared(
  result,
  transform_data(values),
  cache = cache,
  context = list(model = model_release, image = image_digest),
  packages = c("myAnalysisPackage")
)
```

Package versions do not identify independently replaced executables or mutable
model files. Resolve those identities before constructing the computation.
Automatic discovery follows static references. Dynamic `get()`/`eval()` and
S3/S4 method selection can reach definitions it cannot see. Include custom
methods in `context`, for example `context = list(method = my_generic.my_class)`.
Declare their provider in `packages` when its version/build identifies the
selected methods. Otherwise changed methods can reuse stale results. Declare
options, locale, environment variables and external tools in `context` too.
There is no correctness promise for undeclared dependencies. A nonempty
`context` list does not prove that the declaration is complete.

### A stale-result example and its correction

This deliberately unsafe command reads an undeclared option. Changing the option
does not change the action key:

```r
cache <- shared_cache(tempfile("context-demo-"))
options(tarshare.demo.scale = 2L)
unsafe <- function() shared_run(getOption("tarshare.demo.scale"), cache)
unsafe() # 2L
options(tarshare.demo.scale = 3L)
unsafe() # still 2L: the option value was not declared

safe <- function() shared_run(
  getOption("tarshare.demo.scale"), cache,
  context = list(scale = getOption("tarshare.demo.scale"))
)
safe() # 3L
options(tarshare.demo.scale = 4L)
safe() # 4L
options(tarshare.demo.scale = NULL)
```

A model file replaced at the same pathname or an executable replaced without
changing its version string has the same failure mode. Use a content identity
or immutable build/snapshot identifier, not merely a path or mutable tag.

There are **two invalidation layers**: the local `targets` decision to dispatch
the wrapper, then the shared action lookup. A call to `getOption()` or
`Sys.getenv()` only inside `context` will not run when the local target is
already skipped. Resolve external state into a tracked value when `_targets.R`
is sourced, or use an upstream target with an appropriate refresh cue:

```r
execution <- list(scale = getOption("analysis.scale", 1L))
list(
  tar_target(values, c(3, 5, 8, 13)),
  tar_shared(summary, mean(values) * execution$scale, cache,
             context = execution)
)
```

Changes to that tracked `execution` value can invalidate both layers. Resolve
file and executable identities at a trusted boundary without hashing large
artifacts again inside every target.

## Randomness and deliberate recomputation

The cache controls R's random stream using its key and `seed`. Keep explicit
seeds supplied to scientific functions or external programs among the command's
dependencies. For different random replicates, use distinct `seed` values or
include a replicate identifier in `context`:

```r
draw <- shared_run(
  stats::rnorm(10),
  cache = cache,
  seed = 42L,
  context = list(replicate = 1L)
)
```

`targets::tar_invalidate()` causes the local wrapper to run again; the same
action key can still hit the shared cache. To request a new computation, change
an explicit generation in `context`:

```r
shared_run(mean(values), cache, context = list(generation = "rerun-2"))
```

Keep that generation stable to reuse the deliberately recomputed result.

## Storage and concurrency

Each key has a filesystem lock. A writer computes into a temporary staging
directory and publishes a completed entry by renaming that directory. A failed
computation does not publish a reusable entry. Competing writers for the same
key wait for the lock and check for an existing result before computing.

`shared_cache(path, verify = TRUE, timeout = Inf)` verifies cached file content
on hits by default. Verification reads output bytes and can matter for large
files. `verify = FALSE` skips per-hit content digest verification and assumes
the cache is kept immutable. It does not change input identity.

The filesystem must support the locking and same-filesystem rename operations
used by the backend. Shared mounts need deployment-specific qualification.
The existing tests exercise processes on one local host, not a multi-host NFS
or SMB deployment. Lock support varies by filesystem and mount configuration;
this backend does not implement a visibility-retry protocol. Filesystem locks
alone do not establish distributed cache safety.

This version provides no cache garbage collection or removal API. Keep entries
available while local targets metadata or downstream work refers to their files.
Do not deploy an unbounded shared cache without an operator-owned capacity and
retention plan. Do not apply one store's native CAS collector to this cache:
it does not know the action index, other stores, or active file readers.

The backend stores one bundle per computation key. It does not deduplicate
identical output bytes produced by different computation keys. See `REVIEW.md`
for the CAS-integration and coordinated-retention work still required.

## Relationship to targets CAS

The native
[`tar_repository_cas()` interface](https://docs.ropensci.org/targets/reference/tar_repository_cas.html)
stores outputs by their content hashes. Its documentation describes sharing
those objects together with `_targets/meta/meta` to preserve results across
workflow checkouts. The metadata connects target definitions to saved outputs. `targets` also
provides `tar_meta_upload()`, `tar_meta_download()`, and `tar_meta_sync()` for
cloud metadata. Sharing compatible pipeline code, metadata, and retained CAS
objects is already an upstream-supported reuse route; use it when that solves
the problem.

`tarshare` instead performs an explicit action lookup inside a scheduled
command. This enables reuse with a fresh local metadata store, while adding its
own computation key. It uses public target construction APIs and leaves
`targets` metadata under `targets` control. It does not promise a transparent
pre-dispatch cache lookup for an arbitrary existing pipeline.

A native CAS adapter is not implemented yet. CAS upload/download/exists methods
operate on output objects, not on pre-execution computation identities. A thin
adapter still needs an action-to-object mapping. Its file handling must not
move or remove the cache-owned files that other callers already hold.

The upstream `consistent = FALSE` setting retries visibility checks on stores
without strong read-after-write consistency; it does not provide distributed
locking. The built-in `tar_repository_cas_local_gc()` collects against a single
store's current metadata and explicitly may remove historical or colleagues'
objects. Neither feature is a drop-in solution for cross-store retention.

## Examples and development

The installed examples use toy numeric data and create temporary directories:

```r
source(system.file("examples", "values-and-files.R", package = "tarshare"))
source(system.file("examples", "independent-stores.R", package = "tarshare"))
```

Integration checks cover independent stores, renamed targets, changed upstream
values, runtime context, dynamic branches, reproducible random streams, and file
bundles. The supplied archive includes a historical local Linux check record
(R 4.5.3, targets 1.12.0, 195 passing expectations). That record is not a check
of this pull request. Newly added context-contract tests and current hosted
checks must be reported separately. No throughput or distributed-filesystem
performance claim is made.

Future work includes cloud backends and a stable public `targets` runtime
identity hook for integration before command dispatch. Those are outside the
current filesystem interface.

## License

GPL-3.

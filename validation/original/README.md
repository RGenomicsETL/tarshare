# tarshare 0.1.0: validation record

`tarshare` is a generic GPL-3 R package for reusing computations across
independent `targets` stores through a shared filesystem cache.

## Result

The package passed the following command on 2026-10-17:

```sh
R CMD check --no-manual tarshare_0.1.0.tar.gz
```

The final check status was **OK**. The test suite reported **195 passing
expectations, 0 failures, 0 warnings, and 0 skips**. Package installation,
namespace and dependency checks, documentation checks, and examples also passed.
The two installed examples were executed successfully as separate runnable
examples.

`R-CMD-check.log` and `testthat.Rout` in this directory are the recorded outputs.
After checking, one README sentence was clarified to identify `seed` as a
computation argument. The package was then rebuilt. Byte comparisons confirmed
that the final archive differs from the checked archive only in that README
sentence and the automatically generated packaging timestamp. All R code,
help files, examples, tests, and dependency declarations are identical.

## Source and environment

- Source commit: `2999a54404b6a56c52bc40b88e137b1a4307f1d3`
- Source files: 26 tracked files; the source tree was clean at packaging.
- R: 4.5.3 (2026-03-11)
- Platform: x86_64-conda-linux-gnu, Ubuntu 24.04.3 LTS
- targets: 1.12.0
- digest: 0.6.39
- filelock: 1.0.3
- vctrs: 0.7.3
- testthat: 3.3.2
- callr: 3.7.6
- processx: 3.9.0
- ps: 1.9.3
- codetools: 0.2.20
- roxygen2: 8.1.0

SHA-256 of the final installable archive, `tarshare_0.1.0.tar.gz`:

```text
5d018322577fc0acfd01b7deb3fea8634a668df31097281720fb8322634ce193
```

## Behavior exercised

- Reuse across independent stores and renamed output targets.
- Native local skipping on subsequent runs, changed inputs, and recovery of
  earlier shared results when inputs revert.
- Dynamic branches, including partial reuse, changed file identities, and
  relocation of identical file inputs.
- Referenced helper definitions, captured values, explicit context, package
  identities, and reproducible random streams.
- Preservation of file identities through base R and vctrs vector operations.
- Complete file bundles, directories, sidecars, empty directories, deleted
  members, and same-size content corruption.
- Repair of corrupt metadata and publication only after successful computation.
- Rejection of unsupported live resources and output paths outside staging.
- Two concurrent R processes requesting the same key: one actual computation.
- A killed writer: no completed entry, followed by successful recovery in a
  fresh process.
- The default targets callr subprocess, in addition to direct R execution.

## Scope

Execution validation covers the local Linux environment above. The repository
includes GitHub Actions checks for Linux, Windows, and macOS; those hosted jobs
have not yet run. The declared older minimum versions have not been tested in
this session. Shared-filesystem deployments still need qualification of their
locking and rename behavior. No cloud-backend or throughput benchmark was run.

The implementation is opt-in. A shared hit happens inside a scheduled target
wrapper. Ambient process state, dynamic lookup, custom method dispatch, external
executables, and mutable resources need explicit identities or context. Cached
file paths refer directly to immutable cache-owned files. There is no garbage
collection API in this version. See the package README and help for the full
interface and limits.

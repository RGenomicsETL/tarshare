# Validation records

`original/` preserves the initial 0.1.0 prototype checks. Those results do not
validate subsequent runtime changes or the tinytest migration.

Current GitHub Actions runs check the exact PR revision on Linux, Windows and
macOS with `R CMD check --no-manual --as-cran`. The native tinytest runner exercises
installed code and examples. Per-platform check artifacts retain the package
source used, `00check.log`, and `tests/tinytest.Rout` (or `.fail`). Consult these
artifacts and the commit identity rather than treating this file as a pass claim.

Generated help is produced by roxygen2 from `R/` and checked for drift. Filesystem
qualification is separate: the CI harness result is explicitly same-host only.
See `inst/qualification/README.md` for the two-host procedure. No actual NFS/SMB
profile or large-artifact throughput result has been recorded here.

# Qualify an actual shared filesystem

Use two development hosts with the same installed tarshare revision, R and package
identities, and the same mounted path. Use a new run ID in an explicitly disposable
directory. No connections, mounts, credentials or production data are provisioned.
Record the actual filesystem/server/client versions and mount options in `profile`.

On host A:

```r
source(system.file("qualification", "shared-filesystem.R", package = "tarshare"))
a <- qualify_shared_filesystem(
  root = "/shared/disposable-tests", run_id = "trial01", role = "a",
  profile = "REPLACE with filesystem/server/client versions and mount options",
  revision = "REPLACE with the installed source commit", timeout = 120
)
```

Start the same command on host B with `role = "b"`, within the timeout. Both roles
wait at bounded barriers; each run ID is single-use. The harness refuses two equal
host names by default. Only use `allow_same_host = TRUE` to debug the harness; its
report then says `same-host-diagnostic-only` and is not multi-host evidence.

The harness checks same-key writer exclusion, different-key overlap, actual
computation counts, killed writers before/after publication, complete data plus
sidecars, cross-participant visibility, maintenance exclusion and retained-reader
survival. It finally releases its own synthetic consumers and collects their data.
A failure or timeout is a failed profile, not permission to relax an invariant.

Reports, system/package details and failure markers remain under
`root/tarshare-qualification-trial01`. Inspect both `.report` files and the supplied
profile before describing a deployment as qualified. Host names alone do not prove
physical separation: the operator must really select two hosts on the intended
shared mount. These are bounded tests, not a proof of all failure modes or a
power-loss durability test. Do not publish private host/mount details unreviewed.

CI runs the same harness locally to test the test program. No actual NFS/SMB
multi-host result is currently supplied by the repository.

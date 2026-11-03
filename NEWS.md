# tarshare (development version)

* `shared_serve()` serves a cache directory to hosts without a shared
  filesystem, over 'nanonext' (`tcp://`, `tls+tcp://`, `ipc://`).
  `shared_cache()` accepts the store's URL; each host keeps a local mirror.
  The store resolves each key to one result (put-if-absent publication), and
  lets one client compute a key at a time under a lease bound to that client's
  connection, released at once when the client exits. Results are pinned in
  the same step as the lookup. Store clients read their own mirrors, so
  `shared_gc()` and `shared_release()` on the store host's directory do not
  pull files from under them. Frames use the ducknng v1 envelope. The protocol
  is modelled in TLA+ in `design/spec/` and checked with TLC.
* A path to a file result is now identified by its object id and its path
  inside the bundle, not by where the cache is mounted, so downstream keys agree
  across hosts and mounts. This and the version change give every key a new
  value once.

# tarshare 0.1.0

Initial public release: cross-store computation reuse for `targets`, explicit
execution context, content-addressed results and file bundles, public CAS
integration, retained-owner garbage collection and tinytest coverage.

Four vignettes (get started, computation identity, file outputs and inputs,
operating a cache) and a pkgdown site at <https://rgenomicsetl.github.io/tarshare/>.

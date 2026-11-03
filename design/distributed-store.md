# Distributed tarshare: design options

Status: option D's first two phases are implemented: `shared_serve()`, store
URLs in `shared_cache()`, and location-independent identity for cache-owned
paths. See [As built](#as-built). The protocol is specified in TLA+ in
[`spec/`](spec/) and model-checked; see [Specification](#specification). The
lease experiment is [`spikes/nng-lease.R`](spikes/nng-lease.R).

## Summary

The aim is an open **global cache for targets**. Seqera introduced the same
idea for Nextflow alongside 26.10 (October 2026) as Global Cache, a licensed
plugin in early access: a task is reused across runs, pipelines and users
wherever it ran. tarshare already has what makes that
work, namely a key that ignores the store and the target name, an action
index, and content-addressed objects. What it lacks is a backend that works
across hosts. The three are, respectively, Seqera's "drop the session id and
process name", its task lookup, and "the work directory is the cache".

tarshare's action index (`actions/`) and its content-addressed objects
(`objects/`, `native/`) mirror a Bazel remote cache. Objects are immutable and
named by their hash. A distributed version therefore needs one serialization
point for a small amount of metadata (action records, pins, single-flight
leases) and some way to move bytes. Everything else is the existing code.

Recommendation:

1. **Step 0, needed by every option:** put the filesystem behind an internal
   storage seam of about ten verbs, without changing behaviour. The existing
   tinytests are the acceptance test.
2. **Then option D:** a small nanonext store server. One long-running R process
   owns an ordinary tarshare cache directory on its local disk. Clients reach
   it over `tls+tcp://` (or `ipc://` in tests) and keep a local mirror for file
   outputs. A single-flight lease is bound to the client's NNG connection, so
   a writer that dies frees its key without a TTL and without heartbeats. An R
   process busy in `eval()` could not send heartbeats anyway. The spike
   confirms this on nanonext 1.10.4.
3. **Take three things from Seqera now**, because they are cheap before
   release and expensive after: an identity for cache-owned file paths that
   does not depend on where the cache is mounted, ordered read-only secondary
   caches, and promotion between caches.
4. **Speak ducknng's frame envelope on the wire.** The server can then later be
   rebuilt as a DuckDB-backed index in the style of CanardAbsurd (option F)
   with bytes on a bucket through Ropendal. That is an open equivalent of
   Seqera's cloud-prefix deployment, and clients need no change.

User-facing additions: a URL form of `shared_cache()`, one new function,
`shared_serve()`, and later `shared_push()`. `shared_run()`, `tar_shared()`,
`shared_repository()` and the retention contract stay as they are. The key
changes once, for computations that consumed cache-owned paths (see
[Identity](#identity-of-cache-owned-paths)).

## As built

The first two phases of option D, in `R/serve.R`, `R/remote.R` and `R/wire.R`,
with `inst/tinytest/test-store.R`:

- **Server.** `shared_serve(path, url, tls, token)` is a single-threaded nanonext
  `rep` loop over an ordinary cache directory. It monitors pipes, binds leases
  to `pipe_id()`, and grants leases only to pipes it has seen open. A lease
  also holds the key's `action-<key>` file lock, so filesystem clients of the
  same directory and store clients exclude each other. Each request holds the
  shared maintenance lock.
- **Client.** `shared_cache(url, tls, mirror, chunk_size)` returns a plain list,
  safe to embed in target commands; the socket opens lazily per process and is
  reopened after a fork. The token comes from `TARSHARE_TOKEN` at connection
  time. The mirror resolves per host, with one subdirectory per URL.
- **Compute path.** A granted claim runs the unchanged filesystem
  `shared_run()` on the mirror. The miss path therefore has a single
  implementation, and the existing fault-injection tests still cover it.
- **Wire.** The ducknng v1 envelope (22-byte header). Methods are
  `tarshare.claim`, `publish`, `abandon`, `have`, `put_begin`, `put_chunk`,
  `put_end`, `manifest` and `get_chunk`. Control payloads are `name<TAB>value`
  lines rather than JSON (no JSON parser in the dependency set), followed by
  a manifest or raw bytes.
- **No deserialization on the server.** It verifies sizes, SHA-256 and that the
  record hashes to the object id. It keeps a server-written `manifest.tsv` per
  object, generated on first use for objects that filesystem clients
  published.
- **Administration.** Run `shared_gc()`, `shared_release()`,
  `shared_references()` and `shared_retain()` against the store's directory on
  its host. There are no admin verbs on the wire yet; these functions refuse a
  URL.
- **Collection needs no grace period.** `publish` refuses an object that is not
  committed, and the client uploads it again. The spec shows this is enough
  (`ActionsHaveObjects`, `Completes`), and the store test exercises it.
- **Path identity.** A string `<root>/objects/<64 hex>/files[/...]` becomes
  `tarshare-object:<id>[/...]` in keys. This applies only when `<root>` is laid
  out as a cache and the object's `complete` file exists, so keys do not depend
  on which caches a process happens to know.

Not yet built: tiers and `shared_push()`; the native namespace (so
`shared_repository()` refuses a URL); admin verbs; parked waiters; the
dirty-start re-verification. Default transfer chunk: 8 MiB. Default request
timeout: 300 s (option `tarshare.request_timeout`).

## Specification

[`spec/TarshareStore.tla`](spec/TarshareStore.tla) models one store and its
clients. Clients claim, compute, upload, publish and download. The model
includes crashes, connection drops that leave the client running, server
restarts, operator releases, and collection with no quiescence precondition.
Computation is nondeterministic, so two clients computing one key may produce
different objects. The checked properties:

| Property | Meaning |
|---|---|
| `ActionsHaveObjects` | an action always names a committed object |
| `PinsHold` | a pinned key always has its action |
| `FetchSafe` | a client sent to download an object finds it |
| `OneResult` | while a consumer's pin stands, the key resolves to what it delivered |
| `LeaseOnLiveConnection` | leases are held only over live connections |
| `SingleFlight` | a key is recomputed only after a lease was lost unpublished or its action collected |
| `Completes` (liveness) | every client that does not crash returns a result |

TLC checks all of them with 3 clients, 2 keys, 2 possible results, one
connection drop or restart, and one collection: 1,219,652 distinct states, no
error. [`spec/check.sh`](spec/check.sh) also seeds four bugs and confirms that
each is caught:

| Seeded bug | Caught by |
|---|---|
| a hit that does not pin | `FetchSafe` |
| publication that overwrites | `OneResult` |
| publication without the committed-object check | `ActionsHaveObjects` |
| a crashed client keeping its lease | `Completes` |

Run with `TLA2TOOLS=/path/to/tla2tools.jar sh design/spec/check.sh` (TLC 1.8.0).
The model is at the protocol level: one server step per request, as the
single-threaded server provides. Bytes, chunking and hashing are left to
`test-store.R`, whose blocks are named after these properties.

## ducknng, DuckDB 2.0 and Quack

**DuckDB 2.0.0 shipped on 2026-10-21 (LTS).**

- Extensions built on the stable v1 C API (`C_STRUCT`) still load: v2.0.0
  accepts v1 versions up to 1.5.6.
- `C_STRUCT_UNSTABLE` now means the unstable v2 API, so a 1.x extension built
  as unstable is refused by 2.0. Its message reads: "pin it with
  build_loadable_extension_capi(... 1 5 6 ...)".
- The C API v2 is "not yet stable".

**ducknng is not 2.0-ready as built.** It sets `USE_UNSTABLE_C_API=1` against
v1.5.2, only for the Arrow conversion and error-data functions. In the v2.0.0
headers those functions are in the stable v1 struct under
`DUCKDB_API_VERSION_AT_LEAST(1, 5, 6)`. The pending-streaming functions are
in its unguarded base. Building ducknng on the stable v1 API at 1.5.6 should
give one binary for DuckDB 1.5.6 and 2.0. This is from reading the headers,
not from a build.

**What a tarshare server on ducknng (option F) would need from ducknng:**

1. The stable-API rebuild above.
2. The requesting pipe id in `ducknng_auth_context()` or
   `ducknng_request_subject()`. The dispatcher already has it
   (`nng_msg_get_pipe()` in `ducknng_service.c`). With it, a lease row can
   store its pipe and be checked lazily against `ducknng_list_pipes()`, so no
   removal callback is needed.
3. A switch to leave the always-on `query_open` family unregistered, instead of
   denying it in an authorizer.
4. Optionally, raw (non-JSON) request bodies for SQL methods, to carry chunk
   bytes. Without that, bytes go to a bucket through Ropendal, as in option F.

**Quack directly.** Quack is a DuckDB core extension, first released in
1.5.3; its repository README still says "experimental". It speaks HTTP and
"exposes the full SQL surface".

- `quack_authorization_function` can allow, deny or rewrite each statement,
  and `quack_authentication_function` gives per-user tokens. That makes fixed
  operations possible only by matching query text.
- The protocol version must match exactly.
- Leases cannot be tied to a connection.
- An R client would need duckdb, quack and httpfs.

It suits DuckDB-to-DuckDB access to the index in option F, not the R client
path, which stays on nanonext.

## Inspiration: Nextflow Global Cache

Sources:
[blog](https://seqera.io/blog/nextflow-global-cache),
[plugin registry](https://registry.nextflow.io/plugins/xpack-platform),
[26.10 migration notes](https://docs.seqera.io/nextflow/migrations/26-10),
[design ADR, closed](https://github.com/nextflow-io/nextflow/pull/6796).
The shipped feature is the proprietary `xpack-platform` plugin (0.1.2), which
needs `NXF_XPACK_LICENSE`. The ADR is design intent; how the plugin actually
handles concurrency and lays out storage is not documented.

| Global Cache | tarshare today | This design |
|---|---|---|
| Hash drops session id and process name, keeping "its inputs and its script" | Key never included store path or target name | unchanged |
| A cloud prefix is the cache; content-addressable; the work directory itself is the cache | `objects/` is content-addressed; a file result's stage directory becomes its object | server disk first; bucket backend via Ropendal later (B, F) |
| `fileIdentity = provenance` (metadata-based, the default) or `sample` | `shared_file()` hashes content or takes an `id`; plain paths are strings | cache-owned paths get the identity `(object id, relative path)`: provenance and content at once, with no rehashing |
| `secondaryPaths`: ordered read-only caches consulted on a miss | none | ordered tiers; a secondary hit is promoted into the primary |
| `push-cache <source> <target>` | none | `shared_push()` |
| `clean-cache --failed --orphans --older-than` | `shared_gc()` (unreferenced, orphans, abandoned stages), pins | keep pins; `older_than` only as a filter on an explicit release |
| ADR: conditional PUT (`If-None-Match`, `ifGenerationMatch=0`), redundant work accepted (~1%) | filelock single-flight | put-if-absent for correctness, plus a cheap connection-bound lease |
| Cloud storage only; every bucket reachable from every task; licensed | one directory, any POSIX filesystem | no shared filesystem or bucket needed; GPL |
| ADR rejected bucket lifecycle rules, which "may delete task outputs while downstream tasks are using them" | nothing is removed implicitly | unchanged: Seqera's own reasoning for not relying on age-based deletion |

Two of Seqera's choices are worth not copying. Accepting duplicate work is
fine for short tasks, but an alignment or a variant-calling run is exactly
what one wants computed once, and the NNG lease costs almost nothing. Its
shipped cleanup is `--older-than`, while its own ADR proposed access-time
cleanup with downstream "touch". tarshare's pins avoid both: a result lives
until its owners are released.

## Siblings in RGenomicsETL

### CanardAbsurd: durable execution, not a cache

[CanardAbsurd](https://github.com/RGenomicsETL/CanardAbsurd) brings Absurd's
checkpoint-and-replay model to R. Its README states: "Not a scheduler. There is
no dependency graph or artifact store." The layers fit together:

- **targets** decides what to run (the graph and its invalidation).
- **CanardAbsurd** makes each submitted run survive crashes (at least once,
  with leases, retries and checkpoints).
- **tarshare** makes a computation that already ran anywhere not run again
  (an action index, content-addressed objects and pins).

The two packages approach leases from opposite directions:

| | CanardAbsurd | tarshare, option D |
|---|---|---|
| State owner | one process owns a DuckDB file (`ca_serve()`), clients use Quack | one process owns a cache directory (`shared_serve()`), clients use NNG |
| Lease | `token` UUID plus `lease_until`; renewed by `ca_step()`, `ca_heartbeat()`, `ca_process()` | bound to the client's NNG pipe; never renewed |
| Lease lost while the holder runs | stale worker cannot write: every write needs the current token | duplicate compute; publication is put-if-absent, the loser delivers the winner |
| Why that is enough | task writes are not idempotent, so they are fenced | writes are content-addressed and put-if-absent, so they are idempotent |
| Long external command | `ca_process()`: child process, worker heartbeats, per-attempt directory | not needed: the NNG I/O thread keeps the pipe alive while R blocks |
| Transitions | one SQL statement each (`claim.sql`, `spawn.sql`: `INSERT ... ON CONFLICT DO NOTHING RETURNING`) | one server request each, serialized by the server loop |
| Ambiguous transport failure | surfaced, never retried, since the statement may have committed | safe to retry: every verb is idempotent |

Three ways they meet:

1. **tarshare as CanardAbsurd's artifact store.** CanardAbsurd's durability
   guide says checkpoints live in the task row and advises: "Save file
   references rather than bulk data." A step can run
   `shared_run(..., format = "file", owner = "canard:<task id>")` and
   checkpoint the returned key and paths. The bytes are deduplicated,
   content-checked and pinned to the task, and released with it.
2. **The tarshare key as an idempotency key.** CanardAbsurd guarantees at
   least once: "a step whose callback finished but whose result was not saved
   runs again." If that step is a deterministic `shared_run()`, the rerun finds
   the published action and returns at once. tarshare thus closes the
   recomputation window for exactly the expensive, deterministic steps, which
   is the guide's advice ("give every external side effect an idempotency
   key") applied to computation.
3. **CanardAbsurd's state machine as tarshare's index (option F).** Its
   single-statement transitions, fencing tokens and native reaper thread are
   a tested pattern for the tables tarshare needs (actions, pins, leases).

`ca_process()` and tarshare's stages solve the same problem the same way: a
private per-attempt directory, so an abandoned attempt cannot overwrite
accepted output.

### ducknng: the same transport, inside DuckDB

[ducknng](https://github.com/RGenomicsETL/ducknng) binds NNG into DuckDB on
nanonext's model. It adds what option D would otherwise have to grow:

- A versioned frame envelope: version, type, a status byte with `BUSY`,
  `NOT_FOUND` and `UNAUTHORIZED`, method name, error, and payload.
- Fixed RPC methods whose handler is server-owned SQL
  (`ducknng_register_sql_method()`).
- mTLS caller identities (`tls:san:...`) visible to handlers through
  `ducknng_request_subject()`, peer and IP allowlists, per-identity limits,
  and a SQL authorizer.
- Pipe events in SQL: `ducknng_read_monitor()`, `ducknng_list_pipes()`.

Gaps for a tarshare server on ducknng:

- The always-on `query_open` accepts arbitrary SQL, so the authorizer must
  deny everything except the tarshare methods.
- I did not find the requesting pipe's id in the request context. Binding
  leases to connections needs it.
- The upload lane appends rows to tables. It does not stream file bytes.

### Ropendal: bytes on buckets

[Ropendal](https://github.com/RGenomicsETL/Ropendal) wraps OpenDAL for fs, S3,
GCS, Azure Blob, SFTP and HTTP. It is byte-first, with nanonext-style aio
handles.

- `fs_write()` is create-only: it checks existence, then writes with OpenDAL's
  `if_not_exists`, which is a server-side conditional write where the backend
  supports it (check `fs_capabilities()`).
- `fs_stat()` returns the ETag. `fs_read_iter()` and `byte_ranges()` stream.

That covers what options B and F need for objects, and what an S3-backed
`shared_serve()` would need. tarshare's README currently says it "does not
talk to cloud object storage"; Ropendal is how it could.

## What has to hold

These come from the current package and stay non-negotiable:

- The key is unchanged, except for the one deliberate change to cache-owned
  paths below.
- An action becomes visible only after its object is complete. Missing or
  corrupt data is a miss. Hard storage errors propagate; they never turn into
  silent recomputation.
- Nothing is removed implicitly. Every returned result is pinned for an owner
  before the call returns; release is explicit.
- Returned file paths are immutable and stable on the host that received them.
- The trust model is "trusted collaborators". Reading a result is still a
  deserialization.

Goals: several hosts, no shared POSIX filesystem required for correctness
(ideally not for bytes either), and crew or mirai workers on different hosts.
Not goals for a first version: hostile writers, replicated or highly available
servers, quotas or eviction.

## Why it can stay small

Correctness rests on three properties, none of which needs distributed
locking:

1. **Objects are content-addressed.** Two writers uploading the same id upload
   the same bytes, so object puts are idempotent.
2. **Action publication is put-if-absent**, and refused unless the object is
   committed. A single process, a conditional bucket write, or
   `INSERT ... ON CONFLICT DO NOTHING` decides it.
3. **Pins are taken in the same step as the lookup or publication**, so
   collection cannot slip between "found it" and "pinned it".

Single-flight leases are only an efficiency mechanism. If a lease is lost
while its holder lives, two hosts compute the same key. The second writer's
publication returns the winner's object, which it then delivers, so every
consumer sees one result. The cost is duplicated work, never a wrong answer.
Seqera's ADR makes the same argument for accepting duplicates. The CanardAbsurd
comparison above shows why tarshare, unlike a task queue, needs no fencing.

## Identity of cache-owned paths

A file result is a path inside the cache: `<root>/objects/<id>/files/<rel>`. A
downstream computation that receives it records the whole string in its key.
Today that is why "all consumers must see the cache at the same mounted
path". With per-host mirrors the root differs by host, so downstream keys
would differ too.

Fix it in the identity walker. A string under a registered cache or mirror
root whose next components are `objects/<64 hex>/files/` is recorded as
`tarshare-object:<id>/<rel>`. This is Seqera's provenance identity, and
because objects are content-addressed it is also a content identity, at the
cost of a regular expression rather than a rehash. It helps option A too:
mounts no longer have to agree. It changes the key of every computation that
consumed a cache path, once. Nextflow 26.10 likewise changed `eval` hashes once.
Record it in NEWS.

## Tiers and promotion

`shared_cache()` takes an ordered list of locations. The first is the primary
(read-write). The rest are secondaries: read-only, consulted in order on a
primary miss. Locations can be directories or URLs.

- **Secondary hit.** The client fetches the object from the secondary, uploads
  it to the primary, and publishes and pins it there. Retention then belongs to
  the primary, and the secondary can be collected on its own schedule. A
  secondary is trusted because the operator listed it.
- **`shared_push(from, to, keys)`** copies actions and objects between caches,
  for example to promote a project's validated results into an
  organization-wide read-only cache. Content addressing makes the copy
  verifiable.
- **One primary is one trust scope**, which Seqera calls a workspace. Sharing
  across scopes goes through read-only tiers, not a shared index.

## Step 0: a storage seam

`shared_run()` (R/cache.R), the `shared_cas_*()` callbacks (R/cas.R) and the
retention functions (R/retention.R) call filesystem helpers directly today.
Move those calls behind internal S3 generics dispatched on the cache class.
The current code becomes the `fs` driver, unchanged:

| Verb | `fs` driver (current code) | Remote driver |
|---|---|---|
| `store_session(cache)` | `shared_gate()` shared lock | lazily dial a socket |
| `store_claim(cache, key, format, owner)` | `action-<key>` lock, `shared_restore()`, `shared_pin()` | `CLAIM` |
| `store_peek(cache, key, format)` | `shared_restore()` without a pin | `PEEK` (secondaries) |
| `store_abandon(cache, key)` | unlock | `ABANDON` |
| `store_fetch(cache, object)` | object directory in place | copy into the local mirror, verify |
| `store_put_object(cache, stage)` | object lock, `shared_publish()` | `HAVE`, then `PUT_*` |
| `store_publish(cache, key, object, format, owner)` | action stage, `shared_publish()`, pin | `PUBLISH` |
| `store_native_put/get/has(cache, ...)` | `shared_cas_*()` bodies | the same verbs, `native` namespace |
| `store_refs/retain/release/gc(cache, ...)` | R/retention.R bodies | admin verbs run by the server |

`shared_run()` then reads as: claim, then hit (fetch, deliver), or granted
(peek the secondaries; compute; put the object; publish; deliver the winner),
or busy (wait). It knows nothing about the backend. This step is mostly code
motion, and every current test must pass without edits.

## Options

The options differ in two layers: where the **index** lives (action records,
pins, leases), and how **bytes** move.

### A. Shared filesystem, qualified (status quo)

No code. Qualify NFS or SMB with the shipped two-host harness.

- Gains: zero copies, nothing to run.
- Costs: correctness depends on advisory locks and rename semantics of a
  particular server, client and mount profile (open item #5 in REVIEW.md).
  Every worker needs the mount.

### B. Object storage directly, no server (Seqera's shape)

Objects become blobs named by hash. Actions use conditional creation: Ropendal
`fs_write()`, or S3 `If-None-Match: *`, or GCS `ifGenerationMatch=0`. Leases
are blobs with an expiry, and pins are one blob per owner and key.

- Gains: no process to operate; scales; native objects can use targets'
  `repository = "aws"` or `"gcp"`.
- Costs: leases need wall-clock TTLs, and an R process inside `eval()` cannot
  renew them. Either the TTL exceeds the longest computation, or
  single-flight degrades to Seqera's accepted duplicates. Collection needs
  asserted quiescence plus a grace period. Credentials go on every worker, and
  every bucket must be reachable from every task.

### C. nanonext index server, bytes on a shared mount

A nanonext server owns the index, pins and leases. Bytes stay on a mount.
Clients write a stage on the mount and ask the server to verify and commit it.

- Gains: removes the dependency on network file locks, the weakest part of
  option A, while keeping zero-copy reads. Smallest new code.
- Costs: still needs a mount wherever a file output is read. Collection keeps
  today's quiescence rule, because readers hold paths on the mount.

### D. nanonext store server (recommended first)

The same server as C, but it also moves the bytes. Its directory is an
ordinary tarshare cache on local disk. Clients copy objects into a local
mirror. Details below.

- Gains: no shared filesystem or bucket anywhere; leases freed when a writer
  dies; collection can run while clients are active; `shared_repository()`
  becomes a networked targets CAS, so crew workers on different hosts can
  share native objects. C is D with a different byte plane.
- Costs: one R process to run and back up; every byte is copied (server disk,
  wire, mirror); throughput limited by one R process until it is sharded.

### E. Speak an existing remote-cache protocol

The Bazel HTTP cache (`GET/PUT /ac/<key>`, `/cas/<hash>`) is served by
bazel-remote, buildbarn, or nginx with WebDAV.

- Gains: off-the-shelf servers with bucket backends, auth and monitoring.
- Costs: no leases. These servers evict by LRU to a size limit, which breaks
  the retention contract, and pins have nowhere to live.

### F. DuckDB index in the CanardAbsurd style, served by ducknng, bytes via Ropendal

The index is DuckDB tables (`actions`, `pins`, `leases`, `uploads`) owned by
one process, as in `ca_serve()`. Each verb is one SQL statement, as in
CanardAbsurd's `inst/sql/`:

- `PUBLISH` is an `INSERT ... ON CONFLICT DO NOTHING RETURNING` of the winner.
- `CLAIM` is an `UPDATE` with a token.
- Collection is an anti-join.

The verbs are exposed as fixed ducknng SQL methods behind an authorizer that
denies everything else, never as Quack's arbitrary SQL. Bytes go to a bucket
or a server directory through Ropendal: clients write objects create-only
and the server verifies them before `PUBLISH`.

- Gains: ACID, WAL-backed metadata; cache contents, owners and sizes become
  queryable from any DuckDB session; mTLS identities as owners and scopes;
  collection and reporting in SQL; a self-hosted, open counterpart to
  Seqera's cloud-prefix deployment.
- Costs: DuckDB and ducknng on the server; ducknng needs the request pipe id
  for connection-bound leases, or leases fall back to CanardAbsurd-style TTLs
  with the heartbeat problem; bucket credentials on clients if they write
  objects directly. Best reached from D by swapping the server, which is why
  the wire format matters now.

### Comparison

| | A: shared FS | B: object store | C: nng + mount | D: nng store | E: Bazel cache | F: DuckDB + ducknng |
|---|---|---|---|---|---|---|
| Shared mount needed | yes, with locks | no | yes, bytes only | no | no | no |
| Cross-host single-flight | filelock, mount-dependent | TTL lease, or none | connection lease | connection lease | none | connection lease if ducknng exposes pipe ids, else TTL |
| Writer process dies | lock freed by the OS; on NFS, by its lock manager | wait for TTL | freed at once | freed at once | n/a | freed at once, or TTL |
| Retention contract kept | yes | yes | yes | yes | no (LRU) | yes |
| Collection | offline, quiescent | offline, quiescent + grace | server, quiescent | server, online with grace | server eviction | SQL, online with grace |
| Metadata durability | rename, no fsync | bucket | rename, no fsync | rename, no fsync | server | DuckDB WAL |
| New infrastructure | none | bucket, credentials everywhere | one R process | one R process + disk | external server | DuckDB process + bucket or disk |
| New R dependency | none | Ropendal | nanonext | nanonext | nanonext or curl | nanonext; server: duckdb, ducknng, Ropendal |
| Hosts without a mount | no | yes | no | yes | yes | yes |
| Rough size | 0 | medium | small | medium | small | large |

## Option D in detail

### Usage

```r
# On the store host: one long-running R process (systemd, tmux, a scheduler job).
cert <- nanonext::write_cert(cn = "store.lab")   # or certificates from a site CA
tarshare::shared_serve(
  path = "/data/tarshare",                       # an ordinary tarshare cache directory
  url  = "tls+tcp://0.0.0.0:5555",
  tls  = nanonext::tls_config(server = cert$server)
)                                                # tokens come from the environment

# In _targets.R on any host: only the cache line changes.
cache <- shared_cache(
  c("tls+tcp://store.lab:5555",                  # primary, read-write
    "tls+tcp://org-store.lab:5555"),             # secondary, read-only
  ca = "/etc/tarshare/ca.pem"
)
list(
  tar_target(values, c(3, 5, 8, 13)),
  tar_shared(summary, summarise_values(values), cache)
)
tar_option_set(repository = shared_repository(cache))  # optional networked native CAS
```

`shared_cache()` dispatches on each location. A path gives the `fs` driver; a
`tcp://`, `tls+tcp://` or `ipc://` URL gives the `nng` driver.

The cache object must stay a plain list of strings and numbers (locations, CA
path, `verify`, `timeout`, chunk size). `tar_shared()` embeds it in the target
command and `shared_repository()` substitutes it into callback text, so it
cannot hold a socket or a `tlsConfig` (external pointers neither serialize nor
hash stably). Each process opens its connection lazily and keeps it in
`shared_runtime`.

The access token is read from `TARSHARE_TOKEN` when the connection opens, and
never stored in the object, because targets writes commands into its metadata.
The mirror location is resolved on each host
(`tools::R_user_dir("tarshare", "cache")` by default), so the embedded command
does not depend on the host.

### Topology

```
 host A: targets + crew workers              host B: another project
 +-----------------------------+             +-----------------------------+
 | shared_run() -> nng driver  |             | shared_run() -> nng driver  |
 | mirror: local tarshare dir  |             | mirror: local tarshare dir  |
 +--------------+--------------+             +--------------+--------------+
                |  req socket per process                   |
                +--------- tls+tcp://store.lab:5555 --------+
                                    |
                     +--------------v---------------+       +------------------+
                     | shared_serve(): one R thread |  PEEK | org-store        |
                     |  rep socket, monitor()       | ----> | (read-only tier) |
                     |  leases: key -> pipe id      |       +------------------+
                     |  fs driver on local disk     |
                     +------------------------------+
```

Each R process (the main process and every crew worker) holds one `req`
socket per location, which is one NNG pipe. The server is single-threaded.
Because it handles one request at a time, put-if-absent, pin-with-lookup and
collection are atomic without locks.

The server still uses the `fs` driver for its directory, so the directory
stays a valid tarshare cache. It can be maintained offline with today's
functions, and an existing shared cache can be migrated by starting a server
on it.

### Protocol

Use ducknng's frame envelope (see its `docs/protocol.md`): version, message
type, a status byte (`BUSY`, `NOT_FOUND`, `UNAUTHORIZED`, ...), method name,
error text and payload. Payloads are small JSON objects for control, plus raw
bytes for chunks. An R encoder and decoder over nanonext raw messages is a few
dozen lines. Adopting it means option F's server, or any DuckDB session with
ducknng, speaks the same protocol. It also follows ducknng's rule against
one-off binary layouts.

The server never calls `unserialize()` on anything it receives. It stores
result records as opaque bytes and only reads records it wrote itself. Every
request carries the token.

| Method | Fields | Server effect | Reply |
|---|---|---|---|
| `CLAIM` | key, format, owner | if published: pin owner, return object; else lease to this pipe if free | object / granted / status `BUSY` |
| `PEEK` | key, format | read-only lookup, no pin, no lease (for secondaries) | object / `NOT_FOUND` |
| `PUBLISH` | key, object, format, owner | requires a committed object; put-if-absent; pin owner; drop the caller's lease | committed or existing winner |
| `ABANDON` | key | drop the caller's lease | ok |
| `HAVE` | ns, ids | batch existence (`ns` is `objects` or `native`) | one flag per id |
| `PUT_BEGIN` | ns, id, manifest | open an upload stage bound to this pipe | upload token, or already present |
| `PUT_CHUNK` | token, file, offset; bytes | positional write, so a resend is harmless | ok |
| `PUT_END` | token | check paths, sizes, SHA-256 and record hash; atomic rename | committed / rejected with reason |
| `MANIFEST` | ns, id | | manifest |
| `GET_CHUNK` | ns, id, file, offset, length | | bytes |
| `PIN` | ns, id, owner | native-namespace pin | ok |
| `REFS`, `RETAIN`, `RELEASE`, `GC`, `PUSH` | as the R functions | run on the server; admin token | table |

Every method is idempotent. NNG's automatic request resend after a reconnect,
or a client retrying a timed-out call, can at worst return the same answer.
This is the opposite of CanardAbsurd, which must surface ambiguous failures
because a SQL statement may already have committed.

The manifest lists the bundle's relative paths, empty directories, sizes and
SHA-256 hashes, which `shared_bundle()` already computes. The server rejects
absolute paths, `..` and anything the existing `shared_path()` rule refuses.
It checks that `complete` equals the SHA-256 of `result.rds` and, in the
`objects` namespace, that this hash is the object id (native ids are hashes of
targets keys, as in `shared_native_key()`).

Whether the manifest matches the bundle recorded inside `result.rds` is
checked by the client on fetch, as `shared_object_read()` does today. A
mismatch is a miss there, not a wrong result.

Chunks default to 8 MiB, so memory is bounded however large a BAM or VCF is,
and a long transfer interleaves with control messages. Each side checks
finished files with `digest(file = ...)`, which streams. Set `recv-size-max`
to one chunk plus a header; nanonext's default is unlimited, and the spike
moved 64 MiB in one message.

### Leases

The server records `leases[key] <- pipe_id(aio)` when it grants a `CLAIM`.
`monitor()` signals the same condition variable as the receive, and
`read_monitor()` returns removed pipes as negative ids. The server then drops
those leases and deletes their upload stages. A waiting client polls `CLAIM`
with backoff up to `timeout`, which keeps today's meaning. Computations take
minutes, so polling costs nothing that matters.

Evidence, from `Rscript design/spikes/nng-lease.R` (nanonext 1.10.4,
NNG 1.12.3, R 4.6.2, Linux, `ipc://`). The holder takes the lease and then
blocks in `Sys.sleep()`, standing in for a long `eval()`. It sends nothing,
yet keeps the lease. The waiter gets the lease at its first poll after the
holder is killed with SIGKILL:

```
15:20:23.18 server: pipe 822305069 LEASE k1 -> GRANTED
15:20:24.71 server: pipe 822305070 LEASE k1 -> BUSY 822305069
  ... BUSY every 0.5 s while the holder is alive and silent ...
15:20:28.05 server: pipe closed, released lease: k1
15:20:28.23 server: pipe 822305070 LEASE k1 -> GRANTED
15:20:30.22 bulk : received 67108864 bytes
```

A killed process closes its socket in the kernel, so release is immediate. A
host that crashes or drops off the network is detected only through TCP
keepalive. NNG's `tcp-keepalive` option can be enabled (checked), but the
probe interval is the operating system's, about two hours by default on
Linux. Tune the server's sysctls, or set an optional `max_lease` (default
`Inf`, like today's `timeout`). Until then waiters wait, exactly as they do
behind a filelock held by a hung process.

This is the step CanardAbsurd covers with `ca_process()` and heartbeats. Here
NNG's I/O thread does that job, because the lease protects efficiency, not
correctness.

### Bytes and the mirror

The mirror is an ordinary local tarshare cache, written by the existing code:

- **Hit:** if the object is not in the mirror, fetch the manifest and chunks
  into a mirror stage, verify, and publish it locally with
  `shared_publish()`. Then write the action and the local pin, and deliver
  paths inside the mirror.
- **Miss:** `PEEK` the secondaries and promote on a hit. Otherwise compute
  into a mirror stage (local disk, faster than a mount), publish locally,
  upload unless `HAVE` says the server has the object, then `PUBLISH`. On an
  existing winner, fetch and deliver it.

Delivered paths are local to the host that ran the target. Their identity is
`(object id, relative path)`, so downstream keys agree across hosts.

A targets pipeline whose workers sit on hosts without a common mount must
already use a CAS repository for file targets. `shared_repository(cache)` over
the nng driver is such a repository, and `tar_shared()` already localizes
file outputs for nonlocal repositories. The `list` callback becomes one
batched `HAVE`.

### Retention and collection

- Pins are taken inside `CLAIM` and `PUBLISH`, atomically with the lookup.
- `GC` runs inside the server as one request. With the server stopped,
  today's `shared_gc()` works on its directory unchanged. Online collection is
  safe for server data for four reasons:
  - no client reads server paths directly;
  - pins cannot race lookups;
  - open uploads live in stages owned by live pipes;
  - an object committed but not yet published is protected by the existing
    `stage_age` grace.
- `quiescent = TRUE` stays required for `RELEASE`, because "this owner is
  finished" is a claim only the operator can make.
- `RELEASE` may take `older_than` to drop an owner's pins taken before a date.
  This is Seqera's `--older-than`, but applied to pins by an operator, never
  to objects by a timer.
- Mirrors keep today's rules: local, offline, quiescent.
- Long collections stall other requests. That is acceptable for a first
  version; incremental sweeping can come later.

### Durability

Today publication is an atomic rename without `fsync`, and the README says so:
"Atomic publication is not a power-loss durability guarantee." After a power
cut, some filesystems can leave a published entry with truncated or
zero-filled files. With `verify = TRUE` the hash check turns that into a miss,
so the cost is recomputation, not a wrong result. With `verify = FALSE` it
would not be caught.

A server is the first place where tarshare can do better, because one process
writes its own local disk. Options:

1. **Re-verify after an unclean stop (recommended first).** The server writes
   a clean-shutdown marker and journals the ids it published since the last
   one. On a dirty start it rehashes those objects and removes failures before
   accepting requests. This needs no compiled code, and the cost of a power
   cut is a bounded verification pass.
2. **`fsync` ordering.** Sync the files, then the stage directory; rename;
   then sync the parent; only then publish the action. Base R has no
   `fsync()`, so this needs a small C helper (`fsync` or `FlushFileBuffers`)
   in a package that is pure R today.
3. **DuckDB for the index (option F).** Commits are WAL-backed. Objects still
   need 1 or 2.

CanardAbsurd draws the same line: "Checkpointing does not make an HTTP call
or a file write transactional." Its state is durable through DuckDB; the
files a step writes are not. For tarshare the files are the product, so the
verification pass matters.

### Failures

| Event | Behaviour |
|---|---|
| Client process dies while computing | lease and upload stage dropped at pipe removal; the next `CLAIM` computes |
| Client host dies or is partitioned | released by TCP keepalive or `max_lease`; waiters wait until then |
| Lease lost while the holder lives | duplicate compute; put-if-absent; the loser delivers the winner |
| Client dies between `PUT_END` and `PUBLISH` | orphan object, collected after `stage_age` |
| Server down or unreachable | `tarshare_storage_error`: the target fails, nothing recomputes silently |
| Server restarts cleanly | on-disk state intact; leases and uploads were in memory and their pipes are gone |
| Server loses power | dirty start: journaled objects re-verified before serving |
| Corrupt server object | `CLAIM` validates sizes, and hashes when `verify`; corrupt is a miss and the next upload replaces it, as `shared_publish()` does today |
| Secondary unreachable | treated like a primary failure: a hard error, not a skipped tier |

The last row is a choice to confirm. Skipping an unreachable tier would turn
an outage into silent recomputation, which the contract forbids today.

### Security

- Transport: `tls+tcp://` with nanonext's Mbed TLS, using
  `nanonext::write_cert()` or a site CA. Clients store the CA path in the
  cache config.
- Authentication: a bearer token per deployment, from the environment, on
  every request; a separate admin token for `RELEASE`, `GC` and `PUSH`.
  Mutual TLS has not been evaluated for nanonext: `tls_config()` accepts
  `auth` for servers, but its documentation does not say how client
  certificates are validated. ducknng does support mTLS identities (option F).
- The server treats object bytes as opaque. It validates paths, sizes and
  hashes, and never deserializes client data.
- Unchanged: anyone holding the token can publish a result for any key, and
  readers deserialize it. Share only with trusted collaborators.

### Size and cost

Estimates:

- The step-0 seam: about 150 lines moved.
- The client driver with the envelope codec: about 300 new lines.
- `shared_serve()`: about 300 lines.
- Tiers and path identity: about 100 lines.
- Tests: about 350 lines.

nanonext goes in Suggests and loads only for URL caches; crew and mirai users
already have it. Operating cost is one R process and its disk, which is a
single point of failure to back up.

Implementation notes from the spike:

- Pass `block = TRUE` (or a timeout) to `send()` and `recv()`. Without it, a
  receive before the reply arrives returns error 8, "Try again".
- `read_monitor()` returns `NULL` when nothing changed.
- `socket(dial = , autostart = NA)` dials synchronously, which avoids sending
  before the connection exists.

## Phasing and tests

1. **Seam and path identity (done).** The seam turned out to be a single
   dispatch in `shared_run()`; the remote driver reuses the filesystem path on
   its mirror. All other tinytests pass untouched.
2. **nng driver and `shared_serve()` (done)** for `CLAIM`, `PUBLISH`, `ABANDON`,
   objects and the mirror, on the ducknng envelope. Run the existing cache
   tests against a server in `callr::r_bg()` on `ipc://`, so CI opens no
   ports. New tests:
   - a killed holder frees its lease;
   - a waiter computes once;
   - a killed uploader commits nothing;
   - a server restart, clean and dirty;
   - a `PUBLISH` race in which the loser delivers the winner;
   - manifest path traversal rejected;
   - wrong token rejected.
3. **Tiers, `PEEK` and `shared_push()`**, plus the native namespace:
   `shared_repository()` over the network, with a batched `HAVE` for `list`.
4. **TLS, tokens and admin verbs**, a vignette section, and a URL mode for the
   two-host qualification harness.

Later, only if needed:

- waiters parked on extra rep contexts and woken with `race_aio()` instead of
  polling;
- a Ropendal bucket backend behind `shared_serve()`;
- the C byte plane;
- option F as a second server implementation;
- several server processes sharded by key prefix;
- peer mirrors.

## Rejected

- **mirai or crew daemons as the store.** In mirai the host listens and
  daemons dial in to that one host, and daemons evaluate code the host sends.
  A store needs many unrelated clients dialing one service that never
  evaluates client code.
- **Quack as tarshare's transport.** CanardAbsurd's own deployment guide
  states it: "The token grants arbitrary SQL, not a set of task operations."
  Every pipeline worker would hold that power over the cache host. ducknng's
  fixed SQL methods behind an authorizer are the DuckDB route.
- **nanonext `http_server()` as the control plane.** It exists in 1.10.4,
  together with `handler()`, `handler_stream()` and `ncurl()`. But an HTTP
  lease cannot be tied to a connection, so leases would need TTLs again, and
  `ncurl()` returns whole bodies in memory. It remains useful for a read-only
  status endpoint.
- **Age-based eviction or bucket lifecycle rules.** Seqera's ADR rejected
  them because they "may delete task outputs while downstream tasks are using
  them". Pins answer the question directly.
- **Peer-to-peer without a server.** Any peer's copy of an object is valid,
  which makes peers attractive for moving bytes later. Put-if-absent on
  actions still needs a single authority.

## Open questions

1. Do the target deployments always have a shared mount (HPC), or not (cloud,
   laptops)? With a mount everywhere, C first is smaller; otherwise D.
2. Is one server, backed up but not replicated, acceptable for a first
   version?
3. **Wire format (decided).** The ducknng envelope, with text control payloads.
   Switch control payloads to JSON if option F is built.
4. **Index backend.** Stay on the fs layout (offline maintenance with today's
   functions, no new dependencies), or move to DuckDB tables early for SQL
   inspection and WAL durability?
5. **ducknng changes.** Rebuild on the stable v1 C API at 1.5.6 and expose the
   request pipe id (see [ducknng, DuckDB 2.0 and Quack](#ducknng-duckdb-20-and-quack)).
6. **Owner identity across hosts.** The default owner is the store path as
   seen by the process that runs the target. A crew worker on another host
   sees a different path, and two hosts can share a path. Two choices:
   resolve the owner on the controller when the graph is built and embed it
   in the command (stable, but moving the store changes the command), or keep
   a random owner id in the store (stable, but workers may not see the store).
   CanardAbsurd tasks would use `canard:<task id>`.
7. Should the native CAS (`shared_repository()`) be in the first version?
8. Should an unreachable secondary be a hard error, as proposed, or skipped
   with a warning?

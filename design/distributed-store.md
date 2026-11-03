# Distributed tarshare: design options

Status: proposal. Nothing here is implemented. The one experiment it relies on
is [`spikes/nng-lease.R`](spikes/nng-lease.R).

## Summary

tarshare already splits its cache into an action index (`actions/`: key to
object) and content-addressed objects (`objects/`, `native/`). That is the same
split as a Bazel remote cache. Because objects are immutable and named by
their hash, a distributed version needs only one serialization point for a
small amount of metadata (action records, pins, single-flight leases) and some
way to move bytes. Everything else is the existing code.

Recommendation:

1. **Step 0, needed by every option:** put the filesystem behind an internal
   storage seam (about ten verbs) without changing behaviour. The existing
   tinytests are the acceptance test.
2. **Then option D:** a small nanonext store server. One long-running R process
   owns an ordinary tarshare cache directory on its local disk. Clients reach
   it over `tls+tcp://` (or `ipc://` in tests) and keep a local mirror for file
   outputs. Single-flight leases are bound to the client's NNG connection, so a
   writer that dies frees its key without a TTL and without heartbeats, which
   an R process busy in `eval()` could not send anyway. The spike confirms this
   on nanonext 1.10.4.

User-facing additions: a URL form of `shared_cache()` and one new function,
`shared_serve()`. `shared_run()`, `tar_shared()`, `shared_repository()`, the
key, and the retention contract stay as they are.

## What has to hold

These come from the current package and stay non-negotiable:

- The key is unchanged. A distributed cache and a directory cache built from
  the same code agree on every key.
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
   committed. A single process deciding this is enough.
3. **Pins are taken in the same step as the lookup or publication**, so
   collection cannot slip between "found it" and "pinned it".

Single-flight leases are only an efficiency mechanism. If a lease is lost
while its holder is still alive, two hosts compute the same key. Both
publications go through put-if-absent: the second writer gets back the
winner's object id and delivers that, so every consumer still sees one result.
The cost is duplicated work, never a wrong answer. That is why leases can be
cheap and connection-bound instead of a consensus protocol.

## Step 0: a storage seam

`shared_run()` (R/cache.R), the `shared_cas_*()` callbacks (R/cas.R) and the
retention functions (R/retention.R) call filesystem helpers directly today.
Move those calls behind internal S3 generics dispatched on the cache class.
The current code becomes the `fs` driver, unchanged:

| Verb | `fs` driver (current code) | Remote driver |
|---|---|---|
| `store_session(cache)` | `shared_gate()` shared lock | lazily dial a socket |
| `store_claim(cache, key, format, owner)` | `action-<key>` lock, `shared_restore()`, `shared_pin()` | `CLAIM` |
| `store_abandon(cache, key)` | unlock | `ABANDON` |
| `store_fetch(cache, object)` | object directory in place | copy into the local mirror, verify |
| `store_put_object(cache, stage)` | object lock, `shared_publish()` | `HAVE`, then `PUT_*` |
| `store_publish(cache, key, object, format, owner)` | action stage, `shared_publish()`, pin | `PUBLISH` |
| `store_native_put/get/has(cache, ...)` | `shared_cas_*()` bodies | the same verbs, `native` namespace |
| `store_refs/retain/release/gc(cache, ...)` | R/retention.R bodies | admin verbs run by the server |

`shared_run()` then reads as: claim, then hit (fetch, deliver), or granted
(compute, put object, publish, deliver the winner), or busy (wait). It knows
nothing about the backend. This step is mostly code motion, and every current
test must pass without edits.

## Options

### A. Shared filesystem, qualified (status quo)

No code. Qualify NFS or SMB with the shipped two-host harness.

- Gains: zero copies, nothing to run.
- Costs: correctness depends on advisory locks and rename semantics of a
  particular server, client and mount profile (open item #5 in REVIEW.md).
  Every worker needs the mount. No help for cloud or mixed environments.

### B. Object storage directly (S3, GCS, Azure), no server

Objects become blobs named by hash. Actions use conditional creation: S3
`If-None-Match: *` (supported since 2024), GCS `ifGenerationMatch=0`, Azure
`If-None-Match: *`. Leases are lease blobs with an expiry. Pins are one blob
per owner and key.

- Gains: no process to operate; scales; native objects can use targets' own
  `repository = "aws"` or `"gcp"`.
- Costs: leases need wall-clock TTLs, and an R process inside `eval()` cannot
  renew them. A TTL must therefore exceed the longest computation, or
  single-flight degrades to duplicate work. Collection still needs an asserted
  quiescence plus a grace period, because nothing knows about in-flight
  clients. Credentials on every worker. New client dependency (paws or
  similar). No offline or HPC story.

### C. nanonext coordinator, bytes on a shared mount

A nanonext server owns the action index, pins, leases and the maintenance
state. Bytes stay on a mount (or a bucket). Clients write objects to a stage
on the mount and ask the server to verify and commit them.

- Gains: removes the dependency on network file locks, the weakest part of
  option A, while keeping zero-copy reads. Smallest new code.
- Costs: still needs a mount everywhere a file output is read, so it does not
  help hosts without one. Collection keeps today's quiescence rule, because
  readers hold paths on the mount.

### D. nanonext store server (recommended)

The same server as C, but it also moves the bytes. Its directory is an
ordinary tarshare cache on local disk. Clients copy objects into a local
mirror. Details below.

- Gains: no shared filesystem anywhere; leases freed when a writer dies;
  collection can run while clients are active; `shared_repository()` becomes a
  networked targets CAS, so crew workers on different hosts can share native
  objects without a bucket. C becomes a configuration of D (a different data
  plane), not a separate system.
- Costs: one R process to run and back up; every byte is copied (server disk,
  wire, mirror); throughput limited by one R process until it is sharded.

### E. Speak an existing remote-cache protocol

The Bazel HTTP cache protocol (`GET/PUT /ac/<key>`, `/cas/<hash>`) is served
by bazel-remote, buildbarn, or nginx with WebDAV. tarshare could speak it with
`nanonext::ncurl()`.

- Gains: off-the-shelf servers with S3, GCS and Azure backends, auth and
  monitoring.
- Costs: no leases, so no single-flight. These servers evict by LRU to a size
  limit, which breaks tarshare's contract that nothing is removed implicitly,
  and pins have nowhere to live. Better used later as a storage backend behind
  D than as the protocol clients speak.

### Comparison

| | A: shared FS | B: object store | C: nng + mount | D: nng store | E: Bazel cache |
|---|---|---|---|---|---|
| Shared mount needed | yes, with locks | no | yes, bytes only | no | no |
| Cross-host single-flight | filelock, mount-dependent | TTL lease | connection lease | connection lease | none |
| Writer process dies | lock freed by the OS; on NFS, by its lock manager | wait for TTL | freed at once | freed at once | n/a |
| Retention contract kept | yes | yes | yes | yes | no (LRU) |
| Collection | offline, asserted quiescence | offline, asserted quiescence + grace | server-side, quiescence | server-side, online with grace | server eviction |
| New infrastructure | none | bucket, credentials on every worker | one R process | one R process + its disk | external server |
| New R dependency | none | object-store client | nanonext (Suggests) | nanonext (Suggests) | nanonext or curl |
| Workers on hosts without a mount | no | yes | no | yes | yes |
| Rough size | 0 | medium | small | medium | small |

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
cache <- shared_cache("tls+tcp://store.lab:5555", ca = "/etc/tarshare/ca.pem")
list(
  tar_target(values, c(3, 5, 8, 13)),
  tar_shared(summary, summarise_values(values), cache)
)
tar_option_set(repository = shared_repository(cache))  # optional networked native CAS
```

`shared_cache()` dispatches on its argument. A path gives the `fs` driver; a
`tcp://`, `tls+tcp://` or `ipc://` URL gives the `nng` driver.

The cache object must stay a plain list of strings and numbers (URL, CA path,
`verify`, `timeout`, chunk size). `tar_shared()` embeds it in the target
command and `shared_repository()` substitutes it into callback text, so it
cannot hold a socket or a `tlsConfig` (external pointers neither serialize nor
hash stably). Each process opens its connection lazily and keeps it in
`shared_runtime`. The access token is read from `TARSHARE_TOKEN` when the
connection is opened, never stored in the object: targets writes commands into
its metadata. The mirror location is resolved on each host
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
                     +--------------v---------------+
                     | shared_serve(): one R thread |
                     |  rep socket, monitor()       |
                     |  leases: key -> pipe id      |
                     |  fs driver on local disk     |
                     +------------------------------+
```

Each R process (the main process, every crew worker) holds one `req` socket,
which is one NNG pipe. The server is single-threaded. Because it handles one
request at a time, put-if-absent, pin-with-lookup and collection are atomic
without locks. The server still uses the `fs` driver for its directory, so
the directory stays a valid tarshare cache. It can be maintained offline with
today's functions, and an existing shared cache can be migrated by starting a
server on it.

### Protocol

A message is a text header line (`VERB<TAB>field...`) optionally followed by
binary payload after the first newline. The server never calls
`unserialize()` on anything it receives. It stores result records as opaque
bytes and only reads records it wrote itself. Every request carries the token.

| Verb | Fields | Server effect | Reply |
|---|---|---|---|
| `CLAIM` | key, format, owner | if published: pin owner, return object; else lease to this pipe if free | `HIT object` / `GRANTED` / `BUSY age` |
| `PUBLISH` | key, object, format, owner | requires a committed object; put-if-absent; pin owner; drop the caller's lease | `COMMITTED object` / `EXISTS winner` |
| `ABANDON` | key | drop the caller's lease | `OK` |
| `HAVE` | ns, id... | batch existence (`ns` is `objects` or `native`) | one flag per id |
| `PUT_BEGIN` | ns, id; manifest payload | open an upload stage bound to this pipe | `UPLOAD token` / `HAVE` |
| `PUT_CHUNK` | token, file, offset; bytes | append | `OK` |
| `PUT_END` | token | check paths, sizes, SHA-256 and record hash; atomic rename | `COMMITTED` / `REJECTED reason` |
| `MANIFEST` | ns, id | | manifest text |
| `GET_CHUNK` | ns, id, file, offset, length | | bytes |
| `PIN` | ns, id, owner | native-namespace pin | `OK` |
| `REFS`, `RETAIN`, `RELEASE`, `GC` | as today's functions | run R/retention.R on the server | TSV |

The manifest lists the bundle's relative paths, empty directories, sizes and
SHA-256 hashes, which `shared_bundle()` already computes. The server rejects
absolute paths, `..` and anything the existing `shared_path()` rule refuses.
It checks that `complete` equals the SHA-256 of `result.rds` and, in the
`objects` namespace, that this hash is the object id (native ids are hashes of
targets keys, as in `shared_native_key()`). Whether the manifest matches the bundle recorded inside
`result.rds` is checked by the client on fetch, as `shared_object_read()` does
today. A mismatch is a miss there, not a wrong result.

Chunks default to 8 MiB, so memory is bounded however large a BAM or VCF is,
and a long transfer interleaves with control messages at chunk granularity.
Each side checks finished files with `digest(file = ...)`, which streams.
`recv-size-max` is set to one chunk plus a header. nanonext's default is
unlimited; the spike moved 64 MiB in a single message.

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
behind a filelock held by a hung process. A lease lost to a network blip
while its holder lives costs duplicate work, as explained above.

### Bytes and the mirror

The mirror is an ordinary local tarshare cache, written by the existing code:

- **Hit:** if the object is not in the mirror, fetch `MANIFEST` and chunks
  into a mirror stage, verify, and publish it locally with
  `shared_publish()`. Then write the action and the local pin, and deliver
  paths inside the mirror.
- **Miss:** compute into a mirror stage (local disk, faster than a mount),
  publish locally, upload unless `HAVE` says the server has it, then
  `PUBLISH`. On `EXISTS`, fetch and deliver the winner.

Returned paths are local to the host that ran the target, as they are for
`repository = "local"` today. A targets pipeline whose workers sit on hosts
without a common mount must already use a CAS repository for file targets.
`shared_repository(cache)` over the nng driver is such a repository, and
`tar_shared()` already localizes file outputs for nonlocal repositories. The
`list` callback becomes one batched `HAVE`.

Option C is this design with a different data plane. `CLAIM` returns an
object path on a configured mount, and uploads are a stage on the mount plus
`PUT_END`. No locks are needed on the mount, only rename and read-after-close
visibility.

### Retention and collection

- Pins are taken inside `CLAIM` and `PUBLISH`, atomically with the lookup.
- `GC` runs inside the server as one request. With the server stopped,
  today's `shared_gc()` works on its directory unchanged. Online collection is
  safe for server data because no client reads server paths directly, pins
  cannot race lookups, open uploads live in stages owned by live pipes, and an
  object committed but not yet published is protected by the existing
  `stage_age` grace. `quiescent = TRUE` stays required for `RELEASE`, because
  "this owner is finished" is a claim only the operator can make.
- Mirrors keep today's rules: local, offline, quiescent.
- Long collections stall other requests. That is acceptable for a first
  version; incremental sweeping can come later.

### Failures

| Event | Behaviour |
|---|---|
| Client process dies while computing | lease and upload stage dropped at pipe removal; the next `CLAIM` computes |
| Client host dies or is partitioned | released by TCP keepalive or `max_lease`; waiters wait until then |
| Lease lost while the holder lives | duplicate compute; put-if-absent; the loser delivers the winner |
| Client dies between `PUT_END` and `PUBLISH` | orphan object, collected after `stage_age` |
| Server down or unreachable | `tarshare_storage_error`: the target fails, nothing recomputes silently |
| Server restarts | on-disk state intact (atomic renames as today); leases and uploads were in memory and their pipes are gone |
| Corrupt server object | `CLAIM` validates sizes, and hashes when `verify`; corrupt is a miss and the next upload replaces it, as `shared_publish()` does today |

### Security

- Transport: `tls+tcp://` with nanonext's Mbed TLS, using
  `nanonext::write_cert()` or a site CA. Clients store the CA path in the
  cache config.
- Authentication: a bearer token per deployment, from the environment, on
  every request; a separate admin token for `RELEASE` and `GC`. Mutual TLS has
  not been evaluated: `tls_config()` accepts `auth` for servers, but how the
  server would validate client certificates is not documented there.
- The server treats object bytes as opaque. It validates paths, sizes and
  hashes, and never deserializes client data.
- Unchanged: anyone holding the token can publish a result for any key, and
  readers deserialize it. Share only with trusted collaborators.

### Size and cost

Estimates: the step-0 seam is about 150 lines moved. The client driver is
about 250 new lines and `shared_serve()` about 300. Tests are about 300 lines.
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

1. **Seam.** No behaviour change; all tinytests pass untouched.
2. **nng driver and `shared_serve()`** for `CLAIM`, `PUBLISH`, `ABANDON`,
   objects and the mirror. Run the existing cache tests against a server in
   `callr::r_bg()` on `ipc://`, so CI opens no ports. New tests: a killed
   holder frees its lease; a waiter computes once; a killed uploader commits
   nothing; a server restart; a `PUBLISH` race in which the loser delivers the
   winner; manifest path traversal rejected; wrong token rejected.
3. **Native namespace.** `shared_repository()` over the network, with a batched
   `HAVE` for `list`.
4. **TLS, tokens and admin verbs**, a vignette section, and a URL mode for the
   two-host qualification harness.

Later, only if needed: waiters parked on extra rep contexts and woken with
`race_aio()` instead of polling; an object-store backend behind the server
(B or E as server-side storage, clients unchanged); the C data plane; several
server processes sharded by key prefix; peer mirrors.

## Rejected

- **mirai or crew daemons as the store.** In mirai the host listens and
  daemons dial in to that one host, and daemons evaluate code the host sends.
  A store needs many unrelated clients dialing one service that never
  evaluates client code. Use nanonext sockets directly; mirai and crew remain
  how targets schedules workers.
- **nanonext `http_server()` as the control plane.** It exists in 1.10.4
  (`http_server()`, `handler()`, `handler_stream()`, and `ncurl()` on the
  client), and it would admit curl and other languages. But an HTTP lease
  cannot be tied to a connection, so leases would need wall-clock TTLs again.
  `ncurl()` also returns whole bodies in memory. It remains useful for a
  read-only status or metrics endpoint.
- **Peer-to-peer without a server.** Because objects are content-addressed, any
  peer's copy is valid, which makes peers attractive for moving bytes later.
  Put-if-absent on actions still needs a single authority.

## Open questions

1. Do the target deployments always have a shared mount (HPC), or not (cloud,
   laptops)? If there is always a mount, C first is smaller; otherwise D.
2. Is one server, backed up but not replicated, acceptable for a first
   version?
3. **Owner identity across hosts.** The default owner is the store path as
   seen by the process that runs the target. A crew worker on another host
   sees a different path, and two hosts can have the same path. Two choices:
   resolve the owner on the controller when the graph is built and embed it
   in the command (stable, but moving the store changes the command), or keep
   a random owner id once in the store (stable, but workers may not see the
   store).
4. Should the native CAS (`shared_repository()`) be in the first version, or
   only `shared_run()` and `tar_shared()`?
5. Are R functions enough for administration, or is a command-line wrapper
   needed?

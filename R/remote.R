# Client side of a cache served by shared_serve(). The store decides which
# result a key has (put-if-absent) and who computes it (a lease bound to this
# process's connection). A local mirror, an ordinary filesystem cache, holds
# the objects this host computed or downloaded, so delivered paths are local.
# design/spec/TarshareStore.tla models the protocol.

shared_is_url <- function(path) grepl("^(tcp|tls\\+tcp|ipc)://", path)

shared_remote_cache <- function(url, verify, timeout, poll_interval, tls, mirror,
                                chunk_size) {
  if (!is.null(tls) && (!is.character(tls) || length(tls) != 1L || !file.exists(tls))) {
    stop("tls must be the path of an existing PEM certificate file.", call. = FALSE)
  }
  if (!is.null(mirror) && (!is.character(mirror) || length(mirror) != 1L ||
                           is.na(mirror) || !nzchar(mirror))) {
    stop("mirror must be NULL or one directory path.", call. = FALSE)
  }
  if (!is.numeric(chunk_size) || length(chunk_size) != 1L || is.na(chunk_size) ||
      chunk_size < 1024 || chunk_size > 2^30) {
    stop("chunk_size must be between 1 KiB and 1 GiB.", call. = FALSE)
  }
  structure(
    list(url = url, verify = verify, timeout = timeout, visibility_timeout = 0,
         poll_interval = poll_interval, tls = if (!is.null(tls)) normalizePath(tls),
         mirror = mirror, chunk_size = as.numeric(floor(chunk_size))),
    class = c("tarshare_remote", "tarshare_cache")
  )
}

shared_local_cache <- function(cache, what) {
  if (inherits(cache, "tarshare_remote")) {
    stop(what, " needs a filesystem cache. For a store, run it on the store host ",
         "against the directory given to shared_serve().", call. = FALSE)
  }
  invisible(cache)
}

# The mirror is resolved on each host, never embedded in a target command.
shared_mirror <- function(cache) {
  root <- cache$mirror
  if (is.null(root)) {
    base <- getOption("tarshare.mirror", Sys.getenv("TARSHARE_MIRROR", ""))
    if (!nzchar(base)) base <- tools::R_user_dir("tarshare", "cache")
    root <- file.path(base, substr(digest::digest(cache$url, algo = "sha256",
                                                  serialize = FALSE), 1L, 16L))
  }
  shared_cache(root, verify = cache$verify, timeout = cache$timeout,
               poll_interval = cache$poll_interval)
}

shared_connection <- function(cache) {
  if (!requireNamespace("nanonext", quietly = TRUE)) {
    stop("A store cache requires the nanonext package.", call. = FALSE)
  }
  known <- shared_runtime$connections[[cache$url]]
  # A forked child must not share its parent's socket.
  if (!is.null(known) && identical(known$pid, Sys.getpid())) return(known$socket)
  tls <- if (!is.null(cache$tls)) nanonext::tls_config(client = cache$tls)
  socket <- tryCatch(
    nanonext::socket("req", dial = cache$url, tls = tls, autostart = NA),
    error = function(e) shared_storage_error(paste0(
      "Cannot connect to the tarshare store at ", cache$url, ": ", conditionMessage(e)))
  )
  # Detect a vanished server host; not applicable to ipc://.
  try(nanonext::opt(socket, "tcp-keepalive") <- TRUE, silent = TRUE)
  if (is.null(shared_runtime$connections)) shared_runtime$connections <- list()
  shared_runtime$connections[[cache$url]] <- list(socket = socket, pid = Sys.getpid())
  socket
}

shared_request_timeout <- function() {
  as.integer(1000 * getOption("tarshare.request_timeout", 300))
}

# One request and its reply. Error statuses listed in `accept` are returned;
# any other failure is a hard storage error, never a cache miss.
shared_rpc <- function(cache, method, fields = list(), body = NULL, accept = character()) {
  socket <- shared_connection(cache)
  fields <- c(list(token = Sys.getenv("TARSHARE_TOKEN")), fields)
  frame <- shared_frame("call", method, shared_payload(fields, body))
  timeout <- shared_request_timeout()
  failed <- function(what, value) shared_storage_error(paste0(
    "tarshare store at ", cache$url, ": ", what, " failed for ", method, " (",
    if (inherits(value, "errorValue")) nanonext::nng_error(value) else value, ")."))
  sent <- nanonext::send(socket, frame, mode = "raw", block = timeout)
  if (!identical(sent, 0L)) failed("send", sent)
  reply <- nanonext::recv(socket, mode = "raw", block = timeout)
  if (nanonext::is_error_value(reply)) failed("receive", reply)
  reply <- shared_frame_read(reply)
  if (is.null(reply)) failed("decoding", "malformed reply")
  if (identical(reply$type, "error")) {
    if (isTRUE(reply$status %in% accept)) return(list(status = reply$status))
    shared_storage_error(paste0("tarshare store refused ", method, ": ", reply$error))
  }
  c(list(status = "ok"), shared_payload_read(reply$payload))
}

shared_run_remote <- function(cache, key, expr, envir, format, context, seed, packages,
                              owner, localize) {
  mirror <- shared_mirror(cache)
  claim <- shared_claim(cache, key, format, owner)
  if (identical(claim$fields$state, "granted")) {
    published <- FALSE
    # A crash needs no cleanup: the store drops the lease with the connection.
    on.exit(if (!published) try(shared_rpc(cache, "tarshare.abandon", list(key = key)),
                                silent = TRUE), add = TRUE)
    # Compute through the filesystem path on the mirror, unchanged. It derives
    # the same key, and may reuse a result the mirror already holds.
    eval(as.call(list(shared_run, expr, mirror, format = format, context = context,
                      seed = seed, packages = packages, owner = owner)), envir)
    gate <- shared_gate(mirror)
    action <- tryCatch(shared_read_record(shared_location(mirror, "actions", key)),
                       finally = shared_ungate(mirror, gate))
    if (is.null(action) || !identical(action$key, key)) {
      shared_storage_error("The mirror did not record the computed action.")
    }
    object <- shared_remote_publish(cache, mirror, key, action$object, format, owner)
    published <- TRUE
  } else {
    shared_event("hit", key)
    object <- claim$fields$object
  }
  gate <- shared_gate(mirror)
  on.exit(shared_ungate(mirror, gate), add = TRUE)
  restored <- shared_fetch(cache, mirror, object, format)
  shared_mirror_action(mirror, key, object, format)
  shared_pin(mirror, owner, "actions", key)
  shared_deliver(mirror, restored, localize)
}

# CLAIM until the key is published (a pinned hit) or this client holds its lease.
shared_claim <- function(cache, key, format, owner) {
  start <- proc.time()[[3L]]
  wait <- cache$poll_interval
  repeat {
    reply <- shared_rpc(cache, "tarshare.claim",
                        list(key = key, format = format, owner = owner), accept = "busy")
    if (!identical(reply$status, "busy")) {
      state <- reply$fields$state
      if (identical(state, "granted") ||
          (identical(state, "hit") && shared_is_key(reply$fields$object))) return(reply)
      shared_storage_error("Malformed claim reply from the tarshare store.")
    }
    if (proc.time()[[3L]] - start + wait > cache$timeout) {
      stop("Timed out waiting for shared cache lock action-", key, ".", call. = FALSE)
    }
    Sys.sleep(wait)
    wait <- min(2 * wait, 1)
  }
}

# Upload if needed, then PUBLISH. The store may have collected an object that
# was committed but not yet published; it then answers not_found and the
# object is uploaded again. Returns the object the key resolves to.
shared_remote_publish <- function(cache, mirror, key, object, format, owner) {
  start <- proc.time()[[3L]]
  wait <- cache$poll_interval
  for (attempt in seq_len(100L)) {
    shared_upload(cache, mirror, object)
    reply <- shared_rpc(cache, "tarshare.publish",
                        list(key = key, object = object, format = format, owner = owner),
                        accept = c("not_found", "busy"))
    if (identical(reply$status, "ok")) {
      winner <- reply$fields$object
      if (!shared_is_key(winner)) shared_storage_error("Malformed publish reply.")
      return(winner)
    }
    if (identical(reply$status, "busy")) {
      if (proc.time()[[3L]] - start + wait > cache$timeout) {
        stop("Timed out waiting for shared cache lock action-", key, ".", call. = FALSE)
      }
      Sys.sleep(wait)
      wait <- min(2 * wait, 1)
    }
  }
  shared_storage_error("The tarshare store kept refusing a publication.")
}

shared_upload <- function(cache, mirror, object) {
  if (shared_remote_have(cache, object)) return(invisible(FALSE))
  entry <- shared_location(mirror, "objects", object)
  manifest <- shared_manifest_scan(entry)
  begin <- shared_rpc(cache, "tarshare.put_begin", list(id = object),
                      body = shared_manifest_text(manifest))
  if (identical(begin$fields$state, "present")) return(invisible(FALSE))
  token <- begin$fields$upload
  for (i in seq_along(manifest$files)) {
    connection <- file(file.path(entry, manifest$files[[i]]), open = "rb")
    offset <- 0
    tryCatch(repeat {
      bytes <- readBin(connection, raw(), n = cache$chunk_size)
      if (!length(bytes)) break
      shared_rpc(cache, "tarshare.put_chunk",
                 list(upload = token, file = i, offset = sprintf("%.0f", offset)),
                 body = bytes)
      offset <- offset + length(bytes)
    }, finally = close(connection))
  }
  shared_rpc(cache, "tarshare.put_end", list(upload = token))
  invisible(TRUE)
}

shared_remote_have <- function(cache, object) {
  identical(shared_rpc(cache, "tarshare.have", list(ids = object))$fields$present, "1")
}

# Make sure the object is in the mirror, downloading and verifying it if not.
shared_fetch <- function(cache, mirror, object, format) {
  entry <- shared_location(mirror, "objects", object)
  record <- shared_object_read(entry, mirror$verify, object)
  if (is.null(record)) {
    reply <- shared_rpc(cache, "tarshare.manifest", list(id = object))
    manifest <- shared_manifest_read(reply$body)
    if (is.null(manifest)) shared_storage_error("Malformed object manifest from the store.")
    stage <- shared_stage(mirror, "objects")
    on.exit(unlink(stage, recursive = TRUE), add = TRUE)
    for (dir in manifest$directories) shared_mkdir(file.path(stage, dir))
    for (i in seq_along(manifest$files)) {
      path <- file.path(stage, manifest$files[[i]])
      shared_mkdir(dirname(path))
      connection <- file(path, open = "wb")
      offset <- 0
      tryCatch(while (offset < manifest$sizes[[i]]) {
        n <- min(cache$chunk_size, manifest$sizes[[i]] - offset)
        bytes <- shared_rpc(cache, "tarshare.get_chunk",
                            list(id = object, file = i, offset = sprintf("%.0f", offset),
                                 length = sprintf("%.0f", n)))$body
        if (length(bytes) != n) shared_storage_error("Short read from the tarshare store.")
        writeBin(bytes, connection)
        offset <- offset + n
      }, finally = close(connection))
      if (!identical(shared_file_hash(path), manifest$hashes[[i]])) {
        shared_storage_error(paste("Downloaded file failed verification:", manifest$files[[i]]))
      }
    }
    if (is.null(shared_object_read(stage, TRUE, object))) {
      shared_storage_error("Downloaded object failed verification.")
    }
    lock <- shared_lock(mirror, paste0("object-", object))
    tryCatch({
      if (is.null(shared_object_read(entry, mirror$verify, object))) {
        shared_publish(stage, entry)
      }
    }, finally = filelock::unlock(lock))
    record <- shared_object_read(entry, mirror$verify, object)
    if (is.null(record)) shared_storage_error("Mirrored object is not readable.")
  }
  if (!identical(record$format, format)) {
    shared_storage_error("The store returned an object of another format.")
  }
  list(record = record, path = entry)
}

# Record locally which object the store resolved the key to, so the mirror is
# an ordinary cache that its own retention and collection understand.
shared_mirror_action <- function(mirror, key, object, format) {
  lock <- shared_lock(mirror, paste0("action-", key))
  on.exit(filelock::unlock(lock), add = TRUE)
  action <- shared_read_record(shared_location(mirror, "actions", key))
  if (is.null(action) || !identical(action$object, object) ||
      !identical(action$format, format)) {
    shared_publish_action(mirror, key, object, format)
  }
  invisible(NULL)
}

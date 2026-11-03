#' Serve a cache directory to other hosts
#'
#' Runs a store for [shared_cache()] clients given a `tcp://`, `tls+tcp://` or
#' `ipc://` URL, so hosts without a shared filesystem share one cache. The
#' process serves until it is interrupted or killed.
#'
#' The directory stays an ordinary filesystem cache. Run [shared_gc()],
#' [shared_references()], [shared_retain()] and [shared_release()] against it
#' on the store host, with the store running or not: each request takes the
#' cache's shared maintenance lock, so collection waits for it and it waits for
#' collection.
#'
#' The store decides which object a key resolves to. Publication is
#' put-if-absent, so when two clients compute the same key, both deliver the
#' first published result. A client computes only while it holds the key's
#' lease, which is bound to its network connection: a client that exits or
#' crashes releases it at once, without heartbeats, while a long computation
#' keeps it. A lease lost while its holder still runs (a network failure, a
#' store restart) costs a duplicate computation, never a second result. Results
#' are pinned for the requesting owner in the same step as the lookup or
#' publication, so collection cannot remove a result between the two.
#' `design/spec/TarshareStore.tla` in the source repository models this
#' protocol.
#'
#' The store never deserializes data it receives. It checks the size and
#' SHA-256 of every uploaded file and that the object's record hashes to its
#' id. Clients verify everything they download before using it.
#'
#' @param path Cache directory to serve. It is created if needed.
#' @param url Listening URL, for example `"tls+tcp://0.0.0.0:5555"`.
#' @param tls For `tls+tcp://`: a server configuration from
#'   `nanonext::tls_config(server = ...)`.
#' @param token Access token required in every request. Clients send the value
#'   of their `TARSHARE_TOKEN` environment variable. An empty token disables
#'   the check; use that only for `ipc://` on a single host.
#' @param max_message Largest accepted message in bytes. It must exceed the
#'   clients' `chunk_size`.
#' @return Does not return normally.
#' @export
shared_serve <- function(path, url, tls = NULL, token = Sys.getenv("TARSHARE_TOKEN"),
                         max_message = 64 * 2^20) {
  if (!requireNamespace("nanonext", quietly = TRUE)) {
    stop("shared_serve() requires the nanonext package.", call. = FALSE)
  }
  if (!is.character(url) || length(url) != 1L || !shared_is_url(url)) {
    stop("url must be one tcp://, tls+tcp:// or ipc:// URL.", call. = FALSE)
  }
  if (!is.character(token) || length(token) != 1L || is.na(token)) {
    stop("token must be one string.", call. = FALSE)
  }
  cache <- shared_cache(path, verify = FALSE)
  state <- new.env(parent = emptyenv())
  state$leases <- list()  # key -> list(pipe, lock)
  state$uploads <- list() # token -> list(pipe, stage, id, manifest)
  state$pipes <- integer()
  socket <- nanonext::socket("rep")
  on.exit({
    shared_serve_drop(state, c(state$pipes, unlist(lapply(state$leases, `[[`, "pipe"))))
    close(socket)
  }, add = TRUE)
  nanonext::opt(socket, "recv-size-max") <- as.integer(max_message + 65536)
  try(nanonext::opt(socket, "tcp-keepalive") <- TRUE, silent = TRUE)
  cv <- nanonext::cv()
  # Monitor before listening, so no connection's arrival is missed.
  monitor <- nanonext::monitor(socket, cv)
  nanonext::listen(socket, url = url, tls = tls, fail = "error")
  context <- nanonext::context(socket)
  message("tarshare store: serving ", cache$path, " at ", url)
  aio <- nanonext::recv_aio(context, mode = "raw", cv = cv)
  repeat {
    nanonext::wait(cv)
    # Pipe ids: positive when a connection opens, negative when it closes.
    events <- as.integer(nanonext::read_monitor(monitor))
    state$pipes <- union(state$pipes, events[events > 0])
    gone <- -events[events < 0]
    if (length(gone)) {
      state$pipes <- setdiff(state$pipes, gone)
      shared_serve_drop(state, gone)
    }
    if (nanonext::unresolved(aio)) next
    request <- aio$data
    if (!nanonext::is_error_value(request)) {
      reply <- shared_serve_reply(cache, state, request, nanonext::pipe_id(aio), token)
      nanonext::send(context, reply, mode = "raw", block = 10000L)
    }
    aio <- nanonext::recv_aio(context, mode = "raw", cv = cv)
  }
}

# A closed connection loses its leases and its unfinished uploads.
shared_serve_drop <- function(state, pipes) {
  for (key in names(state$leases)) {
    lease <- state$leases[[key]]
    if (lease$pipe %in% pipes) {
      filelock::unlock(lease$lock)
      state$leases[[key]] <- NULL
    }
  }
  for (token in names(state$uploads)) {
    upload <- state$uploads[[token]]
    if (upload$pipe %in% pipes) {
      unlink(upload$stage, recursive = TRUE)
      state$uploads[[token]] <- NULL
    }
  }
  invisible(NULL)
}

shared_serve_reply <- function(cache, state, bytes, pipe, token) {
  frame <- shared_frame_read(bytes)
  if (is.null(frame) || !identical(frame$type, "call")) {
    return(shared_frame_error("invalid", "Malformed request frame."))
  }
  request <- shared_payload_read(frame$payload)
  if (nzchar(token) && !identical(request$fields$token, token)) {
    return(shared_frame_error("unauthorized", "Invalid or missing access token."))
  }
  handler <- switch(frame$name,
    "tarshare.claim" = shared_serve_claim, "tarshare.publish" = shared_serve_publish,
    "tarshare.abandon" = shared_serve_abandon, "tarshare.have" = shared_serve_have,
    "tarshare.put_begin" = shared_serve_put_begin,
    "tarshare.put_chunk" = shared_serve_put_chunk,
    "tarshare.put_end" = shared_serve_put_end,
    "tarshare.manifest" = shared_serve_manifest,
    "tarshare.get_chunk" = shared_serve_get_chunk, NULL)
  if (is.null(handler)) return(shared_frame_error("invalid", "Unknown method."))
  tryCatch({
    result <- shared_serve_gated(cache, handler, state, request, pipe)
    if (is.character(result) && length(result) == 1L && result %in% names(shared_wire_status)) {
      shared_frame_error(result, paste("Request refused:", result))
    } else {
      shared_frame("result", frame$name, shared_payload(result$fields, result$body))
    }
  }, tarshare_invalid = function(e) shared_frame_error("invalid", conditionMessage(e)),
  error = function(e) shared_frame_error("internal", conditionMessage(e)))
}

# Each request holds the shared maintenance lock, so collection by
# shared_gc() on the store host waits for it, and it for collection.
shared_serve_gated <- function(cache, handler, state, request, pipe) {
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  handler(cache, state, request$fields, request$body, pipe)
}

shared_serve_invalid <- function(message) {
  stop(structure(list(message = message, call = NULL),
                 class = c("tarshare_invalid", "error", "condition")))
}

shared_serve_field <- function(fields, name, check = NULL) {
  value <- fields[[name]]
  if (!is.character(value) || length(value) != 1L || !nzchar(value) ||
      (!is.null(check) && !isTRUE(check(value)))) {
    shared_serve_invalid(paste("Missing or invalid field:", name))
  }
  value
}

shared_serve_number <- function(fields, name) {
  value <- suppressWarnings(as.numeric(shared_serve_field(fields, name)))
  if (is.na(value) || value < 0 || value != floor(value)) {
    shared_serve_invalid(paste("Invalid number:", name))
  }
  value
}

# An object is served only with a manifest whose files are all present at
# their recorded sizes and whose record hashes to its id. Objects published by
# filesystem clients get a manifest on first use.
shared_serve_object <- function(cache, id) {
  entry <- shared_location(cache, "objects", id)
  if (!shared_is_key(id) || !dir.exists(entry) ||
      !all(file.exists(file.path(entry, c("complete", "result.rds"))))) return(NULL)
  path <- file.path(entry, "manifest.tsv")
  manifest <- if (file.exists(path)) shared_manifest_read(readLines(path, warn = FALSE))
  if (is.null(manifest)) {
    complete <- readLines(file.path(entry, "complete"), warn = FALSE)
    if (!identical(complete, id) ||
        !identical(shared_file_hash(file.path(entry, "result.rds")), id)) return(NULL)
    manifest <- shared_manifest_scan(entry)
    temporary <- tempfile(".manifest-", tmpdir = entry)
    writeLines(shared_manifest_text(manifest), temporary)
    file.rename(temporary, path)
  }
  files <- file.path(entry, manifest$files)
  if (!all(file.exists(files)) || !identical(unname(file.info(files)$size), manifest$sizes) ||
      !identical(readLines(file.path(entry, "complete"), warn = FALSE), id) ||
      !identical(manifest$hashes[manifest$files == "result.rds"], id)) return(NULL)
  list(entry = entry, manifest = manifest)
}

# The published object of a key, or NULL. Action records are written by this
# server or by filesystem clients of the same directory.
shared_serve_action <- function(cache, key, format) {
  action <- shared_read_record(shared_location(cache, "actions", key))
  if (is.null(action) || !identical(action$schema, 1L) || !identical(action$key, key) ||
      !identical(action$format, format) || !shared_is_key(action$object) ||
      is.null(shared_serve_object(cache, action$object))) return(NULL)
  action$object
}

shared_serve_key_fields <- function(fields) {
  list(key = shared_serve_field(fields, "key", shared_is_key),
       format = shared_serve_field(fields, "format", function(x) x %in% c("rds", "file")),
       owner = shared_serve_field(fields, "owner"))
}

shared_serve_claim <- function(cache, state, fields, body, pipe) {
  args <- shared_serve_key_fields(fields)
  hit <- function(object) {
    shared_pin(cache, args$owner, "actions", args$key)
    list(fields = list(state = "hit", object = object))
  }
  object <- shared_serve_action(cache, args$key, args$format)
  if (!is.null(object)) return(hit(object))
  lease <- state$leases[[args$key]]
  if (!is.null(lease)) {
    # A resent claim from the holder is granted again.
    return(if (identical(lease$pipe, pipe)) list(fields = list(state = "granted")) else "busy")
  }
  # Leases go only to live connections, and the action lock excludes
  # filesystem clients of the same directory while the lease lasts.
  if (!pipe %in% state$pipes) return("busy")
  lock <- filelock::lock(file.path(shared_location(cache, "locks"),
                                   paste0("action-", args$key, ".lock")), timeout = 0)
  if (is.null(lock)) return("busy")
  object <- shared_serve_action(cache, args$key, args$format)
  if (!is.null(object)) {
    filelock::unlock(lock)
    return(hit(object))
  }
  state$leases[[args$key]] <- list(pipe = pipe, lock = lock)
  list(fields = list(state = "granted"))
}

shared_serve_publish <- function(cache, state, fields, body, pipe) {
  args <- shared_serve_key_fields(fields)
  object <- shared_serve_field(fields, "object", shared_is_key)
  if (is.null(shared_serve_object(cache, object))) return("not_found")
  lease <- state$leases[[args$key]]
  lock <- NULL
  if (is.null(lease)) {
    # Publishing without a lease (it was lost) still needs the action lock.
    lock <- filelock::lock(file.path(shared_location(cache, "locks"),
                                     paste0("action-", args$key, ".lock")), timeout = 0)
    if (is.null(lock)) return("busy")
  }
  on.exit(if (!is.null(lock)) filelock::unlock(lock), add = TRUE)
  winner <- shared_serve_action(cache, args$key, args$format)
  if (is.null(winner)) {
    shared_publish_action(cache, args$key, object, args$format)
    winner <- object
  }
  shared_pin(cache, args$owner, "actions", args$key)
  if (!is.null(lease) && identical(lease$pipe, pipe)) {
    filelock::unlock(lease$lock)
    state$leases[[args$key]] <- NULL
  }
  list(fields = list(object = winner))
}

shared_serve_abandon <- function(cache, state, fields, body, pipe) {
  key <- shared_serve_field(fields, "key", shared_is_key)
  lease <- state$leases[[key]]
  if (!is.null(lease) && identical(lease$pipe, pipe)) {
    filelock::unlock(lease$lock)
    state$leases[[key]] <- NULL
  }
  list(fields = list(state = "ok"))
}

shared_serve_have <- function(cache, state, fields, body, pipe) {
  ids <- strsplit(shared_serve_field(fields, "ids"), " ", fixed = TRUE)[[1L]]
  present <- vapply(ids, function(id) !is.null(shared_serve_object(cache, id)), logical(1))
  list(fields = list(present = paste(as.integer(present), collapse = "")))
}

shared_serve_put_begin <- function(cache, state, fields, body, pipe) {
  id <- shared_serve_field(fields, "id", shared_is_key)
  if (!is.null(shared_serve_object(cache, id))) return(list(fields = list(state = "present")))
  manifest <- shared_manifest_read(body)
  if (is.null(manifest) || !identical(manifest$hashes[manifest$files == "result.rds"], id)) {
    shared_serve_invalid("Invalid object manifest.")
  }
  stage <- shared_stage(cache, "objects")
  for (dir in manifest$directories) shared_mkdir(file.path(stage, dir))
  for (file in manifest$files) {
    shared_mkdir(dirname(file.path(stage, file)))
    file.create(file.path(stage, file))
  }
  token <- nanonext::random(16L)
  state$uploads[[token]] <- list(pipe = pipe, stage = stage, id = id, manifest = manifest)
  list(fields = list(state = "upload", upload = token))
}

shared_serve_upload <- function(state, fields, pipe) {
  upload <- state$uploads[[shared_serve_field(fields, "upload")]]
  if (is.null(upload) || !identical(upload$pipe, pipe)) return(NULL)
  upload
}

# Positional writes make a resent chunk harmless.
shared_serve_put_chunk <- function(cache, state, fields, body, pipe) {
  upload <- shared_serve_upload(state, fields, pipe)
  if (is.null(upload)) return("not_found")
  i <- shared_serve_number(fields, "file")
  offset <- shared_serve_number(fields, "offset")
  if (i < 1 || i > length(upload$manifest$files) ||
      offset + length(body) > upload$manifest$sizes[[i]]) {
    shared_serve_invalid("Chunk outside the declared file.")
  }
  connection <- file(file.path(upload$stage, upload$manifest$files[[i]]), open = "r+b")
  on.exit(close(connection), add = TRUE)
  seek(connection, offset, rw = "write")
  writeBin(body, connection)
  # Keep a long upload from looking abandoned to shared_gc().
  Sys.setFileTime(upload$stage, Sys.time())
  list(fields = list(state = "ok"))
}

shared_serve_put_end <- function(cache, state, fields, body, pipe) {
  token <- shared_serve_field(fields, "upload")
  upload <- shared_serve_upload(state, fields, pipe)
  if (is.null(upload)) return("not_found")
  state$uploads[[token]] <- NULL
  on.exit(unlink(upload$stage, recursive = TRUE), add = TRUE)
  manifest <- upload$manifest
  files <- file.path(upload$stage, manifest$files)
  if (!identical(unname(file.info(files)$size), manifest$sizes) ||
      !identical(vapply(files, shared_file_hash, character(1), USE.NAMES = FALSE),
                 manifest$hashes) ||
      !identical(readLines(file.path(upload$stage, "complete"), warn = FALSE), upload$id)) {
    shared_serve_invalid("Uploaded object failed verification.")
  }
  writeLines(shared_manifest_text(manifest), file.path(upload$stage, "manifest.tsv"))
  entry <- shared_location(cache, "objects", upload$id)
  lock <- shared_lock(cache, paste0("object-", upload$id))
  tryCatch({
    if (is.null(shared_serve_object(cache, upload$id))) shared_publish(upload$stage, entry)
  }, finally = filelock::unlock(lock))
  list(fields = list(state = "committed"))
}

shared_serve_manifest <- function(cache, state, fields, body, pipe) {
  object <- shared_serve_object(cache, shared_serve_field(fields, "id", shared_is_key))
  if (is.null(object)) return("not_found")
  list(fields = list(state = "ok"), body = shared_manifest_text(object$manifest))
}

shared_serve_get_chunk <- function(cache, state, fields, body, pipe) {
  object <- shared_serve_object(cache, shared_serve_field(fields, "id", shared_is_key))
  if (is.null(object)) return("not_found")
  i <- shared_serve_number(fields, "file")
  offset <- shared_serve_number(fields, "offset")
  n <- shared_serve_number(fields, "length")
  if (i < 1 || i > length(object$manifest$files) || offset + n > object$manifest$sizes[[i]]) {
    shared_serve_invalid("Chunk outside the file.")
  }
  connection <- file(file.path(object$entry, object$manifest$files[[i]]), open = "rb")
  on.exit(close(connection), add = TRUE)
  seek(connection, offset)
  list(fields = list(state = "ok"), body = readBin(connection, raw(), n = n))
}

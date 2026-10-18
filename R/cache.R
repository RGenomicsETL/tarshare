#' Configure a shared filesystem cache
#'
#' The directory must be visible at the same path to all workers that consume
#' cached file outputs. It must support operating-system file locks and atomic
#' directory renames within the filesystem. Use a cache shared with trusted
#' collaborators: reading an R cache is not a sandbox for untrusted objects.
#'
#' @param path Cache directory, independent of any individual targets store.
#' @param verify Verify the contents of cached output files on each cache hit.
#'   Set to `FALSE` only for an externally enforced immutable cache. Record
#'   integrity and bundle completeness are checked either way.
#' @param timeout Seconds to wait for another process computing the same key.
#'   The default waits until the other process finishes or exits.
#' @param visibility_timeout Maximum seconds to retry a missing or incomplete
#'   result after acquiring its lock. Zero is appropriate for a local filesystem.
#' @param poll_interval Seconds between visibility retries.
#' @return A cache configuration object. Construction creates the directory.
#' @export
#' @examples
#' cache <- shared_cache(tempfile("shared-cache-"))
#' shared_run(sum(1:10), cache)
shared_cache <- function(path, verify = TRUE, timeout = Inf,
                         visibility_timeout = 0, poll_interval = 0.05) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("path must be one nonempty directory path.", call. = FALSE)
  }
  if (!is.logical(verify) || length(verify) != 1L || is.na(verify)) {
    stop("verify must be TRUE or FALSE.", call. = FALSE)
  }
  if (!is.numeric(timeout) || length(timeout) != 1L || is.na(timeout) || timeout < 0) {
    stop("timeout must be a nonnegative number of seconds.", call. = FALSE)
  }
  shared_seconds(visibility_timeout, "visibility_timeout")
  shared_seconds(poll_interval, "poll_interval", positive = TRUE)
  path <- path.expand(path)
  shared_mkdir(path)
  for (kind in c("actions", "objects", "native", "refs", "locks", "exports")) {
    shared_mkdir(file.path(path, "v2", kind))
  }
  structure(
    list(path = normalizePath(path, winslash = "/"), verify = verify, timeout = timeout,
         visibility_timeout = visibility_timeout, poll_interval = poll_interval),
    class = "tarshare_cache"
  )
}

#' Reuse the result of a computation
#'
#' Captures `command` without evaluating it. A computation key combines its code,
#' statically discovered referenced values and helpers, package identities,
#' `context`, and `seed`. A hit restores the result; a miss evaluates the command
#' under a lock for that key and publishes the complete successful result.
#'
#' @param command R expression to evaluate only on a cache miss.
#' @param cache Configuration from [shared_cache()].
#' @param format `"rds"` for self-contained R values or `"file"` for paths to files
#'   or directories created below [shared_path()]. All sidecar files in that
#'   directory are retained together, preserving their names and structure.
#' @param context Explicit values for relevant state outside ordinary R dependency
#'   analysis: for example an immutable container image ID, external program
#'   version, database snapshot, sample label, or deliberate cache generation.
#' @param seed Nonnegative integer mixed into the computation identity. Random
#'   numbers use a key-derived seed with L'Ecuyer-CMRG, Inversion, and Rejection.
#'   The caller's RNG state is restored. Independent random replicates must have
#'   distinct input or context values, or a different `seed`.
#' @param packages Additional installed packages whose versions should enter the
#'   key. Namespaced calls and functions' namespaces are discovered automatically.
#' @param owner Retention owner. Defaults to the current targets store, or the
#'   working directory for standalone calls. References are cumulative until
#'   explicitly released with [shared_release()]. Not part of the action key.
#' @param localize Copy file outputs to disposable cache-local export staging.
#'   Used by the target factory for nonlocal repositories which may move inputs.
#'   Return the bundle directory or explicitly return every sidecar in this mode.
#' @return The R value or the cache-owned paths returned by the computation.
#' @details
#' Use deterministic computations with explicit inputs. Static code analysis
#' cannot discover dynamic lookups, changing network/database state, options,
#' environment variables, or external executables. Declare those dependencies in
#' `context`. Plain character paths are ordinary R values: use [shared_file()] to
#' identify a file by its contents. That declaration assumes output semantics do
#' not depend on the file's physical location.
#'
#' Cache entries and returned files are immutable. Do not modify them in place.
#' Use `format = "file"` for file artifacts; an RDS object containing paths to a
#' temporary or project directory does not preserve those files. This package
#' never rewrites arbitrary path strings inside R objects.
#'
#' A condition of class `tarshare_event` is emitted as a message for each hit or
#' computation. Its `event` and `key` fields are available to calling handlers.
#' @export
#' @examples
#' cache <- shared_cache(tempfile("shared-cache-"))
#' x <- 1:10
#' shared_run(mean(x), cache)
#' shared_run(mean(x), cache)
#' shared_run({
#'   path <- shared_path("summary.txt")
#'   writeLines(as.character(mean(x)), path)
#'   path
#' }, cache, format = "file")
shared_run <- function(command, cache, format = "rds", context = list(),
                       seed = 0L, packages = character(), owner = shared_owner(),
                       localize = FALSE) {
  expr <- substitute(command)
  envir <- parent.frame()
  if (!inherits(cache, "tarshare_cache")) {
    stop("cache must be created with shared_cache().", call. = FALSE)
  }
  format <- match.arg(format, c("rds", "file"))
  shared_owner_check(owner)
  shared_flag(localize, "localize")
  identity <- shared_identity(
    expr, envir, list(format = format, context = context), seed, packages
  )
  key <- identity$key
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  lock <- shared_lock(cache, paste0("action-", key))
  on.exit(filelock::unlock(lock), add = TRUE, after = FALSE)
  restored <- shared_retry(cache, function() shared_restore(cache, key, format))
  if (is.null(restored)) {
    stage <- shared_stage(cache, "objects")
    on.exit(unlink(stage, recursive = TRUE), add = TRUE, after = FALSE)
    shared_mkdir(file.path(stage, "files"))
    shared_event("compute", key)
    value <- shared_compute(expr, envir, identity$seed, stage, format)
    record <- list(schema = 2L, format = format)
    if (identical(format, "file")) {
      record$bundle <- shared_bundle(value, file.path(stage, "files"))
    } else {
      shared_assert_value(value)
      record$value <- value
    }
    object <- shared_write_record(record, stage)
    object_path <- shared_location(cache, "objects", object)
    object_lock <- shared_lock(cache, paste0("object-", object))
    tryCatch({
      if (is.null(shared_object_read(object_path, cache$verify, object))) {
        shared_publish(stage, object_path)
      }
    }, finally = filelock::unlock(object_lock))
    # Publish the action only after the complete content object is readable.
    restored <- shared_retry(cache, function() {
      record <- shared_object_read(object_path, cache$verify, object)
      if (is.null(record)) NULL else list(record = record, path = object_path)
    })
    if (is.null(restored)) shared_storage_error("Published object is not readable.")
    action_stage <- shared_stage(cache, "actions")
    on.exit(unlink(action_stage, recursive = TRUE), add = TRUE, after = FALSE)
    shared_write_record(list(schema = 2L, key = key, object = object,
                             format = format), action_stage)
    shared_publish(action_stage, shared_location(cache, "actions", key))
  } else {
    shared_event("hit", key)
  }
  # A retained owner reference outlives this invocation and any local store.
  shared_pin(cache, owner, "actions", key)
  shared_deliver(cache, restored, localize)
}

shared_runtime <- new.env(parent = emptyenv())

shared_compute <- function(expr, envir, seed, stage, format) {
  previous <- shared_runtime$current
  shared_runtime$current <- list(path = file.path(stage, "files"), format = format)
  on.exit(shared_runtime$current <- previous, add = TRUE)
  kind <- RNGkind()
  had_seed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_seed <- if (had_seed) get(".Random.seed", envir = globalenv()) else NULL
  on.exit({
    do.call(RNGkind, as.list(kind))
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = globalenv())
    } else if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
      rm(list = ".Random.seed", envir = globalenv())
    }
  }, add = TRUE)
  set.seed(seed, kind = "L'Ecuyer-CMRG", normal.kind = "Inversion", sample.kind = "Rejection")
  eval(expr, envir = envir)
}

shared_restore <- function(cache, key, format) {
  action <- shared_read_record(shared_location(cache, "actions", key))
  if (is.null(action) || !identical(action$schema, 2L) ||
      !identical(action$key, key) || !identical(action$format, format) ||
      !shared_is_key(action$object)) return(NULL)
  path <- shared_location(cache, "objects", action$object)
  record <- shared_object_read(path, cache$verify, action$object)
  if (is.null(record) || !identical(record$format, format)) return(NULL)
  list(record = record, path = path)
}

shared_publish <- function(stage, entry) {
  previous <- NULL
  if (file.exists(entry)) {
    previous <- tempfile(pattern = ".replaced-", tmpdir = dirname(entry))
    if (!file.rename(entry, previous)) {
      stop("Could not replace an invalid cache entry.", call. = FALSE)
    }
  }
  if (!file.rename(stage, entry)) {
    if (!is.null(previous)) {
      file.rename(previous, entry)
    }
    stop("Could not atomically publish the cache entry.", call. = FALSE)
  }
  if (!is.null(previous)) {
    unlink(previous, recursive = TRUE)
  }
  invisible(NULL)
}

shared_mkdir <- function(path) {
  if (!dir.exists(path) && !dir.create(path, recursive = TRUE, showWarnings = FALSE) &&
      !dir.exists(path)) {
    stop("Could not create directory: ", path, call. = FALSE)
  }
  invisible(path)
}

shared_file_hash <- function(path) {
  digest::digest(file = path, algo = "sha256", serialize = FALSE)
}

shared_event <- function(event, key) {
  message(structure(
    list(message = paste0("tarshare ", event, " ", substr(key, 1L, 12L), "\n"),
         call = NULL, event = event, key = key),
    class = c("tarshare_event", "message", "condition")
  ))
}

shared_assert_value <- function(value) {
  if (missing(value)) return(invisible(NULL))
  if (is.environment(value) || typeof(value) %in% c("externalptr", "weakref") ||
      inherits(value, "connection") || is.function(value)) {
    stop("Cached outputs must be self-contained values, not live resources or functions.",
         call. = FALSE)
  }
  if (isS4(value)) {
    for (name in methods::slotNames(value)) {
      shared_assert_value(methods::slot(value, name))
    }
  } else if (is.list(value) || is.pairlist(value) || is.expression(value) || is.call(value)) {
    invisible(lapply(as.list.default(value), shared_assert_value))
  }
  for (attribute in attributes(value)) {
    shared_assert_value(attribute)
  }
  invisible(NULL)
}

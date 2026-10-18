# Versioned layout: old caches remain untouched, including during collection.
shared_location <- function(cache, kind, key = NULL) {
  root <- file.path(cache$path, "v2", kind)
  if (is.null(key)) root else file.path(root, key)
}

shared_is_key <- function(key) {
  is.character(key) && length(key) == 1L && !is.na(key) &&
    grepl("^[a-f0-9]{64}$", key)
}

shared_flag <- function(value, name) {
  if (!is.logical(value) || length(value) != 1L || is.na(value)) {
    stop(name, " must be TRUE or FALSE.", call. = FALSE)
  }
}

shared_seconds <- function(value, name, positive = FALSE) {
  if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
      !is.finite(value) || value < 0 || (positive && value == 0)) {
    stop(name, " must be a finite ", if (positive) "positive" else "nonnegative",
         " number of seconds.", call. = FALSE)
  }
}

shared_storage_error <- function(message) {
  stop(structure(list(message = message, call = NULL),
                 class = c("tarshare_storage_error", "error", "condition")))
}

shared_lock <- function(cache, key, exclusive = TRUE, timeout = cache$timeout) {
  lock <- filelock::lock(file.path(shared_location(cache, "locks"), paste0(key, ".lock")),
                         exclusive = exclusive, timeout = timeout * 1000)
  if (is.null(lock)) {
    stop("Timed out waiting for shared cache lock ", key, ".", call. = FALSE)
  }
  lock
}

# Lock order is maintenance gate -> action/native key -> content key -> pin.
# Never open the same lock twice in one process: POSIX locks are process-owned.
shared_gate <- function(cache, exclusive = FALSE) {
  if (is.null(shared_runtime$gates)) shared_runtime$gates <- character()
  if (cache$path %in% shared_runtime$gates) {
    stop("Nested operations on the same shared cache are unsupported.", call. = FALSE)
  }
  gate <- shared_lock(cache, "maintenance", exclusive = exclusive)
  shared_runtime$gates <- c(shared_runtime$gates, cache$path)
  gate
}

shared_ungate <- function(cache, gate) {
  filelock::unlock(gate)
  shared_runtime$gates <- setdiff(shared_runtime$gates, cache$path)
  invisible(NULL)
}

shared_stage <- function(cache, kind) {
  path <- tempfile(".stage-", tmpdir = shared_location(cache, kind))
  shared_mkdir(path)
  path
}

shared_write_record <- function(record, path) {
  file <- file.path(path, "result.rds")
  saveRDS(record, file, compress = FALSE, version = 3L)
  hash <- shared_file_hash(file)
  writeLines(hash, file.path(path, "complete"))
  hash
}

shared_read_record <- function(path, expected = NULL) {
  files <- file.path(path, c("complete", "result.rds"))
  if (!all(file.exists(files))) return(NULL)
  if (any(file.access(files, 4L) != 0L)) {
    shared_storage_error(paste("Cannot read cache record:", path))
  }
  checksum <- readLines(files[[1L]], warn = FALSE)
  if (!shared_is_key(checksum) ||
      (!is.null(expected) && !identical(checksum, expected)) ||
      !identical(checksum, shared_file_hash(files[[2L]]))) return(NULL)
  # Checksum-valid I/O/deserialization failures are errors, not cache misses.
  readRDS(files[[2L]])
}

shared_object_read <- function(path, verify, expected = NULL) {
  record <- shared_read_record(path, expected)
  if (is.null(record) || !identical(record$schema, 2L) ||
      !isTRUE(record$format %in% c("rds", "file"))) return(NULL)
  if (identical(record$format, "file") &&
      !shared_bundle_valid(path, record$bundle, verify)) return(NULL)
  record
}

shared_retry <- function(cache, read) {
  start <- proc.time()[[3L]]
  repeat {
    result <- read()
    if (!is.null(result)) return(result)
    left <- cache$visibility_timeout - (proc.time()[[3L]] - start)
    if (left <= 0) return(NULL)
    Sys.sleep(min(left, cache$poll_interval))
  }
}

shared_copy_path <- function(from, to) {
  if (!file.exists(from)) shared_storage_error(paste("Missing source:", from))
  link <- Sys.readlink(from)
  if (!is.na(link) && nzchar(link)) {
    stop("Cached file bundles cannot contain symbolic links.", call. = FALSE)
  }
  if (dir.exists(from)) {
    inventory <- shared_scan_bundle(from)
    shared_mkdir(to)
    for (dir in shared_relative(inventory$directories, from)) {
      shared_mkdir(file.path(to, dir))
    }
    relative <- shared_relative(inventory$files, from)
    for (i in seq_along(relative)) {
      if (!file.copy(inventory$files[[i]], file.path(to, relative[[i]]),
                     copy.mode = TRUE, copy.date = TRUE)) {
        shared_storage_error("Could not copy a cached bundle file.")
      }
    }
  } else {
    shared_mkdir(dirname(to))
    if (!file.copy(from, to, copy.mode = TRUE, copy.date = TRUE)) {
      shared_storage_error(paste("Could not copy cached file:", from))
    }
  }
  invisible(to)
}

shared_deliver <- function(cache, restored, localize) {
  record <- restored$record
  if (identical(record$format, "rds")) return(record$value)
  path <- restored$path
  if (localize) {
    bundle <- record$bundle
    covered <- vapply(bundle$files, function(file) {
      any(bundle$paths == "" | file == bundle$paths |
          startsWith(file, paste0(bundle$paths, "/")))
    }, logical(1))
    if (!all(covered)) {
      stop("Nonlocal file targets must return the bundle directory or every sidecar.",
           call. = FALSE)
    }
    path <- shared_stage(cache, "exports")
    shared_copy_path(file.path(restored$path, "files"), file.path(path, "files"))
  }
  shared_bundle_paths(path, record$bundle)
}

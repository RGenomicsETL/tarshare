#' Identify a retention owner
#'
#' @param store A targets store path, or NULL to select the running pipeline.
#' @return A stable owner string. Outside targets, defaults to the working directory.
#' @export
shared_owner <- function(store = NULL) {
  if (is.null(store) && targets::tar_active()) store <- targets::tar_path_store()
  if (!is.null(store)) {
    store <- path.expand(store)
    if (!grepl("^(/|[A-Za-z]:[/\\\\]|\\\\\\\\)", store)) store <- file.path(getwd(), store)
    return(paste0("targets:", normalizePath(store, winslash = "/", mustWork = FALSE)))
  }
  paste0("R:", normalizePath(getwd(), winslash = "/", mustWork = TRUE))
}

shared_owner_check <- function(owner) {
  if (!is.character(owner) || length(owner) != 1L || is.na(owner) || !nzchar(owner)) {
    stop("owner must be one nonempty string.", call. = FALSE)
  }
}

shared_pin <- function(cache, owner, kind, key) {
  id <- digest::digest(owner, algo = "sha256", serialize = FALSE)
  lock <- shared_lock(cache, paste0("owner-", id))
  on.exit(filelock::unlock(lock), add = TRUE)
  parent <- file.path(shared_location(cache, "refs"), id)
  shared_mkdir(parent)
  path <- file.path(parent, paste0(kind, "-", key))
  if (dir.exists(path)) {
    record <- shared_read_record(path)
    if (!identical(record, list(owner = owner, kind = kind, key = key))) {
      shared_storage_error("Invalid retention reference; refusing to overwrite it.")
    }
    return(invisible(NULL))
  }
  stage <- tempfile(".stage-", tmpdir = parent)
  shared_mkdir(stage)
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  shared_write_record(list(owner = owner, kind = kind, key = key), stage)
  shared_publish(stage, path)
}

shared_refs_read <- function(cache) {
  owners <- list.dirs(shared_location(cache, "refs"), full.names = TRUE, recursive = FALSE)
  rows <- list()
  for (owner in owners) {
    paths <- list.dirs(owner, full.names = TRUE, recursive = FALSE)
    for (path in paths[!startsWith(basename(paths), ".stage-")]) {
      ref <- shared_read_record(path)
      if (is.null(ref) || !is.character(ref$owner) || length(ref$owner) != 1L ||
          is.na(ref$owner) || !isTRUE(ref$kind %in% c("actions", "native")) ||
          !shared_is_key(ref$key) ||
          !identical(basename(path), paste0(ref$kind, "-", ref$key))) {
        shared_storage_error("Invalid retention reference; collection is unsafe.")
      }
      rows[[length(rows) + 1L]] <- data.frame(owner = ref$owner, kind = ref$kind,
                                            key = ref$key, path = path)
    }
  }
  if (!length(rows)) return(data.frame(owner = character(), kind = character(),
                                       key = character(), path = character()))
  do.call(rbind, rows)
}

#' Retain and release shared results
#'
#' Every successful lookup pins its action for its owner before returning.
#' Pins are cumulative: removing a local store never releases its files implicitly.
#' Release an owner only after its pipeline, retained history and external readers
#' no longer need those paths. Collection is explicitly quiescent, not online GC.
#'
#' @param cache A [shared_cache()] configuration.
#' @param owner Retention owner string, e.g. [shared_owner()].
#' @param keys Action keys to retain or release. NULL releases all of the owner's
#'   references, including native CAS references.
#' @param quiescent Explicit assertion that all consumers have stopped and the
#'   references being released are no longer needed. Required for release.
#' @return `shared_references()` returns a data frame of owner, kind and key.
#'   Retain/release return the number of requested/removed references invisibly.
#' @export
shared_references <- function(cache) {
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  shared_refs_read(cache)[c("owner", "kind", "key")]
}

#' @rdname shared_references
#' @export
shared_retain <- function(cache, keys, owner = shared_owner()) {
  shared_owner_check(owner)
  if (!is.character(keys) || !all(vapply(keys, shared_is_key, logical(1)))) {
    stop("keys must be action keys emitted by shared_run().", call. = FALSE)
  }
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  for (key in unique(keys)) {
    lock <- shared_lock(cache, paste0("action-", key))
    tryCatch({
      action <- shared_read_record(shared_location(cache, "actions", key))
      if (is.null(action) || is.null(shared_restore(cache, key, action$format))) {
        stop("Cannot retain a missing or invalid action: ", key, call. = FALSE)
      }
      shared_pin(cache, owner, "actions", key)
    }, finally = filelock::unlock(lock))
  }
  invisible(length(unique(keys)))
}

#' @rdname shared_references
#' @export
shared_release <- function(cache, owner, keys = NULL, quiescent = FALSE) {
  shared_owner_check(owner)
  if (!isTRUE(quiescent)) stop("Release requires quiescent = TRUE.", call. = FALSE)
  if (!is.null(keys) && (!is.character(keys) || anyNA(keys))) {
    stop("keys must be NULL or a character vector.", call. = FALSE)
  }
  gate <- shared_gate(cache, exclusive = TRUE)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  refs <- shared_refs_read(cache)
  selected <- refs$owner == owner
  if (!is.null(keys)) selected <- selected & refs$kind == "actions" & refs$key %in% keys
  for (path in refs$path[selected]) {
    if (unlink(path, recursive = TRUE) != 0L) shared_storage_error("Could not release reference.")
  }
  invisible(sum(selected))
}

#' Preview or collect unreferenced cache data
#'
#' Collection uses retained owner references, not one store's current metadata.
#' Completed unpinned actions and unreachable content objects are removable.
#' Unpublished stages and private export copies have a configurable age grace.
#' An exclusive maintenance lock excludes in-flight shared operations. Consumers
#' holding returned paths are protected by persistent pins, not by writer locks.
#'
#' @param cache A [shared_cache()] configuration.
#' @param dry_run TRUE to return candidates without removing anything.
#' @param quiescent Explicit assertion that pipelines and external readers have
#'   stopped. Required for deletion; a lock cannot verify unmanaged readers.
#' @param stage_age Minimum age in seconds for abandoned stages and export copies.
#' @return A data frame containing candidate kind, key, path, bytes, reason and
#'   removed status. Attributes `selected_bytes` and `removed_bytes` give totals.
#' @details Pins survive local store deletion and keep history until explicitly
#'   released. Invalid pin/action metadata aborts collection before any deletion.
#'   Lock files and old layout directories are never removed. Interrupted
#'   collection may leave orphan objects, which the next invocation can collect.
#' @export
shared_gc <- function(cache, dry_run = TRUE, quiescent = FALSE, stage_age = 3600) {
  shared_flag(dry_run, "dry_run")
  shared_seconds(stage_age, "stage_age")
  if (!dry_run && !isTRUE(quiescent)) {
    stop("Collection requires quiescent = TRUE.", call. = FALSE)
  }
  gate <- shared_gate(cache, exclusive = TRUE)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  refs <- shared_refs_read(cache)
  keep_actions <- unique(refs$key[refs$kind == "actions"])
  keep_objects <- character()
  for (key in keep_actions) {
    action <- shared_read_record(shared_location(cache, "actions", key))
    if (is.null(action) || !identical(action$key, key) || !shared_is_key(action$object)) {
      shared_storage_error("A retained action is invalid; refusing collection.")
    }
    keep_objects <- union(keep_objects, action$object)
  }
  keep <- list(actions = keep_actions, objects = keep_objects,
               native = refs$key[refs$kind == "native"], exports = character())
  rows <- list()
  for (kind in names(keep)) {
    paths <- list.dirs(shared_location(cache, kind), full.names = TRUE, recursive = FALSE)
    for (path in paths) {
      key <- basename(path)
      abandoned <- startsWith(key, ".stage-") || startsWith(key, ".replaced-")
      age <- as.numeric(difftime(Sys.time(), file.info(path)$mtime, units = "secs"))
      candidate <- if (abandoned) !is.na(age) && age >= stage_age else
        shared_is_key(key) && !key %in% keep[[kind]]
      if (!candidate) next
      files <- list.files(path, recursive = TRUE, all.files = TRUE, full.names = TRUE)
      rows[[length(rows) + 1L]] <- data.frame(
        kind = kind, key = key, path = path,
        bytes = sum(file.info(files)$size, na.rm = TRUE),
        reason = if (abandoned) "abandoned-stage" else "unreferenced", removed = FALSE
      )
    }
  }
  # Interrupted pin publication is never a retained reference. No active operation
  # can still be using these directories while the exclusive gate is held.
  owners <- list.dirs(shared_location(cache, "refs"), full.names = TRUE, recursive = FALSE)
  for (owner in owners) {
    stages <- list.dirs(owner, full.names = TRUE, recursive = FALSE)
    for (path in stages[startsWith(basename(stages), ".stage-")]) {
      age <- as.numeric(difftime(Sys.time(), file.info(path)$mtime, units = "secs"))
      if (is.na(age) || age < stage_age) next
      files <- list.files(path, recursive = TRUE, all.files = TRUE, full.names = TRUE)
      rows[[length(rows) + 1L]] <- data.frame(
        kind = "refs", key = basename(path), path = path,
        bytes = sum(file.info(files)$size, na.rm = TRUE),
        reason = "abandoned-stage", removed = FALSE)
    }
  }
  result <- if (length(rows)) do.call(rbind, rows) else data.frame(
    kind = character(), key = character(), path = character(), bytes = numeric(),
    reason = character(), removed = logical()
  )
  # All reachability checks finish before any deletion; actions precede objects.
  if (!dry_run) for (i in seq_len(nrow(result))) {
    if (unlink(result$path[[i]], recursive = TRUE) != 0L) {
      shared_storage_error(paste("Could not collect:", result$path[[i]]))
    }
    result$removed[[i]] <- TRUE
  }
  attr(result, "selected_bytes") <- sum(result$bytes)
  attr(result, "removed_bytes") <- sum(result$bytes[result$removed])
  result
}

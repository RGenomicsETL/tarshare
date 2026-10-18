#' Use the shared backend through the public targets CAS interface
#'
#' Action records and content objects remain distinct. This adapter supplies
#' upload/download/exists/list callbacks to [targets::tar_repository_cas()].
#' Native targets keys have their own namespace because they are not action keys
#' or tarshare bundle hashes. Neither upload nor download moves a caller's files.
#'
#' @param cache A [shared_cache()] configuration.
#' @param consistent Whether the filesystem has strong read-after-write consistency.
#' @param key A native targets content key.
#' @param keys A character vector of native targets content keys.
#' @param path Source for upload or destination for download, a file or directory.
#' @return `shared_repository()` returns a repository string for targets. Upload
#'   and download act by side effect; exists returns a logical; list returns keys.
#' @details Native objects are retained for their pipeline store until the owner
#'   is explicitly released. Use [shared_gc()], not the single-store native GC,
#'   for this backend. Repository callbacks are public to survive targets' text
#'   serialization without a closure or a dependency on targets internals.
#' @export
shared_repository <- function(cache, consistent = FALSE) {
  shared_flag(consistent, "consistent")
  targets::tar_repository_cas(
    upload = function(key, path) tarshare::shared_cas_upload(key, path, cache),
    download = function(key, path) tarshare::shared_cas_download(key, path, cache),
    exists = function(key) tarshare::shared_cas_exists(key, cache),
    list = function(keys) tarshare::shared_cas_list(keys, cache),
    consistent = consistent, substitute = list(cache = cache)
  )
}

shared_native_key <- function(key) {
  if (!is.character(key) || length(key) != 1L || is.na(key) || !nzchar(key)) {
    stop("key must be a nonempty native content key.", call. = FALSE)
  }
  digest::digest(key, algo = "sha256", serialize = FALSE)
}

#' @rdname shared_repository
#' @export
shared_cas_upload <- function(key, path, cache) {
  id <- shared_native_key(key)
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  lock <- shared_lock(cache, paste0("native-", id))
  on.exit(filelock::unlock(lock), add = TRUE, after = FALSE)
  entry <- shared_location(cache, "native", id)
  existing <- shared_retry(cache, function() shared_object_read(entry, cache$verify))
  if (is.null(existing)) {
    stage <- shared_stage(cache, "native")
    on.exit(unlink(stage, recursive = TRUE), add = TRUE, after = FALSE)
    to <- file.path(stage, "files", "payload")
    shared_copy_path(path, to)
    record <- list(schema = 2L, format = "file", native_key = key,
                   bundle = shared_bundle(to, file.path(stage, "files")))
    shared_write_record(record, stage)
    shared_publish(stage, entry)
  }
  found <- shared_retry(cache, function() shared_object_read(entry, cache$verify))
  if (is.null(found)) shared_storage_error("Published native CAS object is not readable.")
  shared_pin(cache, shared_owner(store = targets::tar_path_store()), "native", id)
  invisible(NULL)
}

#' @rdname shared_repository
#' @export
shared_cas_download <- function(key, path, cache) {
  id <- shared_native_key(key)
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  entry <- shared_location(cache, "native", id)
  record <- shared_retry(cache, function() shared_object_read(entry, cache$verify))
  if (is.null(record)) shared_storage_error("Missing or invalid native CAS object.")
  if (file.exists(path)) stop("CAS download destination already exists.", call. = FALSE)
  shared_copy_path(file.path(entry, "files", "payload"), path)
  shared_pin(cache, shared_owner(store = targets::tar_path_store()), "native", id)
  invisible(NULL)
}

#' @rdname shared_repository
#' @export
shared_cas_exists <- function(key, cache) {
  id <- shared_native_key(key)
  gate <- shared_gate(cache)
  on.exit(shared_ungate(cache, gate), add = TRUE)
  found <- !is.null(shared_retry(cache, function() {
    shared_object_read(shared_location(cache, "native", id), cache$verify)
  }))
  # Compatible imported metadata can skip upload/download entirely. A successful
  # lookup still registers this consumer before the original owner may release.
  if (found) shared_pin(cache, shared_owner(store = targets::tar_path_store()), "native", id)
  found
}

#' @rdname shared_repository
#' @export
shared_cas_list <- function(keys, cache) {
  keys[vapply(keys, shared_cas_exists, logical(1), cache = cache)]
}

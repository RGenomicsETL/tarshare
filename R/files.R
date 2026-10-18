#' Give a file input an immutable content identity
#'
#' @param path Character vector of input file paths. Ordering and names matter.
#' @param id One immutable identifier per path, such as an already established
#'   SHA-256 or immutable object version. Supplying IDs avoids reading the files.
#'   If omitted, SHA-256 is computed from each regular file's contents.
#' @return A path-like character vector with class `tarshare_file`. It can be
#'   passed to ordinary file-reading functions. Its identity uses `id`, names,
#'   and ordering, rather than physical paths.
#' @details
#' Supplying `id` asserts that the identifier describes the bytes used by the
#' computation. The caller owns verification when localizing or registering
#' those files. The cache does not repeat that verification. Explicit IDs may
#' also describe immutable directories; automatic hashing accepts regular files.
#'
#' Relocation is safe only when the command depends on contents rather than
#' pathnames. Include any meaningful filename, sample label, or path-dependent
#' tool setting separately in the computation or its `context`.
#' @export
#' @examples
#' path <- tempfile()
#' writeLines("1,2,3", path)
#' input <- shared_file(path)
#' readLines(input)
shared_file <- function(path, id = NULL) {
  if (!is.character(path) || !length(path) || anyNA(path) || any(!nzchar(path))) {
    stop("path must contain nonempty input paths.", call. = FALSE)
  }
  original_names <- names(path)
  path <- as.character(path)
  if (is.null(id)) {
    if (any(!file.exists(path)) || any(dir.exists(path))) {
      stop("Automatic input hashing requires existing regular files.", call. = FALSE)
    }
    id <- vapply(path, shared_file_hash, character(1), USE.NAMES = FALSE)
  }
  if (!is.character(id) || length(id) != length(path) || anyNA(id) || any(!nzchar(id))) {
    stop("id must provide one nonempty immutable identifier per path.", call. = FALSE)
  }
  path <- normalizePath(path.expand(path), winslash = "/", mustWork = FALSE)
  names(path) <- original_names
  structure(path, class = c("tarshare_file", "character"), tarshare_id = unname(id))
}

#' Locate an output within the current shared computation
#'
#' @param path Relative file or directory name within this computation's bundle.
#'   The default returns the bundle directory. Parent directories are created.
#' @return An absolute path in a private staging directory. After success,
#'   [shared_run()] returns the corresponding permanent cache path.
#' @details
#' Call this only inside a `format = "file"` shared computation. Write all output
#' files and required sidecars under this directory, then return their paths.
#' Avoid embedding these temporary physical paths inside the output contents.
#' The cache preserves relative paths; it does not rewrite file contents.
#' @export
shared_path <- function(path = "") {
  current <- shared_runtime$current
  if (is.null(current) || !identical(current$format, "file")) {
    stop("shared_path() requires a running format = 'file' shared computation.",
         call. = FALSE)
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) ||
      grepl("(^[/\\\\])|(^[A-Za-z]:)|(^|[/\\\\])\\.\\.([/\\\\]|$)", path)) {
    stop("path must be relative to the computation's output directory.", call. = FALSE)
  }
  result <- if (nzchar(path)) file.path(current$path, path) else current$path
  shared_mkdir(dirname(result))
  result
}

shared_scan_bundle <- function(root) {
  directories <- root
  files <- character()
  all_directories <- root
  while (length(directories)) {
    current <- directories[[1L]]
    directories <- directories[-1L]
    paths <- list.files(current, all.files = TRUE, full.names = TRUE, no.. = TRUE)
    if (!length(paths)) next
    links <- Sys.readlink(paths)
    if (any(!is.na(links) & nzchar(links))) {
      stop("Cached file bundles cannot contain symbolic links.", call. = FALSE)
    }
    info <- file.info(paths)
    if (anyNA(info$isdir)) {
      stop("An output disappeared before its bundle was saved.", call. = FALSE)
    }
    dirs <- paths[info$isdir]
    directories <- c(directories, dirs)
    all_directories <- c(all_directories, dirs)
    files <- c(files, paths[!info$isdir])
  }
  list(files = sort(files), directories = sort(all_directories))
}

shared_relative <- function(paths, root) {
  if (!length(paths)) return(character())
  full <- normalizePath(paths, winslash = "/", mustWork = TRUE)
  root <- normalizePath(root, winslash = "/", mustWork = TRUE)
  inside <- full == root | startsWith(full, paste0(root, "/"))
  if (any(!inside)) {
    stop("File outputs must be created inside shared_path().", call. = FALSE)
  }
  ifelse(full == root, "", substring(full, nchar(root) + 2L))
}

shared_bundle <- function(value, root) {
  if (!is.character(value) || !length(value) || anyNA(value) ||
      any(!nzchar(value)) || any(!file.exists(value))) {
    stop("A file computation must return existing output paths.", call. = FALSE)
  }
  inventory <- shared_scan_bundle(root)
  paths <- shared_relative(value, root)
  names(paths) <- names(value)
  files <- shared_relative(inventory$files, root)
  list(
    paths = paths,
    files = files,
    directories = shared_relative(inventory$directories, root),
    sizes = unname(file.info(inventory$files)$size),
    hashes = vapply(inventory$files, shared_file_hash, character(1), USE.NAMES = FALSE)
  )
}

shared_bundle_paths <- function(entry, bundle) {
  paths <- file.path(entry, "files", bundle$paths)
  names(paths) <- names(bundle$paths)
  paths
}

shared_bundle_valid <- function(entry, bundle, verify) {
  root <- file.path(entry, "files")
  if (!dir.exists(root)) return(FALSE)
  inventory <- shared_scan_bundle(root)
  files <- file.path(root, bundle$files)
  if (!identical(shared_relative(inventory$files, root), bundle$files) ||
      !identical(shared_relative(inventory$directories, root), bundle$directories) ||
      !all(file.exists(shared_bundle_paths(entry, bundle))) ||
      !identical(unname(file.info(files)$size), bundle$sizes)) {
    return(FALSE)
  }
  !verify || identical(
    vapply(files, shared_file_hash, character(1), USE.NAMES = FALSE), bundle$hashes
  )
}

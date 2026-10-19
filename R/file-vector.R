#' Manipulate immutable file descriptors
#'
#' Subsetting and concatenation keep each path paired with its immutable input
#' identity. Names continue to describe semantic roles. Missing indices create
#' missing paths and identities, which cannot be used in a shared computation.
#'
#' Base replacement is deliberately unsupported: rebuild a descriptor with
#' [shared_file()] when its paths or identities change. Concatenation requires
#' descriptors for every nonempty input. Conversion with `as.character()`
#' deliberately returns ordinary paths without content identities.
#'
#' The first argument of `c()` must be a descriptor so base R dispatches this
#' method. Use [vctrs::vec_c()] when that cannot be guaranteed: it checks all
#' arguments and rejects mixed ordinary paths in either order.
#'
#' @param x A vector returned by [shared_file()].
#' @param i Indices used for subsetting.
#' @param ... Further arguments to the corresponding base operation.
#' @param drop,exact,recursive,use.names Standard base operation arguments.
#' @param value A replacement value, which is not accepted.
#' @name shared_file_vector
NULL

shared_file_ids <- function(x) {
  ids <- attr(x, "tarshare_id", exact = TRUE)
  if (!is.character(ids) || length(ids) != length(x)) {
    stop("Invalid tarshare_file content identity.", call. = FALSE)
  }
  ids
}

shared_file_new <- function(path, id) {
  structure(path, class = c("tarshare_file", "character"),
            tarshare_id = unname(id))
}

#' @rdname shared_file_vector
#' @export
`[.tarshare_file` <- function(x, i, ..., drop = TRUE) {
  ids <- shared_file_ids(x)
  names(ids) <- names(x)
  shared_file_new(NextMethod("["), ids[i, ..., drop = drop])
}

#' @rdname shared_file_vector
#' @export
`[[.tarshare_file` <- function(x, i, ..., exact = TRUE) {
  ids <- shared_file_ids(x)
  names(ids) <- names(x)
  shared_file_new(NextMethod("[["), ids[[i, ..., exact = exact]])
}

#' @rdname shared_file_vector
#' @export
c.tarshare_file <- function(..., recursive = FALSE, use.names = TRUE) {
  inputs <- list(...)
  paths <- lapply(inputs, function(x) {
    if (is.null(x) || (is.character(x) && !length(x))) return(character())
    if (!inherits(x, "tarshare_file")) {
      stop("Combine only shared_file() descriptors; identify every input path.",
           call. = FALSE)
    }
    shared_file_ids(x)
    result <- as.character(x)
    names(result) <- names(x)
    result
  })
  ids <- unlist(lapply(inputs, function(x) {
    if (inherits(x, "tarshare_file")) shared_file_ids(x) else character()
  }), use.names = FALSE)
  path <- do.call(c, c(paths, list(recursive = recursive, use.names = use.names)))
  if (is.null(path)) path <- character()
  if (is.null(ids)) ids <- character()
  shared_file_new(path, ids)
}

#' @rdname shared_file_vector
#' @export
`[<-.tarshare_file` <- function(x, i, ..., value) {
  stop("File identities are immutable; rebuild with shared_file() to replace paths.",
       call. = FALSE)
}

#' @rdname shared_file_vector
#' @export
`[[<-.tarshare_file` <- function(x, i, ..., value) {
  stop("File identities are immutable; rebuild with shared_file() to replace paths.",
       call. = FALSE)
}

#' @rdname shared_file_vector
#' @export
`length<-.tarshare_file` <- function(x, value) {
  stop("File identities are immutable; use subsetting or rebuild with shared_file().",
       call. = FALSE)
}

#' @export
#' @method vec_proxy tarshare_file
#' @importFrom vctrs vec_proxy
vec_proxy.tarshare_file <- function(x, ...) {
  data.frame(
    path = as.character(x), id = shared_file_ids(x),
    role = if (is.null(names(x))) rep("", length(x)) else names(x),
    named = rep(!is.null(names(x)), length(x)),
    stringsAsFactors = FALSE
  )
}

#' @export
#' @method vec_restore tarshare_file
#' @importFrom vctrs vec_restore
vec_restore.tarshare_file <- function(x, to, ...) {
  result <- shared_file_new(x$path, x$id)
  if (!is.null(names(to)) || any(x$named, na.rm = TRUE)) names(result) <- x$role
  result
}

#' @export
#' @method vec_ptype2 tarshare_file.tarshare_file
#' @importFrom vctrs vec_ptype2
vec_ptype2.tarshare_file.tarshare_file <- function(x, y, ...) {
  shared_file_new(character(), character())
}

#' @export
#' @method vec_cast tarshare_file.tarshare_file
#' @importFrom vctrs vec_cast
vec_cast.tarshare_file.tarshare_file <- function(x, to, ...) {
  shared_file_ids(x)
  x
}

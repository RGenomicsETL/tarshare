#' Snapshot declared external computation state
#'
#' Resolve this value while constructing the pipeline. The target factory embeds
#' the snapshot in its command, so changes affect local targets invalidation as
#' well as the shared key. This is a declaration, not discovery of hidden inputs.
#'
#' @param ... Named immutable values, such as image digests, database snapshots,
#'   model releases, or explicit method definitions.
#' @param files Named paths or [shared_file()] descriptors for model/executable
#'   contents. Ordinary files are hashed once per call. Descriptors reuse their IDs.
#' @param options Names of R options to snapshot.
#' @param env Names of nonsecret environment variables to snapshot.
#' @param packages Additional installed method/provider packages to fingerprint.
#' @param locale TRUE to include the current locale string.
#' @return A plain list of declared values and snapshots. It can be inspected and
#'   its values passed explicitly to functions instead of rereading ambient state.
#' @details Never include credentials: targets saves command context in metadata.
#'   A version label alone does not identify a replaced binary or model; use its
#'   content identity. Directory resources require an explicit immutable ID.
#' @export
shared_context <- function(..., files = list(), options = character(),
                           env = character(), packages = character(), locale = FALSE) {
  values <- list(...)
  if (length(values) && (is.null(names(values)) || any(!nzchar(names(values))) ||
                         anyDuplicated(names(values)))) {
    stop("Context values must have unique nonempty names.", call. = FALSE)
  }
  for (names in list(options, env, packages)) {
    if (!is.character(names) || anyNA(names) || any(!nzchar(names)) || anyDuplicated(names)) {
      stop("Snapshot selectors must be unique nonempty character names.", call. = FALSE)
    }
  }
  shared_flag(locale, "locale")
  if (inherits(files, "tarshare_file")) files <- list(files)
  if (is.character(files)) files <- as.list(files)
  if (!is.list(files)) stop("files must be paths or a list of descriptors.", call. = FALSE)
  file_ids <- lapply(files, function(file) {
    if (inherits(file, "tarshare_file")) file else shared_file(file)
  })
  result <- list(values = values, files = file_ids,
    options = stats::setNames(lapply(options, getOption), options),
    env = stats::setNames(as.list(Sys.getenv(env, unset = NA_character_)), env),
    packages = shared_package_records(packages, required = packages),
    locale = if (locale) Sys.getlocale() else NULL)
  # Use the actual identity walker, including method definitions and live-resource
  # rejection. No second environment scanner or validity authority is introduced.
  shared_identity(quote(NULL), baseenv(), context = result)
  result
}

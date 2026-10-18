#' Declare a target backed by a shared computation cache
#'
#' These factories create ordinary targets whose commands use [shared_run()].
#' `targets` still schedules the work, tracks dependencies, and owns each
#' pipeline's metadata. An existing shared result avoids evaluating the original
#' command after the target is dispatched.
#'
#' @param name Target name. Supply an unquoted symbol to `tar_shared()` and a
#'   character string to `tar_shared_raw()`.
#' @param command R command. It is captured without evaluation by `tar_shared()`.
#'   Supply an expression object, usually made with `quote()`, to
#'   `tar_shared_raw()`.
#' @param cache A [shared_cache()] object, evaluated when the target is declared.
#' @param pattern Dynamic branching pattern, captured by `tar_shared()`. Supply
#'   an expression object or `NULL` to `tar_shared_raw()`.
#' @param format Either `"rds"` for an R value or `"file"` for files created with
#'   [shared_path()]. Cached files remain owned by the shared cache; downstream
#'   commands must treat them as immutable.
#' @param context External context, evaluated once when the target is declared.
#'   Use [shared_context()] to snapshot options, resources and provider identities.
#'   Its canonical identity is embedded in the target command and the shared key.
#'   For the raw factory, supply a value, not a quoted expression.
#' @param branch_context Target-derived context, captured as an expression.
#'   Use this for upstream targets and dynamic branch values, not ambient state.
#' @param seed Seed input for [shared_run()]. This also remains a runtime
#'   expression in `tar_shared()`; supply an expression object or literal value
#'   to `tar_shared_raw()`. The effective RNG stream is derived from the shared
#'   computation key, independently of the target name. Give independent
#'   stochastic replicates distinct seeds or replicate identities in `context`.
#' @param packages Character vector of packages to load for this target and
#'   include in its execution identity. Evaluated when the target is declared.
#' @param ... Other arguments to [targets::tar_target_raw()], such as
#'   `iteration`, `cue`, `memory`, `deployment`, or a public CAS `repository`.
#'   Nonlocal file outputs are copied before repository upload; return the whole
#'   bundle directory or every sidecar. Overrides of `deps` and `string` are unsupported:
#'   ordinary dependency detection and command invalidation remain enabled.
#'
#' @return A target definition object to include in a targets pipeline.
#'
#' @details
#' The command, branch context, and seed are embedded as unquoted expressions
#' in the generated command. This preserves the ordinary static dependency
#' analysis of `targets`, including dynamic branch inputs. No target metadata
#' is read or modified by these factories.
#'
#' Only the declared computation is shared. Operations which observe the target
#' name, pipeline directory, time, or other external state need appropriate
#' explicit context; they are not made independent of that state by this
#' factory. See [shared_run()] for the cache identity contract.
#'
#' @examples
#' cache <- shared_cache(tempfile("shared-cache-"))
#' tar_shared(result, sum(data), cache)
#' tar_shared(
#'   simulations, stats::rnorm(2), cache,
#'   pattern = map(replicate_id), branch_context = list(replicate = replicate_id)
#' )
#' tar_shared_raw("result", quote(sum(data)), cache)
#' @export
tar_shared <- function(
  name,
  command,
  cache,
  pattern = NULL,
  format = c("rds", "file"),
  context = list(),
  branch_context = list(),
  seed = 0L,
  packages = targets::tar_option_get("packages"),
  ...
) {
  name_expr <- substitute(name)
  if (!is.symbol(name_expr)) {
    stop("Use an unquoted target name, or use tar_shared_raw().", call. = FALSE)
  }
  tar_shared_raw(
    name = as.character(name_expr),
    command = substitute(command),
    cache = cache,
    pattern = substitute(pattern),
    format = format,
    context = context,
    branch_context = substitute(branch_context),
    seed = substitute(seed),
    packages = packages,
    ...
  )
}

#' @rdname tar_shared
#' @export
tar_shared_raw <- function(
  name,
  command,
  cache,
  pattern = NULL,
  format = c("rds", "file"),
  context = list(),
  branch_context = quote(list()),
  seed = 0L,
  packages = targets::tar_option_get("packages"),
  ...
) {
  format <- match.arg(format)
  dots <- list(...)
  unsupported <- intersect(names(dots), c("deps", "string"))
  if (length(unsupported)) {
    stop(
      "tar_shared() does not support overriding ",
      paste(unsupported, collapse = ", "), ".",
      call. = FALSE
    )
  }
  repository <- if ("repository" %in% names(dots)) {
    dots$repository
  } else {
    targets::tar_option_get("repository")
  }
  dots$repository <- repository
  # Context is intentionally eager. Dynamic target/branch values belong in
  # branch_context, which remains visible to ordinary targets dependency analysis.
  if (is.language(context) || is.expression(context)) {
    stop("context must be resolved at graph construction; use branch_context for target expressions.",
         call. = FALSE)
  }
  execution <- shared_identity(quote(NULL), baseenv(), context = context,
                               packages = packages)$key
  command <- shared_target_expression(command, "command")
  pattern <- shared_target_expression(pattern, "pattern")
  branch_context <- shared_target_expression(branch_context, "branch_context")
  seed <- shared_target_expression(seed, "seed")
  command <- substitute(
    tarshare::shared_run(
      command = COMMAND,
      cache = CACHE,
      format = FORMAT,
      context = list(static = CONTEXT, branch = BRANCH_CONTEXT),
      seed = SEED,
      packages = PACKAGES,
      owner = tarshare::shared_owner(store = targets::tar_path_store()),
      localize = LOCALIZE
    ),
    list(
      COMMAND = command, CACHE = cache, FORMAT = format,
      CONTEXT = execution, BRANCH_CONTEXT = branch_context,
      SEED = seed, PACKAGES = packages, LOCALIZE = !identical(repository, "local")
    )
  )
  do.call(
    targets::tar_target_raw,
    c(
      list(
        name = name, command = command, pattern = pattern,
        format = format, packages = packages
      ),
      dots
    ),
    quote = TRUE
  )
}

shared_target_expression <- function(x, argument) {
  if (is.expression(x)) {
    if (length(x) != 1L) {
      stop(argument, " must contain one R expression.", call. = FALSE)
    }
    x <- x[[1L]]
  }
  x
}

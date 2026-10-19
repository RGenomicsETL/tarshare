# A fingerprint describes only the command's statically referenced bindings.
# Dynamic lookups, process state and external tools belong in explicit context.
shared_identity <- function(command, envir, context = list(), seed = 0L,
                            packages = character()) {
  if (!is.environment(envir)) stop("`envir` must be an environment.", call. = FALSE)
  if (!is.numeric(seed) || length(seed) != 1L || is.na(seed) ||
      !is.finite(seed) || seed < 0 || seed > .Machine$integer.max ||
      seed != trunc(seed)) {
    stop("`seed` must be a single nonnegative R integer.", call. = FALSE)
  }
  if (!is.character(packages) || anyNA(packages) || any(!nzchar(packages))) {
    stop("`packages` must contain package names.", call. = FALSE)
  }
  seed <- as.integer(seed)
  used_packages <- unique(c("base", packages))
  qualified <- list()
  stack <- list()

  # Namespace references are not ordinary globals according to codetools.
  # Record direct references explicitly, but do not walk namespace internals.
  scan_qualified <- function(x) {
    if (missing(x)) return(invisible(NULL))
    if (is.call(x) && length(x) == 3L && is.symbol(x[[1L]]) &&
        as.character(x[[1L]]) %in% c("::", ":::")) {
      pkg <- x[[2L]]
      member <- x[[3L]]
      if ((is.symbol(pkg) || is.character(pkg)) && length(pkg) == 1L &&
          (is.symbol(member) || is.character(member)) && length(member) == 1L) {
        pkg <- as.character(pkg)
        member <- as.character(member)
        token <- paste(pkg, as.character(x[[1L]]), member, sep = "")
        used_packages <<- unique(c(used_packages, pkg))
        qualified[[token]] <<- list(package = pkg, member = member,
                                    exported = identical(x[[1L]], quote(`::`)))
      }
    }
    if (is.call(x) || is.pairlist(x) || is.expression(x) || is.list(x)) {
      invisible(lapply(as.list.default(x), scan_qualified))
    }
    invisible(NULL)
  }

  read_binding <- function(name, env, function_position = FALSE) {
    while (!identical(env, emptyenv())) {
      if (exists(name, envir = env, inherits = FALSE)) {
        if (bindingIsActive(name, env)) {
          stop("Cannot fingerprint active binding `", name, "`.", call. = FALSE)
        }
        value <- get(name, envir = env, inherits = FALSE)
        if (!function_position || is.function(value)) return(value)
      }
      env <- parent.env(env)
    }
    stop("Cannot resolve command dependency `", name, "`.", call. = FALSE)
  }

  bindings <- function(fun) {
    globals <- codetools::findGlobals(fun, merge = FALSE)
    collect <- function(names, function_position) {
      names <- sort(unique(as.character(names)), method = "radix")
      structure(lapply(names, function(name) {
        snapshot(read_binding(name, environment(fun), function_position))
      }), names = names)
    }
    list(variables = collect(globals$variables, FALSE),
         functions = collect(globals$functions, TRUE))
  }

  attributes_snapshot <- function(x, ast = FALSE) {
    attrs <- attributes(x)
    if (ast) attrs[c("srcref", "wholeSrcref", "srcfile", "source")] <- NULL
    if (!length(attrs)) return(NULL)
    lapply(attrs, snapshot)
  }

  function_snapshot <- function(fun) {
    if (is.primitive(fun)) {
      return(list(type = typeof(fun), code = deparse(fun),
                  attributes = attributes_snapshot(fun, ast = TRUE)))
    }
    ancestor <- which(vapply(stack, identical, logical(1L), y = fun))
    if (length(ancestor)) return(list(type = "function_reference", depth = ancestor[[1L]]))
    stack[[length(stack) + 1L]] <<- fun
    on.exit(stack[[length(stack)]] <<- NULL, add = TRUE)
    env <- environment(fun)
    pkg <- if (isNamespace(env)) getNamespaceName(env) else if (
      identical(env, baseenv())) "base" else NULL
    if (!is.null(pkg)) used_packages <<- unique(c(used_packages, pkg))
    if (is.null(pkg)) {
      scan_qualified(formals(fun))
      scan_qualified(body(fun))
    }
    list(type = "closure", package = pkg,
         formals = snapshot(formals(fun), ast = TRUE),
         body = snapshot(body(fun), ast = TRUE),
         attributes = attributes_snapshot(fun, ast = TRUE),
         bindings = if (is.null(pkg)) bindings(fun) else NULL)
  }

  snapshot <- function(x, ast = FALSE) {
    if (missing(x)) return(list(type = "missing_argument"))
    type <- typeof(x)
    if (is.environment(x) || type %in% c("externalptr", "weakref") ||
        inherits(x, "connection")) {
      stop("Cannot fingerprint live environments, external pointers or connections; ",
           "supply an immutable value or explicit context instead.", call. = FALSE)
    }
    if (is.function(x)) return(function_snapshot(x))
    if (inherits(x, "tarshare_file")) {
      ids <- attr(x, "tarshare_id", exact = TRUE)
      if (!is.character(x) || !is.character(ids) || length(ids) != length(x) ||
          anyNA(ids) || any(!nzchar(ids))) {
        stop("Invalid tarshare_file content identity.", call. = FALSE)
      }
      attrs <- attributes(x)
      attrs$tarshare_id <- NULL
      return(list(type = "tarshare_file", ids = snapshot(ids),
                  attributes = snapshot(attrs)))
    }
    if (is.null(x)) return(list(type = "NULL"))
    if (is.symbol(x)) return(list(type = "symbol", name = as.character(x)))
    if (is.call(x) || is.pairlist(x) || is.expression(x) || is.list(x)) {
      return(list(type = type, s4 = isS4(x),
                  values = lapply(as.list.default(x), snapshot, ast = ast),
                  attributes = attributes_snapshot(x, ast = ast)))
    }
    if (is.atomic(x)) {
      # Materialize ALTREP vectors so equal values have the same representation.
      data <- vector(type, length(x))
      data[] <- x
      return(list(type = type, s4 = isS4(x), values = data,
                  attributes = attributes_snapshot(x, ast = ast)))
    }
    if (isS4(x)) {
      return(list(type = type, s4 = TRUE,
                  attributes = attributes_snapshot(x, ast = ast)))
    }
    stop("Unsupported value type in computation identity: ", type, call. = FALSE)
  }

  thunk <- function() NULL
  body(thunk) <- command
  environment(thunk) <- envir
  scan_qualified(command)
  command_snapshot <- snapshot(command, ast = TRUE)
  binding_snapshot <- bindings(thunk)
  context_snapshot <- snapshot(context)
  qualified_snapshot <- list()
  for (token in sort(as.character(names(qualified)), method = "radix")) {
    ref <- qualified[[token]]
    available <- length(find.package(ref$package, quiet = TRUE)) > 0L
    resolved <- if (available) tryCatch({
      value <- if (ref$exported) getExportedValue(ref$package, ref$member) else
        get(ref$member, envir = asNamespace(ref$package), inherits = FALSE)
      list(available = TRUE, value = value)
    }, error = function(e) list(available = FALSE)) else list(available = FALSE)
    qualified_snapshot[[token]] <- if (resolved$available) {
      list(available = TRUE, value = snapshot(resolved$value))
    } else list(available = FALSE)
  }
  implementation_version <- if ("tarshare" %in% loadedNamespaces()) {
    as.character(getNamespaceVersion("tarshare"))
  } else tryCatch(as.character(utils::packageVersion("tarshare")),
                  error = function(e) "development")
  payload <- list(
    schema = 1L, implementation = list(package = "tarshare", version = implementation_version),
    R = list(version = as.character(getRversion()), platform = R.version$platform),
    command = command_snapshot, bindings = binding_snapshot,
    qualified = qualified_snapshot, context = context_snapshot,
    packages = shared_package_records(used_packages, required = packages),
    rng = list(kind = "L'Ecuyer-CMRG", normal = "Inversion", sample = "Rejection", seed = seed)
  )
  key <- digest::digest(payload, algo = "sha256", serializeVersion = 3L)
  unsigned <- strtoi(substr(key, 1L, 7L), base = 16L) * 16 +
    strtoi(substr(key, 8L, 8L), base = 16L)
  list(key = key, seed = as.integer(unsigned %% .Machine$integer.max + 1))
}

# Include hard dependencies recursively; optional/dynamically selected packages
# can be named in `packages`. Library locations are deliberately not identities.
shared_package_records <- function(packages, required = character()) {
  records <- list()
  pending <- unique(packages)
  while (length(pending)) {
    pkg <- sort(pending, method = "radix")[[1L]]
    pending <- setdiff(pending, pkg)
    if (pkg %in% names(records) || identical(pkg, "R")) next
    path <- find.package(pkg, quiet = TRUE)
    if (!length(path)) {
      if (pkg %in% required) stop("Required package is not installed: ", pkg, call. = FALSE)
      records[[pkg]] <- list(available = FALSE)
      next
    }
    desc <- as.list(read.dcf(file.path(path, "DESCRIPTION"))[1L, ])
    records[[pkg]] <- shared_package_record(desc)
    dependency_fields <- intersect(c("Depends", "Imports", "LinkingTo"), names(desc))
    dependencies <- unlist(strsplit(paste(unlist(desc[dependency_fields]), collapse = ","),
                                    ",", fixed = TRUE), use.names = FALSE)
    dependencies <- trimws(gsub("\\s*\\([^)]*\\)", "", dependencies))
    pending <- union(pending, setdiff(dependencies[nzchar(dependencies)], names(records)))
  }
  records[sort(as.character(names(records)), method = "radix")]
}

shared_package_record <- function(description) {
  fields <- c("Package", "Version", "Built", "RemoteSha", "GithubSHA1")
  record <- description[intersect(fields, names(description))]
  if (!is.null(record$Built)) {
    built <- trimws(strsplit(record$Built, ";", fixed = TRUE)[[1L]])
    # Installation dates do not describe code or ABI compatibility.
    record$Built <- structure(as.list(built[c(1L, 2L, 4L)]),
                              names = c("R", "platform", "OS"))
  }
  record
}

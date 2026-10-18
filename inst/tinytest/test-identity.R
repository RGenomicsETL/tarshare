library(tarshare)

shared_identity <- tarshare:::shared_identity
shared_package_records <- tarshare:::shared_package_records
shared_package_record <- tarshare:::shared_package_record

identity_for <- function(command, values = list(), context = list(), seed = 0L,
                         packages = character()) {
  shared_identity(command, list2env(values, parent = baseenv()),
                  context = context, seed = seed, packages = packages)
}

# identities depend on referenced values, not evaluation environments
(function() {
  a <- identity_for(quote(x + 1L), list(x = 2L, unused = "first"))
  b <- identity_for(quote(x + 1L), list(x = 2L, unused = new.env()))
  expect_identical(a, b)
  expect_match(a$key, "^[0-9a-f]{64}$")
  expect_identical(typeof(a$seed), "integer")
  expect_true(a$seed > 0L)
  expect_true(a$seed <= .Machine$integer.max)
  expect_false(identical(a$key, identity_for(quote(x + 1L), list(x = 3L))$key))
  expect_false(identical(a$key, identity_for(quote(x + 2L), list(x = 2L))$key))
})()

# user helper bodies, defaults and captured globals participate
(function() {
  make_helper <- function(k, default = 1L) {
    env <- list2env(list(k = k), parent = baseenv())
    f <- eval(quote(function(x = 1L) x + k), env)
    formals(f)$x <- default
    f
  }
  first <- identity_for(quote(helper()), list(helper = make_helper(2L)))$key
  expect_identical(first,
                   identity_for(quote(helper()), list(helper = make_helper(2L)))$key)
  expect_false(identical(first,
    identity_for(quote(helper()), list(helper = make_helper(3L)))$key))
  expect_false(identical(first,
    identity_for(quote(helper()), list(helper = make_helper(2L, 4L)))$key))
  changed_body <- make_helper(2L)
  body(changed_body) <- quote(x * k)
  expect_false(identical(first,
    identity_for(quote(helper()), list(helper = changed_body))$key))
})()

# nested helpers and captured default expressions are tracked
(function() {
  helper <- function(k) {
    env <- list2env(list(k = k), parent = baseenv())
    env$inner <- eval(quote(function(x = k) x * 2L), env)
    eval(quote(function() inner()), env)
  }
  a <- identity_for(quote(f()), list(f = helper(2L)))
  b <- identity_for(quote(f()), list(f = helper(3L)))
  expect_false(identical(a$key, b$key))
})()

# function-position lookup skips nonfunction shadow bindings
(function() {
  outer <- new.env(parent = baseenv())
  outer$f <- eval(quote(function(x) x + 1L), outer)
  inner <- list2env(list(f = 99, x = 1L), parent = outer)
  before <- shared_identity(quote(f(x)), inner)
  expect_identical(eval(quote(f(x)), inner), 2L)
  inner$f <- 100
  expect_identical(before, shared_identity(quote(f(x)), inner))
  outer$f <- eval(quote(function(x) x + 2L), outer)
  expect_false(identical(before$key, shared_identity(quote(f(x)), inner)$key))
  before <- shared_identity(quote(list(f, f(x))), inner)
  inner$f <- 101
  expect_false(identical(before$key, shared_identity(quote(list(f, f(x))), inner)$key))
})()

# explicit context tracks methods selected by dynamic dispatch
(function() {
  env <- new.env(parent = baseenv())
  env$g <- eval(quote(function(x) UseMethod("g")), env)
  env$g.item <- eval(quote(function(x) unclass(x) + 1L), env)
  env$x <- structure(1L, class = "item")
  a <- shared_identity(quote(g(x)), env, context = list(method = env$g.item))
  env$g.item <- eval(quote(function(x) unclass(x) + 2L), env)
  b <- shared_identity(quote(g(x)), env, context = list(method = env$g.item))
  expect_false(identical(a$key, b$key))
})()

# recursive and mutually recursive closures have finite identities
(function() {
  recursive <- function(offset) {
    env <- list2env(list(offset = offset), parent = baseenv())
    env$f <- eval(quote(function(x) if (x > 0L) g(x - 1L) else offset), env)
    env$g <- eval(quote(function(x) if (x > 0L) f(x - 1L) else offset), env)
    env$f
  }
  a <- identity_for(quote(f(3L)), list(f = recursive(1L)))
  expect_identical(a, identity_for(quote(f(3L)), list(f = recursive(1L))))
  expect_false(identical(a$key,
    identity_for(quote(f(3L)), list(f = recursive(2L)))$key))
  env <- new.env(parent = baseenv())
  env$f <- eval(quote(function(n) if (n > 0L) f(n - 1L) else 0L), env)
  expect_match(shared_identity(quote(f(3L)), env)$key, "^[0-9a-f]{64}$")
})()

# source references and source locations are excluded
(function() {
  helper <- function(text) eval(parse(text = text, keep.source = TRUE),
                                new.env(parent = baseenv()))
  f <- helper("function(x) { x + 1L }")
  g <- helper("# a different source location\n\nfunction(x) {\n x + 1L\n}")
  expect_identical(identity_for(quote(f(2L)), list(f = f)),
                   identity_for(quote(f(2L)), list(f = g)))
  first <- parse(text = "x + 1L", keep.source = TRUE)[[1L]]
  second <- parse(text = "\n# same expression\nx + 1L", keep.source = TRUE)[[1L]]
  expect_identical(identity_for(first, list(x = 2L)),
                   identity_for(second, list(x = 2L)))
})()

# ordinary types, attributes and names remain semantic
(function() {
  key <- function(x) identity_for(quote(x), list(x = x))$key
  expect_false(identical(key(1L), key(1)))
  expect_false(identical(key(c(a = 1L)), key(c(b = 1L))))
  expect_false(identical(key(1L), key(structure(1L, class = "tagged_number"))))
  expect_false(identical(key(factor("a", levels = c("a", "b"))),
                         key(factor("a", levels = c("a", "c")))))
  expect_false(identical(key(matrix(1:4, 2L)), key(1:4)))
  expect_identical(key(1:3), key(c(1L, 2L, 3L)))
  expect_false(identical(key(list(a = 1L, b = 2L)), key(list(b = 2L, a = 1L))))
})()

# file references use content IDs, names and order instead of locations
(function() {
  refs <- function(paths, ids, names = c("one", "two")) {
    structure(paths, class = "tarshare_file", tarshare_id = ids, names = names)
  }
  ids <- c("content-one", "content-two")
  a <- refs(c("/project-a/x.txt", "/project-a/y.txt"), ids)
  b <- refs(c("/project-b/new-x.txt", "/project-b/new-y.txt"), ids)
  key <- function(x) identity_for(quote(x), list(x = x))$key
  expect_identical(key(a), key(b))
  expect_false(identical(key(a), key(refs(unclass(b), rev(ids)))))
  expect_false(identical(key(a), key(refs(unclass(b), ids, c("alpha", "two")))))
  expect_false(identical(key(a), key(as.character(a))))
  expect_error(key(structure("x", class = "tarshare_file")), "Invalid tarshare_file")
})()

# namespace functions and recursive installed dependencies are fingerprinted
(function() {
  records <- shared_package_records("vctrs")
  expect_true(all(c("vctrs", "rlang", "lifecycle", "cli", "glue") %in% names(records)))
  expect_identical(records$vctrs$Version, as.character(packageVersion("vctrs")))
  expect_true("Built" %in% names(records$vctrs))
  original <- shared_package_records
  altered_identity <- shared_identity
  hook <- new.env(parent = environment(shared_identity))
  hook$shared_package_records <- function(packages, required) {
    expect_true("stats" %in% packages)
    records <- original(packages, required)
    records$stats$RemoteSha <- "another-installation-revision"
    records
  }
  environment(altered_identity) <- hook
  env <- list2env(list(x = 1:3), parent = baseenv())
  a <- shared_identity(quote(stats::median(x)), env)
  b <- altered_identity(quote(stats::median(x)), env)
  expect_false(identical(a$key, b$key))
  a <- identity_for(quote(f(x)), list(f = stats::median, x = 1:3))
  f <- stats::median
  body(f) <- quote(x[[1L]])
  b <- identity_for(quote(f(x)), list(f = f, x = 1:3))
  expect_false(identical(a$key, b$key))
  expect_false(identical(identity_for(quote(1L))$key,
                         identity_for(quote(1L), packages = "stats")$key))
  expect_error(identity_for(quote(1L), packages = "tarshare_uninstalled_test_package"),
               "Required package is not installed")
})()

# context and user seed control identity and computation seed
(function() {
  a <- identity_for(quote(stats::runif(3L)), context = list(tool = "1"), seed = 42L)
  expect_identical(a,
    identity_for(quote(stats::runif(3L)), context = list(tool = "1"), seed = 42))
  b <- identity_for(quote(stats::runif(3L)), context = list(tool = "2"), seed = 42L)
  c <- identity_for(quote(stats::runif(3L)), context = list(tool = "1"), seed = 43L)
  expect_false(identical(a$key, b$key))
  expect_false(identical(a$key, c$key))
  expect_false(identical(a$seed, c$seed))
  expect_error(identity_for(quote(1L), seed = -1L), "nonnegative R integer")
  expect_error(identity_for(quote(1L), seed = 0.5), "nonnegative R integer")
})()

# package installation dates are excluded while ABI metadata remains
(function() {
  description <- list(Package = "stats", Version = "1.0", RemoteSha = "commit-one",
    Built = "R 4.5.3; x86_64-pc-linux-gnu; 2026-01-01 12:00:00 UTC; unix")
  original <- shared_package_records
  key <- function(description) {
    identity <- shared_identity
    hook <- new.env(parent = environment(identity))
    hook$shared_package_records <- function(packages, required) {
      records <- original(packages, required)
      records$stats <- shared_package_record(description)
      records
    }
    environment(identity) <- hook
    identity(quote(stats::median(1:3)), new.env(parent = baseenv()))$key
  }
  first <- key(description)
  description$Built <- "R 4.5.3; x86_64-pc-linux-gnu; 2026-10-01 16:00:00 UTC; unix"
  expect_identical(first, key(description))
  description$Built <- "R 4.5.3; aarch64-apple-darwin; 2026-10-01 16:00:00 UTC; unix"
  expect_false(identical(first, key(description)))
})()

# live values and active dependencies are rejected
(function() {
  expect_error(identity_for(quote(x), list(x = new.env())), "live environments")
  expect_error(identity_for(quote(x), list(x = list(inner = new.env()))), "live environments")
  expect_error(identity_for(quote(x), list(x = structure(1L, state = new.env()))),
               "live environments")
  expect_error(identity_for(quote(1L), context = list(state = new.env())),
               "live environments")
  expect_error(identity_for(quote(x), list(x = new("externalptr"))), "external pointers")
  connection <- file(tempfile(), "w")
  expect_error(identity_for(quote(x), list(x = connection)), "connections")
  close(connection)
  env <- new.env(parent = baseenv())
  makeActiveBinding("x", function() 1L, env)
  expect_error(shared_identity(quote(x), env), "active binding")
  expect_error(shared_identity(quote(missing_value), env), "Cannot resolve command dependency")
})()

# These tests expose the declared-context boundary rather than pretending that
# static analysis can prove that an arbitrary expression has no hidden inputs.
test_that("an option change is not discovered without its value in context", {
  root <- tempfile("tarshare-context-")
  cache <- shared_cache(root)
  on.exit(unlink(root, recursive = TRUE))
  withr::local_options(list(tarshare.test.scale = 2L))
  run <- function() suppressMessages(shared_run(getOption("tarshare.test.scale"), cache))
  expect_identical(run(), 2L)
  options(tarshare.test.scale = 3L)
  expect_identical(run(), 2L)
})

test_that("declaring an option value invalidates shared reuse", {
  root <- tempfile("tarshare-context-")
  cache <- shared_cache(root)
  on.exit(unlink(root, recursive = TRUE))
  withr::local_options(list(tarshare.test.scale = 2L))
  run <- function() suppressMessages(shared_run(
    getOption("tarshare.test.scale"), cache,
    context = list(scale = getOption("tarshare.test.scale"))
  ))
  expect_identical(run(), 2L)
  options(tarshare.test.scale = 3L)
  expect_identical(run(), 3L)
  options(tarshare.test.scale = 2L)
  expect_identical(run(), 2L)
})

test_that("identical bytes do not imply identical computation keys", {
  env <- new.env(parent = baseenv())
  first <- shared_identity(quote(1L + 1L), env)
  second <- shared_identity(quote(2L), env)
  expect_identical(eval(quote(1L + 1L), env), eval(quote(2L), env))
  expect_false(identical(first$key, second$key))
})

test_that("a context value resolved at graph construction invalidates local skipping", {
  root <- tempfile("tarshare-context-project-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  script <- file.path(root, "_targets.R")
  cache_path <- file.path(root, "cache")
  store <- file.path(root, "store")
  writeLines(c(
    paste0("cache <- tarshare::shared_cache(", deparse(cache_path), ")"),
    "execution <- list(scale = getOption('tarshare.test.scale'))",
    "list(tarshare::tar_shared(result, execution$scale, cache,",
    "  context = execution, packages = character()))"
  ), script)
  withr::local_options(list(tarshare.test.scale = 2L))
  run <- function() targets::tar_make(
    script = script, store = store, callr_function = NULL,
    reporter = "silent", envir = new.env(parent = baseenv())
  )
  run()
  expect_identical(targets::tar_read_raw("result", store = store), 2L)
  options(tarshare.test.scale = 3L)
  run()
  expect_identical(targets::tar_read_raw("result", store = store), 3L)
})

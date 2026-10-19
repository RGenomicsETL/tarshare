library(tarshare)

# The original undeclared-state counterexample remains covered.
(function() {
  root <- tempfile("tarshare-context-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  old <- options(tarshare.test.scale = 2L)
  on.exit(options(old), add = TRUE)
  run <- function() suppressMessages(shared_run(getOption("tarshare.test.scale"), cache))
  expect_identical(run(), 2L)
  options(tarshare.test.scale = 3L)
  expect_identical(run(), 2L)
  safe <- function() suppressMessages(shared_run(getOption("tarshare.test.scale"), cache,
    context = shared_context(options = "tarshare.test.scale")))
  expect_identical(safe(), 3L)
  options(tarshare.test.scale = 2L)
  expect_identical(safe(), 2L)
})()

# Equal output bytes are not an excuse to weaken action identity.
(function() {
  first <- tarshare:::shared_identity(quote(1L + 1L), baseenv())
  second <- tarshare:::shared_identity(quote(2L), baseenv())
  expect_false(identical(first$key, second$key))
  root <- tempfile("tarshare-dedup-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  expect_identical(suppressMessages(shared_run(1L + 1L, cache)), 2L)
  expect_identical(suppressMessages(shared_run(2L, cache)), 2L)
  expect_length(list.dirs(file.path(root, "actions"), recursive = FALSE), 2L)
  expect_length(list.dirs(file.path(root, "objects"), recursive = FALSE), 1L)
})()

# Context is now eager even when the command reads ambient state directly.
(function() {
  root <- tempfile("tarshare-eager-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  script <- file.path(root, "_targets.R")
  pipeline <- bquote({
    cache <- tarshare::shared_cache(.(file.path(root, "cache")))
    list(tarshare::tar_shared(
      result, getOption("tarshare.test.scale"), cache,
      context = list(scale = getOption("tarshare.test.scale")),
      packages = character()
    ))
  })
  dput(pipeline, file = script)
  old <- options(tarshare.test.scale = 2L)
  on.exit(options(old), add = TRUE)
  run <- function(store) targets::tar_make(script = script, store = store,
    callr_function = NULL, reporter = "silent", envir = new.env(parent = baseenv()))
  a <- file.path(root, "a")
  b <- file.path(root, "b")
  run(a)
  expect_identical(targets::tar_read_raw("result", store = a), 2L)
  options(tarshare.test.scale = 3L)
  run(a)
  expect_identical(targets::tar_read_raw("result", store = a), 3L)
  run(b)
  expect_identical(targets::tar_read_raw("result", store = b), 3L)
  options(tarshare.test.scale = 2L)
  run(a)
  expect_identical(targets::tar_read_raw("result", store = a), 2L)
})()

# Replacing resource bytes without changing the path/version invalidates both stores.
(function() {
  root <- tempfile("tarshare-resource-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  resource <- file.path(root, "model-or-executable")
  script <- file.path(root, "_targets.R")
  pipeline <- bquote({
    resource <- .(resource)
    cache <- tarshare::shared_cache(.(file.path(root, "cache")))
    list(tarshare::tar_shared(
      result, readLines(resource), cache,
      context = tarshare::shared_context(
        version = "unchanged", files = list(tool = resource)
      ),
      packages = character()
    ))
  })
  dput(pipeline, file = script)
  run <- function(store) targets::tar_make(script = script, store = store,
    callr_function = NULL, reporter = "silent", envir = new.env(parent = baseenv()))
  a <- file.path(root, "a")
  b <- file.path(root, "b")
  writeLines("version one", resource)
  run(a)
  expect_identical(targets::tar_read_raw("result", store = a), "version one")
  writeLines("version two", resource)
  run(a)
  run(b)
  expect_identical(targets::tar_read_raw("result", store = a), "version two")
  expect_identical(targets::tar_read_raw("result", store = b), "version two")
  expect_error(shared_context(state = new.env()), "live environments")
  cache <- shared_cache(file.path(root, "cache"))
  expect_error(tar_shared_raw("x", quote(1L), cache,
    context = quote(list(x = upstream))), "branch_context")
})()

# Explicit method snapshots participate; IDs avoid reading already identified files.
(function() {
  one <- function(x) unclass(x) + 1L
  two <- function(x) unclass(x) + 2L
  a <- shared_context(method = one)
  b <- shared_context(method = two)
  expect_false(identical(tarshare:::shared_identity(quote(NULL), baseenv(), a)$key,
                         tarshare:::shared_identity(quote(NULL), baseenv(), b)$key))
  descriptor <- shared_file(tempfile(), id = "immutable:not-localized")
  expect_identical(shared_context(files = list(model = descriptor))$files$model, descriptor)
})()

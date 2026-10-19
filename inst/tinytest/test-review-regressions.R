library(tarshare)

# Native CAS plus unchanged metadata needs no action cache for compatible pipelines.
(function() {
  env <- new.env()
  source(system.file("examples", "native-cas-metadata.R", package = "tarshare"), local = env)
  result <- env$native_cas_metadata_example()
  on.exit(unlink(result$root, recursive = TRUE))
  expect_identical(result$computations, 1L)
})()

# Actual method dispatch changes invalidate an existing store and a fresh store.
(function() {
  root <- tempfile("tarshare-method-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  script <- file.path(root, "_targets.R")
  write <- function(offset) {
    pipeline <- bquote({
      cache <- tarshare::shared_cache(.(file.path(root, "cache")))
      calculate <- function(x) UseMethod("calculate")
      calculate.item <- function(x) unclass(x) + .(offset)
      list(tarshare::tar_shared(
        result, calculate(structure(1L, class = "item")), cache,
        context = tarshare::shared_context(method = calculate.item),
        packages = character()
      ))
    })
    dput(pipeline, file = script)
  }
  run <- function(store) targets::tar_make(script = script, store = store,
    callr_function = NULL, reporter = "silent", envir = new.env(parent = baseenv()))
  a <- file.path(root, "a")
  b <- file.path(root, "b")
  write(1L)
  run(a)
  expect_identical(targets::tar_read_raw("result", store = a), 2L)
  write(2L)
  run(a)
  run(b)
  expect_identical(targets::tar_read_raw("result", store = a), 3L)
  expect_identical(targets::tar_read_raw("result", store = b), 3L)
})()

# Interrupted collection leaves only reclaimable unreferenced data.
(function() {
  root <- tempfile("tarshare-interrupted-gc-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  suppressMessages(shared_run(1L, cache, owner = "finished"))
  suppressMessages(shared_run(2L, cache, owner = "finished"))
  shared_release(cache, "finished", quiescent = TRUE)
  collect <- shared_gc
  hook <- new.env(parent = environment(collect))
  count <- 0L
  hook$unlink <- function(...) {
    count <<- count + 1L
    if (count == 2L) stop("interrupted collection")
    base::unlink(...)
  }
  environment(collect) <- hook
  expect_error(collect(cache, dry_run = FALSE, quiescent = TRUE), "interrupted collection")
  expect_length(list.dirs(file.path(root, "objects"), recursive = FALSE), 2L)
  result <- shared_gc(cache, dry_run = FALSE, quiescent = TRUE)
  expect_true(all(result$removed))
  expect_identical(nrow(shared_gc(cache)), 0L)
})()

# A failed upload never publishes a native record or moves the original input.
(function() {
  root <- tempfile("tarshare-partial-upload-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(file.path(root, "cache"))
  input <- file.path(root, "input")
  writeLines("complete", input)
  upload <- shared_cas_upload
  hook <- new.env(parent = environment(upload))
  hook$shared_copy_path <- function(from, to) {
    dir.create(dirname(to), recursive = TRUE)
    writeLines("partial", to)
    stop("upload interrupted")
  }
  environment(upload) <- hook
  expect_error(upload("native", input, cache), "upload interrupted")
  expect_false(shared_cas_exists("native", cache))
  expect_identical(readLines(input), "complete")
  shared_cas_upload("native", input, cache)
  expect_true(shared_cas_exists("native", cache))
})()

# A store which imports native metadata retains its objects even when skipped.
(function() {
  root <- tempfile("tarshare-native-owners-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  script <- file.path(root, "_targets.R")
  path <- file.path(root, "cache")
  pipeline <- bquote({
    cache <- tarshare::shared_cache(.(path))
    list(targets::tar_target(
      result, 42L, repository = tarshare::shared_repository(cache)
    ))
  })
  dput(pipeline, file = script)
  run <- function(store) targets::tar_make(script = script, store = store,
    callr_function = NULL, reporter = "silent", envir = new.env(parent = baseenv()))
  a <- file.path(root, "a")
  b <- file.path(root, "b")
  run(a)
  dir.create(b)
  expect_true(file.copy(file.path(a, "meta"), b, recursive = TRUE))
  run(b)
  cache <- shared_cache(path)
  expect_true(shared_owner(b) %in% shared_references(cache)$owner)
  shared_release(cache, shared_owner(a), quiescent = TRUE)
  expect_false(any(shared_gc(cache)$kind == "native"))
  expect_identical(targets::tar_read_raw("result", store = b), 42L)
})()

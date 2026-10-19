library(tarshare)

# Two owners retain the same object independently, including historical actions.
(function() {
  root <- tempfile("tarshare-retention-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  produce <- function() {
    file <- shared_path("data.txt")
    writeLines("payload", file)
    file
  }
  run <- function(owner, generation = 1L) suppressMessages(shared_run(
    produce(), cache, format = "file", owner = owner, context = generation))
  first <- run("store-a")
  second <- run("store-b")
  expect_identical(first, second)
  refs <- shared_references(cache)
  expect_identical(sort(refs$owner), c("store-a", "store-b"))
  expect_length(unique(refs$key), 1L)
  expect_error(shared_release(cache, "store-a"), "quiescent")
  shared_release(cache, "store-a", quiescent = TRUE)
  expect_identical(nrow(shared_gc(cache)), 0L)
  expect_true(file.exists(first))
  history <- run("store-b", 2L)
  expect_identical(history, first)
  expect_length(shared_references(cache)$key, 2L)
  # An external retained reader remains protected after the store releases.
  key <- refs$key[[1L]]
  shared_retain(cache, key, "reader")
  shared_release(cache, "store-b", quiescent = TRUE)
  plan <- shared_gc(cache)
  expect_false(any(plan$kind == "objects"))
  shared_gc(cache, dry_run = FALSE, quiescent = TRUE)
  expect_identical(readLines(first), "payload")
  shared_release(cache, "reader", quiescent = TRUE)
  plan <- shared_gc(cache)
  expect_true(any(plan$kind == "objects"))
  expect_true(attr(plan, "selected_bytes") > 0)
  expect_true(file.exists(first))
  expect_error(shared_gc(cache, dry_run = FALSE), "quiescent")
  locks <- list.files(file.path(root, "locks"))
  removed <- shared_gc(cache, dry_run = FALSE, quiescent = TRUE)
  expect_true(all(removed$removed))
  expect_identical(attr(removed, "selected_bytes"), attr(removed, "removed_bytes"))
  expect_false(file.exists(first))
  expect_identical(list.files(file.path(root, "locks")), locks)
})()

# Abandoned stages have a grace period; unrelated files are outside GC's scope.
(function() {
  root <- tempfile("tarshare-stages-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  stage <- tarshare:::shared_stage(cache, "objects")
  writeLines("partial", file.path(stage, "partial.txt"))
  dir.create(file.path(root, "unrelated"))
  writeLines("retain", file.path(root, "unrelated", "keep.txt"))
  expect_identical(nrow(shared_gc(cache)), 0L)
  plan <- shared_gc(cache, stage_age = 0)
  expect_identical(plan$reason, "abandoned-stage")
  shared_gc(cache, dry_run = FALSE, quiescent = TRUE, stage_age = 0)
  expect_false(dir.exists(stage))
  expect_true(file.exists(file.path(root, "unrelated", "keep.txt")))
})()

# Crashing between object publication and action publication leaves an orphan, not a hit.
(function() {
  root <- tempfile("tarshare-orphan-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  fault <- shared_run
  hook <- new.env(parent = environment(fault))
  original <- tarshare:::shared_publish
  hook$shared_publish <- function(stage, entry) {
    if (basename(dirname(entry)) == "actions") stop("interrupted action publication")
    original(stage, entry)
  }
  environment(fault) <- hook
  expect_error(suppressMessages(fault(42L, cache)), "interrupted action")
  expect_length(shared_references(cache)$key, 0L)
  expect_identical(shared_gc(cache)$kind, "objects")
  expect_identical(suppressMessages(shared_run(42L, cache)), 42L)
  expect_identical(nrow(shared_gc(cache)), 0L)
  ref <- tarshare:::shared_refs_read(cache)$path[[1L]]
  writeLines("damaged", file.path(ref, "result.rds"))
  expect_error(shared_gc(cache, dry_run = FALSE, quiescent = TRUE), "Invalid retention")
  expect_length(list.dirs(file.path(root, "objects"), recursive = FALSE), 1L)
})()

# Native callbacks copy rather than move; they reject missing and corrupt data.
(function() {
  root <- tempfile("tarshare-native-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(file.path(root, "cache"))
  input <- file.path(root, "bundle")
  dir.create(input)
  dir.create(file.path(input, "empty"))
  writeLines("payload", file.path(input, "data.txt"))
  writeLines("index", file.path(input, "data.idx"))
  shared_cas_upload("native-one", input, cache)
  expect_true(dir.exists(input))
  expect_true(shared_cas_exists("native-one", cache))
  expect_false(shared_cas_exists("absent", cache))
  expect_identical(shared_cas_list(c("absent", "native-one"), cache), "native-one")
  output <- file.path(root, "download")
  shared_cas_download("native-one", output, cache)
  expect_identical(readLines(file.path(output, "data.txt")), "payload")
  expect_true(file.exists(file.path(output, "data.idx")))
  expect_true(dir.exists(file.path(output, "empty")))
  expect_error(shared_cas_download("absent", tempfile(), cache), "Missing or invalid")
  native <- list.dirs(file.path(cache$path, "native"), recursive = FALSE)[[1L]]
  unlink(file.path(native, "files", "payload", "data.idx"))
  expect_false(shared_cas_exists("native-one", cache))
  shared_cas_upload("native-one", input, cache)
  expect_true(shared_cas_exists("native-one", cache))
  expect_identical(nrow(shared_gc(cache)), 0L)
})()

# Exercise both the public adapter and a native CAS backend that moves its inputs.
(function() {
  roots <- character()
  on.exit(unlink(roots, recursive = TRUE))
  for (backend in c("shared", "moving")) {
    root <- tempfile("tarshare-cas-pipeline-")
    roots <- c(roots, root)
    dir.create(root)
    cache_path <- file.path(root, "cache")
    script <- file.path(root, "_targets.R")
    counter <- file.path(root, "counter")
    native_path <- file.path(root, "native")
    repository <- if (backend == "shared") {
      quote(tarshare::shared_repository(cache))
    } else {
      bquote(targets::tar_repository_cas_local(.(native_path)))
    }
    pipeline <- bquote({
      cache <- tarshare::shared_cache(.(cache_path))
      counter <- .(counter)
      make_bundle <- function() {
        cat("computed\n", file = counter, append = TRUE)
        writeLines("data", tarshare::shared_path("data.txt"))
        writeLines("sidecar", tarshare::shared_path("data.idx"))
        tarshare::shared_path()
      }

      list(tarshare::tar_shared(
        result, make_bundle(), cache, format = "file",
        repository = .(repository), packages = character()
      ))
    })
    dput(pipeline, file = script)
    run <- function(store) targets::tar_make(script = script, store = store,
      callr_function = NULL, reporter = "silent", envir = new.env(parent = baseenv()))
    a <- file.path(root, "store-a")
    b <- file.path(root, "store-b")
    run(a)
    run(b)
    expect_identical(readLines(counter), "computed")
    for (store in c(a, b)) {
      path <- targets::tar_read_raw("result", store = store)
      expect_identical(readLines(file.path(path, "data.txt")), "data")
      expect_identical(readLines(file.path(path, "data.idx")), "sidecar")
    }
    cache <- shared_cache(cache_path)
    refs <- shared_references(cache)
    expect_true(all(c(shared_owner(a), shared_owner(b)) %in% refs$owner))
    objects <- list.dirs(file.path(cache_path, "objects"), recursive = FALSE)
    expect_length(objects, 1L)
    expect_true(file.exists(file.path(objects, "files", "data.idx")))
    unlink(a, recursive = TRUE)
    shared_release(cache, shared_owner(a), quiescent = TRUE)
    expect_false(any(shared_gc(cache)$kind == "objects"))
  }
})()

# Copying a subset to a moving backend cannot silently drop an unreturned sidecar.
(function() {
  root <- tempfile("tarshare-sidecar-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root)
  produce <- function() {
    path <- shared_path("data.txt")
    writeLines("data", path)
    writeLines("sidecar", paste0(path, ".idx"))
    path
  }
  expect_error(suppressMessages(shared_run(produce(), cache, format = "file",
    localize = TRUE)), "every sidecar")
})()

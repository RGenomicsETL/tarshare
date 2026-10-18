library(tarshare)

cache_fixture <- function() {
  root <- tempfile("tarshare-tests-")
  dir.create(root)
  list(root = root, cache = shared_cache(file.path(root, "cache")))
}

cache_events <- function(code) {
  events <- character()
  value <- withCallingHandlers(code, tarshare_event = function(event) {
    events <<- c(events, event$event)
    invokeRestart("muffleMessage")
  })
  list(value = value, events = events)
}

# cached NULL and structured R values retain types and attributes
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  x <- data.frame(group = factor(c("a", "b")), date = as.Date(c("2020-01-01", NA)))
  run <- function() shared_run(x, cache)
  first <- cache_events(run())
  second <- cache_events(run())
  expect_identical(first$events, "compute")
  expect_identical(second$events, "hit")
  expect_identical(second$value, x)
  null <- function() shared_run(NULL, cache)
  expect_null(cache_events(null())$value)
  expect_identical(cache_events(null())$events, "hit")
})()

# file bundles retain structure and complete sidecars
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  produce <- function() {
    first <- shared_path("a/data.txt")
    second <- shared_path("b/data.txt")
    writeLines("one", first)
    writeLines("two", second)
    writeLines("index", paste0(first, ".index"))
    c(first = first, second = second)
  }
  run <- function() shared_run(produce(), cache, format = "file")
  first <- cache_events(run())
  second <- cache_events(run())
  expect_identical(second$events, "hit")
  expect_identical(first$value, second$value)
  expect_identical(names(second$value), c("first", "second"))
  expect_identical(readLines(second$value[[1L]]), "one")
  expect_identical(readLines(second$value[[2L]]), "two")
  expect_true(file.exists(paste0(second$value[[1L]], ".index")))
  expect_false(any(grepl(".stage-", second$value, fixed = TRUE)))

  unlink(paste0(second$value[[1L]], ".index"))
  repaired <- cache_events(run())
  expect_identical(repaired$events, "compute")
  expect_true(file.exists(paste0(repaired$value[[1L]], ".index")))
})()

# directory outputs include empty subdirectories
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  produce <- function() {
    root <- shared_path()
    dir.create(file.path(root, "empty"))
    writeLines("payload", file.path(root, "value.txt"))
    root
  }
  run <- function() shared_run(produce(), cache, format = "file")
  path <- cache_events(run())$value
  expect_true(dir.exists(file.path(path, "empty")))
  expect_identical(cache_events(run())$events, "hit")
  unlink(file.path(path, "empty"), recursive = TRUE)
  expect_identical(cache_events(run())$events, "compute")
})()

# same-size file corruption and damaged records do not become hits
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  produce <- function() {
    path <- shared_path("value.txt")
    writeLines("one", path)
    path
  }
  run <- function() shared_run(produce(), cache, format = "file")
  path <- cache_events(run())$value
  writeLines("two", path)
  repaired <- cache_events(run())
  expect_identical(repaired$events, "compute")
  expect_identical(readLines(repaired$value), "one")
  record <- file.path(dirname(dirname(path)), "result.rds")
  writeLines("broken", record)
  expect_identical(cache_events(run())$events, "compute")
})()

# errors leave no published result or lock held
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  fail <- function() {
    writeLines("partial", shared_path("partial.txt"))
    stop("computation failed")
  }
  run <- function() shared_run(fail(), cache, format = "file")
  expect_error(suppressMessages(run()), "computation failed")
  expect_error(suppressMessages(run()), "computation failed")
  expect_length(list.files(cache$path, pattern = "^complete$", recursive = TRUE), 0L)
  expect_length(list.files(file.path(cache$path, "v2", "objects"),
                          pattern = "^.stage-", recursive = TRUE, all.files = TRUE), 0L)
})()

# files outside staging and symbolic links are rejected
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  outside <- file.path(fixture$root, "outside.txt")
  writeLines("outside", outside)
  expect_error(suppressMessages(shared_run(outside, cache, format = "file")),
               "inside shared_path")
  expect_error(shared_path("x"), "running format")
  escape <- function() shared_path("../escape.txt")
  expect_error(suppressMessages(shared_run(escape(), cache, format = "file")),
               "relative")
  if (.Platform$OS.type == "windows") return(invisible(NULL))
  link <- function() {
    out <- shared_path("linked.txt")
    file.symlink(outside, out)
    out
  }
  expect_error(suppressMessages(shared_run(link(), cache, format = "file")),
               "symbolic links")
})()

# input content identity allows reuse across locations
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  a <- file.path(fixture$root, "a.txt")
  b <- file.path(fixture$root, "b.txt")
  writeLines("first", a)
  file.copy(a, b)
  input <- shared_file(a)
  run <- function() shared_run(readLines(input), cache)
  expect_identical(cache_events(run())$events, "compute")
  input <- shared_file(b)
  expect_identical(cache_events(run())$events, "hit")
  writeLines("other", b)
  input <- shared_file(b)
  expect_identical(cache_events(run())$events, "compute")
  expect_identical(cache_events(run())$value, "other")
  # Supplied immutable identities do not cause any file read.
  identified <- shared_file(file.path(fixture$root, "not-localized.txt"), id = "version-1")
  expect_identical(attr(identified, "tarshare_id"), "version-1")
})()

# RNG state is restored after hits, misses, and failures
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  original_kind <- RNGkind()
  on.exit(do.call(RNGkind, as.list(original_kind)), add = TRUE)
  set.seed(937)
  before <- .Random.seed
  run <- function() shared_run(stats::rnorm(4), cache)
  first <- cache_events(run())
  expect_identical(.Random.seed, before)
  second <- cache_events(run())
  expect_identical(second$events, "hit")
  expect_identical(second$value, first$value)
  expect_identical(.Random.seed, before)
  expect_error(suppressMessages(shared_run({ stats::rnorm(1); stop("failed") }, cache)),
               "failed")
  expect_identical(.Random.seed, before)
})()

# R outputs cannot contain live resources
(function() {
  fixture <- cache_fixture()
  on.exit(unlink(fixture$root, recursive = TRUE))
  cache <- fixture$cache
  expect_error(suppressMessages(shared_run(new.env(), cache)), "self-contained")
  expect_error(suppressMessages(shared_run(list(e = new.env()), cache)), "self-contained")
  expression_value <- function() as.expression(list(new.env(parent = emptyenv())))
  call_value <- function() as.call(list(quote(identity), new.env(parent = emptyenv())))
  expect_error(suppressMessages(shared_run(expression_value(), cache)), "self-contained")
  expect_error(suppressMessages(shared_run(call_value(), cache)), "self-contained")
})()

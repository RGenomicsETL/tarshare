library(tarshare)

# Visibility retries are bounded and do not turn hard I/O errors into misses.
(function() {
  root <- tempfile("tarshare-visibility-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root, visibility_timeout = 0.2, poll_interval = 0.01)
  count <- 0L
  read <- function() {
    count <<- count + 1L
    if (count < 3L) NULL else 42L
  }
  expect_identical(tarshare:::shared_retry(cache, read), 42L)
  expect_identical(count, 3L)
  expect_null(tarshare:::shared_retry(cache, function() NULL))
  expect_error(tarshare:::shared_retry(cache, function() {
    tarshare:::shared_storage_error("permission failure")
  }), "permission failure", class = "tarshare_storage_error")
  expect_error(shared_cache(tempfile(), visibility_timeout = Inf), "finite")
})()

# A second process may publish while a reader retries visibility.
(function() {
  if (!requireNamespace("callr", quietly = TRUE)) return(invisible(NULL))
  root <- tempfile("tarshare-visible-writer-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root, visibility_timeout = 3, poll_interval = 0.02)
  worker <- function(root) {
    library(tarshare)
    cache <- shared_cache(root)
    file <- tempfile()
    on.exit(unlink(file))
    writeLines("complete", file)
    shared_cas_upload("published", file, cache)
    TRUE
  }
  child <- callr::r_bg(worker, args = list(root), libpath = .libPaths())
  on.exit(child$kill(), add = TRUE)
  expect_true(shared_cas_exists("published", cache))
  child$wait(10000)
  expect_identical(child$get_result(), TRUE)
})()

# Maintenance must not race an active writer, even with a quiescence assertion.
(function() {
  if (!requireNamespace("callr", quietly = TRUE)) return(invisible(NULL))
  root <- tempfile("tarshare-maintenance-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(file.path(root, "cache"), timeout = 0)
  worker <- function(root) {
    library(tarshare)
    cache <- shared_cache(file.path(root, "cache"))
    ready <- file.path(root, "ready")
    release <- file.path(root, "release")
    run <- function() {
      file.create(ready)
      deadline <- Sys.time() + 20
      while (!file.exists(release)) {
        if (Sys.time() > deadline) stop("test release timed out")
        Sys.sleep(0.01)
      }
      1L
    }
    suppressMessages(shared_run(run(), cache))
  }
  child <- callr::r_bg(worker, args = list(root), libpath = .libPaths())
  on.exit(child$kill(), add = TRUE)
  deadline <- Sys.time() + 10
  while (!file.exists(file.path(root, "ready")) && child$is_alive() && Sys.time() < deadline) {
    Sys.sleep(0.01)
  }
  expect_true(file.exists(file.path(root, "ready")))
  expect_error(shared_gc(cache, dry_run = FALSE, quiescent = TRUE), "Timed out")
  file.create(file.path(root, "release"))
  child$wait(10000)
  expect_identical(child$get_result(), 1L)
  expect_identical(nrow(shared_gc(cache)), 0L)
})()

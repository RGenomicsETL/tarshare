test_that("two R processes coordinate one computation", {
  skip_if_not_installed("callr")
  root <- tempfile("tarshare-concurrent-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  worker <- function(root) {
    library(tarshare)
    cache <- shared_cache(file.path(root, "cache"))
    log <- file.path(root, "computed.txt")
    compute <- function() {
      cat("computed\n", file = log, append = TRUE)
      Sys.sleep(0.5)
      c(result = 42L)
    }
    suppressMessages(shared_run(compute(), cache))
  }
  a <- callr::r_bg(worker, args = list(root), libpath = .libPaths())
  on.exit(a$kill(), add = TRUE)
  b <- callr::r_bg(worker, args = list(root), libpath = .libPaths())
  on.exit(b$kill(), add = TRUE)
  a$wait(15000)
  b$wait(15000)
  expect_false(a$is_alive())
  expect_false(b$is_alive())
  expect_identical(a$get_result(), c(result = 42L))
  expect_identical(b$get_result(), c(result = 42L))
  expect_length(readLines(file.path(root, "computed.txt")), 1L)
})

test_that("a killed writer releases the key and never publishes partial output", {
  skip_if_not_installed("callr")
  root <- tempfile("tarshare-killed-writer-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  worker <- function(root) {
    library(tarshare)
    cache <- shared_cache(file.path(root, "cache"), timeout = 3)
    started <- file.path(root, "started")
    release <- file.path(root, "release")
    compute <- function() {
      out <- shared_path("result.txt")
      writeLines("partial", out)
      file.create(started)
      while (!file.exists(release)) Sys.sleep(0.02)
      writeLines("complete", out)
      out
    }
    suppressMessages(shared_run(compute(), cache, format = "file"))
  }
  a <- callr::r_bg(worker, args = list(root), libpath = .libPaths())
  on.exit(a$kill(), add = TRUE)
  deadline <- Sys.time() + 10
  while (!file.exists(file.path(root, "started")) && a$is_alive() && Sys.time() < deadline) {
    Sys.sleep(0.02)
  }
  expect_true(file.exists(file.path(root, "started")))
  a$kill()
  a$wait(3000)
  expect_length(list.files(file.path(root, "cache"), pattern = "^complete$",
                          recursive = TRUE), 0L)
  file.create(file.path(root, "release"))
  out <- callr::r(worker, args = list(root), libpath = .libPaths(), timeout = 10)
  expect_identical(readLines(out), "complete")
  expect_false(grepl(".stage-", out, fixed = TRUE))
})

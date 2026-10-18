library(tarshare)

# Different action keys can converge on content which is not immediately visible.
# Fault injection simulates two stale reads. Republishing the existing object is
# an error: the second action must wait for and reuse the original content.
(function() {
  root <- tempfile("tarshare-object-visibility-")
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(root, visibility_timeout = 0.1, poll_interval = 0.001)
  expect_identical(suppressMessages(shared_run(2L, cache)), 2L)
  run <- shared_run
  hook <- new.env(parent = environment(run))
  reads <- 0L
  publishes <- 0L
  read <- tarshare:::shared_object_read
  publish <- tarshare:::shared_publish
  hook$shared_object_read <- function(path, verify, expected = NULL) {
    reads <<- reads + 1L
    if (reads <= 2L) NULL else read(path, verify, expected)
  }
  hook$shared_publish <- function(stage, entry) {
    if (basename(dirname(entry)) == "objects") {
      publishes <<- publishes + 1L
      stop("Existing content must not be republished after a transient miss.")
    }
    publish(stage, entry)
  }
  environment(run) <- hook
  expect_identical(suppressMessages(run(1L + 1L, cache)), 2L)
  expect_true(reads >= 3L)
  expect_identical(publishes, 0L)
  expect_length(list.dirs(file.path(root, "v2", "actions"), recursive = FALSE), 2L)
  expect_length(list.dirs(file.path(root, "v2", "objects"), recursive = FALSE), 1L)
})()

# Native uploads use the same bounded prepublication recheck under their key lock.
(function() {
  root <- tempfile("tarshare-native-visibility-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  cache <- shared_cache(file.path(root, "cache"), visibility_timeout = 0.1,
                        poll_interval = 0.001)
  input <- file.path(root, "input.txt")
  writeLines("payload", input)
  shared_cas_upload("native", input, cache)
  upload <- shared_cas_upload
  hook <- new.env(parent = environment(upload))
  reads <- 0L
  read <- tarshare:::shared_object_read
  hook$shared_object_read <- function(path, verify, expected = NULL) {
    reads <<- reads + 1L
    if (reads <= 2L) NULL else read(path, verify, expected)
  }
  hook$shared_copy_path <- function(...) stop("Existing native content must not be recopied.")
  environment(upload) <- hook
  expect_null(upload("native", input, cache))
  expect_true(reads >= 3L)
  expect_true(shared_cas_exists("native", cache))
  expect_identical(readLines(input), "payload")
})()

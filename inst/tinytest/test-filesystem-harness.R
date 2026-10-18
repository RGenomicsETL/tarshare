# Exercise the two-role harness itself; this is not NFS or multi-host evidence.
(function() {
  if (!requireNamespace("callr", quietly = TRUE)) return(invisible(NULL))
  root <- tempfile("tarshare-harness-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  worker <- function(root, role) {
    source(system.file("qualification", "shared-filesystem.R", package = "tarshare"))
    qualify_shared_filesystem(root, "diagnostic", role,
      profile = "CI local filesystem, same host", revision = "diagnostic",
      timeout = 30, allow_same_host = TRUE)
  }
  a <- callr::r_bg(worker, args = list(root, "a"), libpath = .libPaths())
  on.exit(a$kill(), add = TRUE)
  b <- callr::r_bg(worker, args = list(root, "b"), libpath = .libPaths())
  on.exit(b$kill(), add = TRUE)
  a$wait(120000)
  b$wait(120000)
  expect_false(a$is_alive())
  expect_false(b$is_alive())
  first <- a$get_result()
  second <- b$get_result()
  expect_identical(first$status, "same-host-diagnostic-only")
  expect_identical(second$status, "same-host-diagnostic-only")
  expect_identical(first$collection$removed_bytes, first$collection$selected_bytes)
})()

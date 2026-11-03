library(tarshare)

# The store protocol against a real shared_serve() process. Each block names
# the property of design/spec/TarshareStore.tla it exercises. Separate mirrors
# stand in for separate hosts.
if (!requireNamespace("nanonext", quietly = TRUE) ||
    !requireNamespace("callr", quietly = TRUE)) {
  exit_file("nanonext and callr are needed for store tests")
}
options(tarshare.request_timeout = 5)

store_start <- function(root, url, token = "test-token") {
  process <- callr::r_bg(function(path, url, token) {
    tarshare::shared_serve(path, url, token = token)
  }, args = list(file.path(root, "store"), url, token), libpath = .libPaths())
  deadline <- Sys.time() + 20
  repeat {
    probe <- tryCatch(nanonext::socket("req", dial = url, autostart = NA),
                      error = function(e) NULL)
    if (!is.null(probe)) {
      close(probe)
      break
    }
    if (!process$is_alive() || Sys.time() > deadline) stop("store did not start")
    Sys.sleep(0.05)
  }
  process
}

store_url <- function() sprintf("tcp://127.0.0.1:%d", sample(20000:60000, 1L))

events <- function(expr) {
  seen <- character()
  value <- withCallingHandlers(expr, tarshare_event = function(e) {
    seen <<- c(seen, e$event)
    invokeRestart("muffleMessage")
  })
  list(value = value, events = seen)
}

# Every worker computes the same key. Whether it blocks is read at run time,
# outside the key.
worker <- function(url, mirror, log, block = FALSE) {
  Sys.setenv(TARSHARE_TOKEN = "test-token", TARSHARE_TEST_BLOCK = if (block) "1" else "")
  cache <- tarshare::shared_cache(url, mirror = mirror)
  started <- paste0(log, ".started")
  compute <- function() {
    cat("computed\n", file = log, append = TRUE)
    if (nzchar(Sys.getenv("TARSHARE_TEST_BLOCK"))) {
      file.create(started)
      repeat Sys.sleep(1)
    }
    Sys.sleep(0.5)
    Sys.getpid() # differs between processes: two computations would disagree
  }
  suppressMessages(tarshare::shared_run(compute(), cache))
}

# OneResult and SingleFlight: two hosts ask at once; one computes, both
# deliver its result.
(function() {
  root <- tempfile("ts")
  dir.create(root)
  url <- store_url()
  server <- store_start(root, url)
  on.exit({ server$kill(); unlink(root, recursive = TRUE) })
  log <- file.path(root, "log")
  a <- callr::r_bg(worker, list(url, file.path(root, "a"), log), libpath = .libPaths())
  b <- callr::r_bg(worker, list(url, file.path(root, "b"), log), libpath = .libPaths())
  a$wait(30000)
  b$wait(30000)
  expect_identical(a$get_result(), b$get_result())
  expect_length(readLines(log), 1L)
})()

# LeaseOnLiveConnection and Completes: a holder busy in its command keeps the
# lease without heartbeats; killing it hands the key to the waiter at once.
(function() {
  root <- tempfile("ts")
  dir.create(root)
  url <- store_url()
  server <- store_start(root, url)
  on.exit({ server$kill(); unlink(root, recursive = TRUE) })
  log <- file.path(root, "log")
  started <- paste0(log, ".started")
  holder <- callr::r_bg(worker, list(url, file.path(root, "a"), log, TRUE),
                        libpath = .libPaths())
  on.exit(holder$kill(), add = TRUE)
  deadline <- Sys.time() + 20
  while (!file.exists(started) && Sys.time() < deadline) Sys.sleep(0.05)
  waiter <- callr::r_bg(worker, list(url, file.path(root, "b"), log), libpath = .libPaths())
  on.exit(waiter$kill(), add = TRUE)
  Sys.sleep(1.5)
  expect_true(waiter$is_alive())
  expect_length(readLines(log), 1L)
  holder$kill()
  waiter$wait(20000)
  expect_false(waiter$is_alive())
  expect_identical(waiter$get_result(), waiter$get_pid())
  expect_length(readLines(log), 2L)
})()

(function() {
  root <- tempfile("ts")
  dir.create(root)
  url <- store_url()
  server <- store_start(root, url)
  on.exit({ server$kill(); unlink(root, recursive = TRUE) })
  old <- Sys.getenv("TARSHARE_TOKEN")
  on.exit(Sys.setenv(TARSHARE_TOKEN = old), add = TRUE)
  Sys.setenv(TARSHARE_TOKEN = "test-token")
  cache_a <- shared_cache(url, mirror = file.path(root, "a"))
  cache_b <- shared_cache(url, mirror = file.path(root, "b"))

  # File results move between hosts with their sidecars, and a path to a
  # result has the same identity on every host.
  bundle <- quote({
    writeLines("data", shared_path("data.txt"))
    writeLines("index", shared_path("index/data.idx"))
    shared_path()
  })
  first <- events(eval(bquote(shared_run(.(bundle), cache_a, format = "file"))))
  second <- events(eval(bquote(shared_run(.(bundle), cache_b, format = "file"))))
  expect_identical(c(first$events, second$events), c("compute", "hit"))
  expect_false(identical(first$value, second$value))
  expect_identical(readLines(file.path(second$value, "index", "data.idx")), "index")
  path <- first$value
  events(shared_run(readLines(file.path(path, "data.txt")), cache_a))
  path <- second$value
  expect_identical(events(shared_run(readLines(file.path(path, "data.txt")), cache_b))$events,
                   "hit")

  # OneResult: publication is put-if-absent, and the loser gets the winner.
  # Objects to publish under made-up keys: computed in the mirror itself.
  mirror <- tarshare:::shared_mirror(cache_a)
  object <- function(value) {
    key <- NULL
    withCallingHandlers(eval(bquote(shared_run(.(value), mirror))),
      tarshare_event = function(e) {
        key <<- e$key
        invokeRestart("muffleMessage")
      })
    tarshare:::shared_read_record(tarshare:::shared_location(mirror, "actions", key))$object
  }
  one <- object(1)
  two <- object(2)
  key <- strrep("a", 64L)
  publish <- function(key, object) {
    tarshare:::shared_remote_publish(cache_a, mirror, key, object, "rds", "owner")
  }
  expect_identical(publish(key, one), one)
  expect_identical(publish(key, two), one)

  # ActionsHaveObjects: an uncommitted object cannot be published.
  three <- object(3)
  other <- strrep("b", 64L)
  refused <- tarshare:::shared_rpc(cache_a, "tarshare.publish",
    list(key = other, object = three, format = "rds", owner = "owner"),
    accept = "not_found")
  expect_identical(refused$status, "not_found")

  # PinsHold and online collection: collection keeps pinned results, removes
  # an uploaded but unpublished object, and the publisher uploads it again.
  tarshare:::shared_upload(cache_a, mirror, three)
  expect_true(tarshare:::shared_remote_have(cache_a, three))
  collected <- shared_gc(shared_cache(file.path(root, "store")), dry_run = FALSE,
                         quiescent = TRUE)
  expect_true(three %in% collected$key)
  expect_false(one %in% collected$key)
  expect_identical(publish(other, three), three)
  claim <- tarshare:::shared_claim(cache_b, key, "rds", "owner-b")
  expect_identical(claim$fields[c("state", "object")], list(state = "hit", object = one))

  # The store refuses unknown callers and manifests that escape the object.
  Sys.setenv(TARSHARE_TOKEN = "wrong")
  expect_error(shared_run(sum(1:3), cache_a), class = "tarshare_storage_error")
  Sys.setenv(TARSHARE_TOKEN = "test-token")
  id <- strrep("c", 64L)
  escape <- c("d\tfiles", paste0("f\tresult.rds\t1\t", id), paste0("f\tcomplete\t65\t", id),
              paste0("f\t../escape\t1\t", id))
  expect_error(tarshare:::shared_rpc(cache_a, "tarshare.put_begin", list(id = id), body = escape),
               "Invalid object manifest", class = "tarshare_storage_error")

  # An outage is a hard error, not a recomputation; a restart keeps results.
  server$kill()
  server$wait(5000)
  expect_error(shared_run(sum(1:10), cache_a), class = "tarshare_storage_error")
  server <- store_start(root, url)
  expect_identical(events(eval(bquote(shared_run(.(bundle), cache_a, format = "file"))))$events,
                   "hit")
})()

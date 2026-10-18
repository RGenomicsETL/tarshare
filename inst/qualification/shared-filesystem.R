# Source this installed script on TWO hosts using the same new disposable run ID.
# No host connections or mounts are provisioned. Reports remain in the run directory.
qualify_shared_filesystem <- function(root, run_id, role, profile, revision,
                                     timeout = 60, allow_same_host = FALSE) {
  stopifnot(dir.exists(root), grepl("^[A-Za-z0-9_-]+$", run_id),
            length(run_id) == 1L, role %in% c("a", "b"), length(role) == 1L,
            is.character(profile), length(profile) == 1L, nzchar(profile),
            is.character(revision), length(revision) == 1L, nzchar(revision),
            is.numeric(timeout), is.finite(timeout), timeout > 0)
  if (!requireNamespace("callr", quietly = TRUE)) stop("Install callr before qualification.")
  root <- normalizePath(root, winslash = "/")
  run <- file.path(root, paste0("tarshare-qualification-", run_id))
  peer <- if (role == "a") "b" else "a"
  wait <- function(name) {
    until <- Sys.time() + timeout
    while (!file.exists(file.path(run, name))) {
      failures <- file.path(run, c("a.failed", "b.failed"))
      if (any(file.exists(failures))) stop("A qualification participant failed; inspect its report.")
      if (Sys.time() > until) stop("Qualification barrier timed out: ", name)
      Sys.sleep(0.02)
    }
  }
  publish <- function(name, value) {
    path <- file.path(run, name)
    stage <- tempfile(".report-", tmpdir = run)
    saveRDS(value, stage)
    if (!file.rename(stage, path)) stop("Could not publish qualification report: ", name)
  }
  if (role == "a") {
    if (!dir.create(run)) stop("Use a new disposable run ID; the directory already exists.")
    for (case in c("common", "parallel-a", "parallel-b", "before", "after")) {
      dir.create(file.path(run, case))
    }
    publish("initialized", TRUE)
  } else wait("initialized")
  if (!dir.create(file.path(run, paste0("participant-", role)))) {
    stop("This role already ran; use a new run ID.")
  }
  done <- FALSE
  on.exit(if (!done) file.create(file.path(run, paste0(role, ".failed"))), add = TRUE)
  identity <- tarshare:::shared_identity(quote(NULL), baseenv(),
    context = list(revision = revision), packages = "tarshare")$key
  metadata <- list(host = unname(Sys.info()[["nodename"]]), system = Sys.info(),
    R = R.version.string, packages = utils::sessionInfo(), profile = profile,
    revision = revision, identity = identity, role = role, command = match.call())
  publish(paste0(role, ".profile"), metadata)
  wait(paste0(peer, ".profile"))
  other <- readRDS(file.path(run, paste0(peer, ".profile")))
  distinct <- !identical(metadata$host, other$host)
  if (!distinct && !allow_same_host) stop("Two distinct hosts are required for qualification.")
  if (!identical(identity, other$identity)) stop("R, package, or source identities differ between hosts.")
  cache <- tarshare::shared_cache(file.path(run, "cache"), timeout = timeout,
                                 visibility_timeout = 0.2, poll_interval = 0.02)
  # Self-contained so callr executes precisely the same function on either host.
  worker <- function(run, case, owner, hold = FALSE, timeout = 60) {
    wait <- function(name) {
      until <- Sys.time() + timeout
      while (!file.exists(file.path(run, name))) {
        if (Sys.time() > until) stop("Worker barrier timed out: ", name)
        Sys.sleep(0.02)
      }
    }
    cache <- tarshare::shared_cache(file.path(run, "cache"), timeout = timeout,
                                   visibility_timeout = 0.2, poll_interval = 0.02)
    produce <- function() {
      marker <- tempfile("actual-", tmpdir = file.path(run, case))
      writeLines(paste(Sys.info()[["nodename"]], Sys.getpid()), marker)
      out <- tarshare::shared_path("data.txt")
      writeLines("partial", out)
      if (startsWith(case, "parallel-")) {
        file.create(file.path(run, paste0(case, ".inside")))
        other <- if (case == "parallel-a") "parallel-b" else "parallel-a"
        wait(paste0(other, ".inside"))
      }
      if (case == "before") {
        file.create(file.path(run, "before.ready"))
        wait("before.release")
      }
      Sys.sleep(0.1)
      writeLines("complete", out)
      writeLines("sidecar", tarshare::shared_path("data.idx"))
      tarshare::shared_path()
    }
    key <- event <- NULL
    path <- withCallingHandlers(tarshare::shared_run(produce(), cache, format = "file",
      context = case, owner = owner), tarshare_event = function(e) {
        key <<- e$key
        event <<- e$event
        file.create(file.path(run, paste0(case, ".", key, ".key")))
        invokeRestart("muffleMessage")
      })
    if (hold) {
      file.create(file.path(run, "after.published"))
      wait("after.release")
    }
    list(path = path, key = key, event = event)
  }
  owner <- paste0("qualification:", role)
  common <- worker(run, "common", owner, timeout = timeout)
  publish(paste0(role, ".common"), common)
  wait(paste0(peer, ".common"))
  common_peer <- readRDS(file.path(run, paste0(peer, ".common")))
  stopifnot(identical(common$key, common_peer$key),
            length(list.files(file.path(run, "common"))) == 1L,
            identical(readLines(file.path(common$path, "data.txt")), "complete"),
            identical(readLines(file.path(common$path, "data.idx")), "sidecar"))
  worker(run, paste0("parallel-", role), owner, timeout = timeout)
  publish(paste0(role, ".parallel"), TRUE)
  wait(paste0(peer, ".parallel"))
  for (case in c("before", "after")) {
    if (role == "a") {
      child <- callr::r_bg(worker,
        args = list(run, case, "qualification:crash", case == "after", timeout),
        libpath = .libPaths())
      tryCatch({
        wait(if (case == "before") "before.ready" else "after.published")
        publish(paste0(case, ".live"), TRUE)
        wait(paste0(case, ".observed"))
        child$kill()
        child$wait(timeout * 1000)
        if (child$is_alive()) stop("Could not stop the synthetic writer.")
        publish(paste0(case, ".killed"), TRUE)
        wait(paste0(case, ".recovered"))
      }, finally = child$kill())
    } else {
      wait(paste0(case, ".live"))
      if (case == "before") {
        probe <- tarshare::shared_cache(cache$path, timeout = 0)
        error <- tryCatch(tarshare::shared_gc(probe), error = base::identity)
        stopifnot(inherits(error, "error"), grepl("Timed out", conditionMessage(error)))
      } else {
        plan <- tarshare::shared_gc(cache)
        stopifnot(!any(plan$kind == "objects"))
      }
      publish(paste0(case, ".observed"), TRUE)
      wait(paste0(case, ".killed"))
      if (case == "before") file.create(file.path(run, "before.release"))
      recovered <- worker(run, case, owner, timeout = timeout)
      stopifnot(identical(recovered$event, if (case == "before") "compute" else "hit"),
        identical(readLines(file.path(recovered$path, "data.txt")), "complete"),
        identical(readLines(file.path(recovered$path, "data.idx")), "sidecar"),
        length(list.files(file.path(run, case))) == if (case == "before") 2L else 1L)
      publish(paste0(case, ".recovered"), recovered)
    }
  }
  # Both participants stop reading while A performs maintenance. B retains its
  # common result and checks it again after collection, without using it during GC.
  publish(paste0(role, ".paused"), TRUE)
  wait(paste0(peer, ".paused"))
  if (role == "a") {
    tarshare::shared_release(cache, owner, quiescent = TRUE)
    plan <- tarshare::shared_gc(cache, dry_run = FALSE, quiescent = TRUE, stage_age = 0)
    publish("collected", plan)
    wait("b.read-complete")
    refs <- tarshare::shared_references(cache)
    for (retained in unique(refs$owner)) {
      tarshare::shared_release(cache, retained, quiescent = TRUE)
    }
    removed <- tarshare::shared_gc(cache, dry_run = FALSE, quiescent = TRUE, stage_age = 0)
    publish("finished", list(selected_bytes = attr(removed, "selected_bytes"),
                              removed_bytes = attr(removed, "removed_bytes")))
  } else {
    wait("collected")
    stopifnot(identical(readLines(file.path(common$path, "data.txt")), "complete"))
    publish("b.read-complete", TRUE)
    wait("finished")
  }
  report <- list(status = if (distinct) "profile-tests-passed" else "same-host-diagnostic-only",
    metadata = metadata, peer = other$host, cases = c("same-key-exclusion",
    "different-key-overlap", "kill-before-publication", "kill-after-publication",
    "cross-participant-visibility", "writer-excludes-maintenance", "retained-reader"),
    collection = readRDS(file.path(run, "finished")))
  publish(paste0(role, ".report"), report)
  done <- TRUE
  report
}

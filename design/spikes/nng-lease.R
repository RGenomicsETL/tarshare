# Spike: a single-flight lease bound to an NNG connection.
#
# Checks the two claims the nanonext design in ../distributed-store.md relies on:
#
# 1. A lease held by a client whose R thread is busy (inside a long computation,
#    so it cannot send heartbeats) stays held, because NNG keeps the connection
#    alive on its own I/O threads.
# 2. When that client process dies, the server learns of it from monitor() /
#    read_monitor(), maps the removed pipe back to its lease via pipe_id(), and
#    releases it, so a waiting client can take over without a TTL.
#
# It also sends one 64 MiB message to confirm nanonext's default receive limit
# does not get in the way of chunked object transfer.
#
# Run from a shell: Rscript design/spikes/nng-lease.R
# Requires nanonext. Not part of the package or its tests.

stopifnot(requireNamespace("nanonext", quietly = TRUE))
root <- tempfile("nng-lease-")
dir.create(root)
url <- sprintf("ipc://%s", file.path(root, "store.ipc"))
libs <- .libPaths()

server <- bquote({
  .libPaths(.(libs))
  library(nanonext)
  say <- function(...) {
    cat(format(Sys.time(), "%H:%M:%OS2"), "server:", ..., "\n")
    flush(stdout())
  }
  sock <- socket("rep", listen = .(url))
  cv <- cv()
  mon <- monitor(sock, cv)
  ctx <- context(sock)
  leases <- character() # names: action key; values: pipe id of the holder
  aio <- recv_aio(ctx, mode = "raw", cv = cv)
  repeat {
    wait(cv)
    # Pipe ids: positive when added, negative when removed; NULL if no change.
    events <- as.integer(read_monitor(mon))
    gone <- as.character(-events[events < 0])
    if (length(gone)) {
      dead <- names(leases)[leases %in% gone]
      if (length(dead)) say("pipe closed, released lease:", dead)
      leases <- leases[!leases %in% gone]
    }
    if (unresolved(aio)) next
    bytes <- aio$data
    pipe <- as.character(pipe_id(aio))
    if (length(bytes) > 1e6) {
      answer <- paste("received", length(bytes), "bytes")
    } else {
      fields <- strsplit(rawToChar(bytes[bytes != as.raw(0L)]), "\t")[[1L]]
      key <- fields[[2L]]
      answer <- if (is.na(leases[key]) || leases[key] == pipe) {
        leases[key] <- pipe
        "GRANTED"
      } else {
        paste("BUSY", leases[key])
      }
      say("pipe", pipe, fields[[1L]], key, "->", answer)
    }
    send(ctx, answer, mode = "raw", block = TRUE)
    aio <- recv_aio(ctx, mode = "raw", cv = cv)
  }
})

client <- function(role) bquote({
  .libPaths(.(libs))
  library(nanonext)
  say <- function(...) {
    cat(format(Sys.time(), "%H:%M:%OS2"), .(role), ":", ..., "\n")
    flush(stdout())
  }
  sock <- socket("req", dial = .(url), autostart = NA)
  ask <- function(x) {
    send(sock, x, mode = "raw", block = TRUE)
    r <- recv(sock, mode = "raw", block = TRUE)
    rawToChar(r[r != as.raw(0L)])
  }
  if (.(role) == "holder") {
    say(ask("LEASE\tk1"))
    say("computing; the R thread is blocked and sends nothing")
    Sys.sleep(3600)
  } else if (.(role) == "bulk") {
    say(ask(as.raw(rep_len(0:255, 64 * 2^20))))
  } else {
    repeat {
      r <- ask("LEASE\tk1")
      say(r)
      if (identical(r, "GRANTED")) break
      Sys.sleep(0.5)
    }
  }
})

launch <- function(expr, name) {
  script <- file.path(root, paste0(name, ".R"))
  writeLines(deparse(expr), script)
  log <- file.path(root, paste0(name, ".log"))
  system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", script),
          stdout = log, stderr = log, wait = FALSE)
  Sys.sleep(1.5)
  log
}

pid_of <- function(name) {
  out <- suppressWarnings(system2("pgrep", c("-f", file.path(root, paste0(name, ".R"))),
                                  stdout = TRUE))
  as.integer(out)
}

logs <- c(server = launch(server, "server"), holder = launch(client("holder"), "holder"),
          waiter = launch(client("waiter"), "waiter"))
Sys.sleep(2)
cat("--- SIGKILL holder while it holds the lease\n")
tools::pskill(pid_of("holder"), tools::SIGKILL)
Sys.sleep(2)
logs <- c(logs, bulk = launch(client("bulk"), "bulk"))
Sys.sleep(3)
for (name in c("waiter", "server")) tools::pskill(pid_of(name))
for (name in names(logs)) {
  cat("=====", name, "\n")
  writeLines(readLines(logs[[name]]))
}
unlink(root, recursive = TRUE)

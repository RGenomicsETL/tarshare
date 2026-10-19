library(tarshare)

shared_test_project <- function(cache, name = "result", input = 3L,
                                context = "list()") {
  project <- tempfile("tarshare-project-")
  dir.create(project)
  shared_test_write_project(project, cache, name, input, context)
  project
}

shared_test_write_project <- function(project, cache, name = "result", input = 3L,
                                      context = "list()") {
  writeLines(
    c(
      paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
      "record <- function(x) {",
      "  cat('run\\n', file = 'calls.log', append = TRUE)",
      "  x * 2L",
      "}",
      "list(",
      paste0("  targets::tar_target(input, ", deparse(input), "),"),
      paste0(
        "  tarshare::tar_shared(", name, ", record(input), cache, ",
        "branch_context = ", context, ", packages = character())"
      ),
      ")"
    ),
    file.path(project, "_targets.R")
  )
}

shared_test_make <- function(project) {
  old <- setwd(project)
  on.exit(setwd(old))
  targets::tar_make(
    callr_function = NULL, reporter = "silent",
    envir = new.env(parent = baseenv())
  )
}

shared_test_read <- function(project, name) {
  targets::tar_read_raw(name, store = file.path(project, "_targets"))
}

shared_test_calls <- function(project) {
  path <- file.path(project, "calls.log")
  if (file.exists(path)) length(readLines(path)) else 0L
}

shared_test_write_branches <- function(project, cache, name, values) {
  writeLines(
    c(
      paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
      "record <- function(x) {",
      "  cat(x, '\\n', file = 'calls.log', append = TRUE)",
      "  x * 2L",
      "}",
      "list(",
      paste0("  targets::tar_target(input, ", deparse(values), "),"),
      paste0(
        "  tarshare::tar_shared(", name, ", record(input), cache, ",
        "pattern = map(input), packages = character())"
      ),
      ")"
    ),
    file.path(project, "_targets.R")
  )
}

# independent stores and renamed targets reuse a computation
(function() {
  cache <- tempfile("tarshare-cache-")
  first <- shared_test_project(cache)
  second <- shared_test_project(cache, name = "renamed")
  on.exit(unlink(c(cache, first, second), recursive = TRUE))

  shared_test_make(first)
  shared_test_make(second)
  expect_identical(shared_test_read(first, "result"), 6L)
  expect_identical(shared_test_read(second, "renamed"), 6L)
  expect_identical(shared_test_calls(first), 1L)
  expect_identical(shared_test_calls(second), 0L)

  shared_test_make(second)
  progress <- targets::tar_progress(store = file.path(second, "_targets"))
  expect_identical(progress$progress[progress$name == "renamed"], "skipped")
  expect_identical(shared_test_calls(second), 0L)
})()

# changed upstream values miss and reverting recovers shared results
(function() {
  cache <- tempfile("tarshare-cache-")
  project <- shared_test_project(cache)
  on.exit(unlink(c(cache, project), recursive = TRUE))

  shared_test_make(project)
  shared_test_write_project(project, cache, input = 4L)
  shared_test_make(project)
  expect_identical(shared_test_read(project, "result"), 8L)
  expect_identical(shared_test_calls(project), 2L)

  shared_test_write_project(project, cache, input = 3L)
  shared_test_make(project)
  expect_identical(shared_test_read(project, "result"), 6L)
  expect_identical(shared_test_calls(project), 2L)
})()

# runtime context remains a targets dependency
(function() {
  cache <- tempfile("tarshare-cache-")
  project <- tempfile("tarshare-project-")
  dir.create(project)
  on.exit(unlink(c(cache, project), recursive = TRUE))
  write_project <- function(revision) {
    writeLines(
      c(
        paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
        "record <- function() {",
        "  cat('run\\n', file = 'calls.log', append = TRUE)",
        "  7L",
        "}",
        "list(",
        paste0("  targets::tar_target(revision, ", deparse(revision), "),"),
        paste0(
          "  tarshare::tar_shared(result, record(), cache, ",
          "branch_context = list(release = revision), packages = character())"
        ),
        ")"
      ),
      file.path(project, "_targets.R")
    )
  }

  write_project("alpha")
  shared_test_make(project)
  write_project("beta")
  shared_test_make(project)
  expect_identical(shared_test_calls(project), 2L)
  expect_identical(shared_test_read(project, "result"), 7L)
})()

# dynamic branches reuse their effective input values across stores
(function() {
  cache <- tempfile("tarshare-cache-")
  first <- tempfile("tarshare-project-")
  second <- tempfile("tarshare-project-")
  dir.create(first)
  dir.create(second)
  on.exit(unlink(c(cache, first, second), recursive = TRUE))
  shared_test_write_branches(first, cache, "result", c(2L, 3L))
  shared_test_write_branches(second, cache, "renamed", c(3L, 4L))
  shared_test_make(first)
  shared_test_make(second)
  expect_identical(unname(shared_test_read(first, "result")), c(4L, 6L))
  expect_identical(unname(shared_test_read(second, "renamed")), c(6L, 8L))
  expect_identical(shared_test_calls(first), 2L)
  expect_identical(shared_test_calls(second), 1L)
})()

# default tar_make subprocesses share dynamic results
(function() {
  cache <- tempfile("tarshare-cache-")
  first <- tempfile("tarshare-project-")
  second <- tempfile("tarshare-project-")
  dir.create(first)
  dir.create(second)
  on.exit(unlink(c(cache, first, second), recursive = TRUE))
  shared_test_write_branches(first, cache, "result", c(2L, 3L))
  shared_test_write_branches(second, cache, "renamed", c(3L, 4L))
  run_subprocess <- function(project) {
    old <- setwd(project)
    on.exit(setwd(old))
    targets::tar_make(reporter = "silent")
  }

  run_subprocess(first)
  run_subprocess(second)
  expect_identical(unname(shared_test_read(first, "result")), c(4L, 6L))
  expect_identical(unname(shared_test_read(second, "renamed")), c(6L, 8L))
  expect_identical(shared_test_calls(first), 2L)
  expect_identical(shared_test_calls(second), 1L)
})()

# replicate context gives distinct reproducible branch RNG streams
(function() {
  cache <- tempfile("tarshare-cache-")
  first <- tempfile("tarshare-project-")
  second <- tempfile("tarshare-project-")
  dir.create(first)
  dir.create(second)
  on.exit(unlink(c(cache, first, second), recursive = TRUE))
  write_project <- function(project, name) {
    writeLines(
      c(
        paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
        "draw <- function() {",
        "  cat('run\\n', file = 'calls.log', append = TRUE)",
        "  stats::runif(1)",
        "}",
        "list(",
        "  targets::tar_target(replicate_id, 1:3),",
        paste0(
          "  tarshare::tar_shared(", name, ", draw(), cache, ",
          "pattern = map(replicate_id), ",
          "branch_context = list(replicate = replicate_id), packages = character())"
        ),
        ")"
      ),
      file.path(project, "_targets.R")
    )
  }
  write_project(first, "result")
  write_project(second, "renamed")
  shared_test_make(first)
  shared_test_make(second)
  values <- unname(shared_test_read(first, "result"))
  expect_length(unique(values), 3L)
  expect_identical(unname(shared_test_read(second, "renamed")), values)
  expect_identical(shared_test_calls(first), 3L)
  expect_identical(shared_test_calls(second), 0L)
})()

# the raw factory preserves runtime context and seed expressions
(function() {
  cache <- tempfile("tarshare-cache-")
  project <- tempfile("tarshare-project-")
  dir.create(project)
  on.exit(unlink(c(cache, project), recursive = TRUE))
  writeLines(
    c(
      paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
      "list(",
      "  targets::tar_target(input, 1:2),",
      "  tarshare::tar_shared_raw(",
      "    'result', quote(input * 2L), cache, pattern = quote(map(input)),",
      "    branch_context = quote(list(replicate = input)), seed = quote(input),",
      "    packages = character()",
      "  )",
      ")"
    ),
    file.path(project, "_targets.R")
  )
  shared_test_make(project)
  expect_identical(unname(shared_test_read(project, "result")), c(2L, 4L))
})()

# file targets reuse complete cache-owned bundles across stores
(function() {
  cache <- tempfile("tarshare-cache-")
  first <- tempfile("tarshare-project-")
  second <- tempfile("tarshare-project-")
  dir.create(first)
  dir.create(second)
  on.exit(unlink(c(cache, first, second), recursive = TRUE))
  write_project <- function(project, name) {
    writeLines(
      c(
        paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
        "write_bundle <- function(x) {",
        "  cat('run\\n', file = 'calls.log', append = TRUE)",
        "  paths <- c(tarshare::shared_path('data.txt'),",
        "    tarshare::shared_path('nested/metadata.txt'))",
        "  writeLines(as.character(x), paths[1])",
        "  writeLines('metadata', paths[2])",
        "  paths",
        "}",
        "list(",
        "  targets::tar_target(input, 3L),",
        paste0(
          "  tarshare::tar_shared(", name, ", write_bundle(input), cache, ",
          "format = 'file', packages = character())"
        ),
        ")"
      ),
      file.path(project, "_targets.R")
    )
  }
  write_project(first, "result")
  write_project(second, "renamed")
  shared_test_make(first)
  paths <- shared_test_read(first, "result")
  expect_length(paths, 2L)
  expect_true(all(file.exists(paths)))
  expect_identical(readLines(paths[1]), "3")
  expect_identical(readLines(paths[2]), "metadata")

  unlink(file.path(first, "_targets"), recursive = TRUE)
  expect_true(all(file.exists(paths)))
  shared_test_make(second)
  expect_identical(shared_test_read(second, "renamed"), paths)
  expect_identical(shared_test_calls(first), 1L)
  expect_identical(shared_test_calls(second), 0L)
})()

shared_test_file_identity_branches <- function(iteration) {
  cache <- tempfile("tarshare-cache-")
  first <- tempfile("tarshare-project-")
  second <- tempfile("tarshare-project-")
  dir.create(first)
  dir.create(second)
  on.exit(unlink(c(cache, first, second), recursive = TRUE))
  first_paths <- c("input-one.txt", "input-two.txt")
  second_paths <- c("relocated-one.txt", "relocated-two.txt")
  contents <- c("first", "second")
  for (i in seq_along(contents)) {
    writeLines(contents[i], file.path(first, first_paths[i]))
    writeLines(contents[i], file.path(second, second_paths[i]))
  }
  write_project <- function(project, name, paths, ids) {
    writeLines(
      c(
        paste0("cache <- tarshare::shared_cache(", deparse(cache), ")"),
        "read_input <- function(path) {",
        "  stopifnot(inherits(path, 'tarshare_file'),",
        "    length(attr(path, 'tarshare_id')) == length(path))",
        "  cat('run\\n', file = 'calls.log', append = TRUE)",
        "  readLines(path)",
        "}",
        "list(",
        paste0("  targets::tar_target(inputs, ",
               if (identical(iteration, "list")) "list(" else "c("),
        paste0(
          "    tarshare::shared_file(", deparse(paths[1]),
          ", id = ", deparse(ids[1]), "),"
        ),
        paste0(
          "    tarshare::shared_file(", deparse(paths[2]),
          ", id = ", deparse(ids[2]), ")"
        ),
        paste0("  ), iteration = ", deparse(iteration), "),"),
        paste0(
          "  tarshare::tar_shared(", name, ", read_input(inputs), cache, ",
          "pattern = map(inputs), iteration = 'list', packages = character())"
        ),
        ")"
      ),
      file.path(project, "_targets.R")
    )
  }
  ids <- c("immutable:first", "immutable:second")
  write_project(first, "result", first_paths, ids)
  write_project(second, "renamed", second_paths, ids)
  shared_test_make(first)
  shared_test_make(second)
  expect_identical(unname(shared_test_read(first, "result")), as.list(contents))
  expect_identical(unname(shared_test_read(second, "renamed")), as.list(contents))
  expect_identical(shared_test_calls(first), 2L)
  expect_identical(shared_test_calls(second), 0L)

  writeLines("first-updated", file.path(second, second_paths[1]))
  write_project(second, "renamed", second_paths,
                c("immutable:first-updated", "immutable:second"))
  shared_test_make(second)
  expect_identical(unname(shared_test_read(second, "renamed")),
                   list("first-updated", "second"))
  expect_identical(shared_test_calls(second), 1L)
}

# list branches preserve file identities across relocation and updates
(function() {
  shared_test_file_identity_branches("list")
})()

# vector branches preserve file identities across relocation and updates
(function() {
  shared_test_file_identity_branches("vector")
})()

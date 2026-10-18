# Run after installing tarshare. All data and cache entries are temporary.
library(tarshare)

example_root <- tempfile("tarshare-values-")
dir.create(example_root)
cache <- shared_cache(file.path(example_root, "cache"))

summarise_values <- function(x, cutoff) {
  message("Computing a numeric summary")
  c(mean = mean(x), fraction_above = mean(x >= cutoff))
}

values <- c(3, 5, 8, 13)
first <- shared_run(summarise_values(values, 8), cache)
second <- shared_run(summarise_values(values, 8), cache)
stopifnot(identical(first, second))

# An actual dependency change selects another result.
values <- c(3, 5, 8, 21)
changed <- shared_run(summarise_values(values, 8), cache)
stopifnot(!identical(first, changed))

# The files are known identical because this example copies one frozen fixture.
# A real input registry can provide its already verified SHA-256 as the id.
source_a <- file.path(example_root, "measurements-a.txt")
source_b <- file.path(example_root, "measurements-b.txt")
writeLines(c("3", "5", "8", "13"), source_a)
stopifnot(file.copy(source_a, source_b))
input_a <- shared_file(source_a, id = "example-measurements-1")
input_b <- shared_file(source_b, id = "example-measurements-1")

summarise_file <- function(input, cache) {
  shared_run(
    {
      message("Computing a file summary")
      x <- scan(input, quiet = TRUE)
      value <- c(n = length(x), mean = mean(x))
      rds <- shared_path("summary.rds")
      text <- shared_path("summary.txt")
      saveRDS(value, rds)
      writeLines(format(value), text)
      c(rds = rds, text = text)
    },
    cache = cache,
    format = "file"
  )
}

files_a <- summarise_file(input_a, cache)
files_b <- summarise_file(input_b, cache)
stopifnot(
  identical(files_a, files_b),
  all(file.exists(files_a)),
  identical(unname(readRDS(files_a[[1L]])), c(4, 7.25))
)

cat("Both input locations resolve to the same cached output bundle.\n")
print(files_a)
cat("Example files are under:", example_root, "\n")

# Run after installing tarshare and targets. Both stores are created afresh.
library(targets)
library(tarshare)

example_root <- tempfile("tarshare-stores-")
dir.create(example_root)
cache_path <- file.path(example_root, "cache")
counter_path <- file.path(example_root, "computations.txt")

write_pipeline <- function(path, target_name) {
  # Construct an R expression, not fragments of R source code.
  pipeline <- bquote({
    library(targets)
    library(tarshare)

    cache <- shared_cache(.(cache_path))
    counter <- .(counter_path)

    summarise_values <- function(x) {
      cat("computed\n", file = counter, append = TRUE)
      c(mean = mean(x), spread = stats::sd(x))
    }

    list(
      tar_target(values, c(3, 5, 8, 13)),
      tar_shared(.(as.name(target_name)), summarise_values(values), cache)
    )
  })
  dput(pipeline, file = path)
}

script_a <- file.path(example_root, "pipeline-a.R")
script_b <- file.path(example_root, "pipeline-b.R")
store_a <- file.path(example_root, "store-a")
store_b <- file.path(example_root, "store-b")
write_pipeline(script_a, "summary")
write_pipeline(script_b, "renamed_summary")

tar_make(script = script_a, store = store_a)
tar_make(script = script_b, store = store_b)

first <- tar_read(summary, store = store_a)
second <- tar_read(renamed_summary, store = store_b)
stopifnot(
  identical(first, second),
  identical(readLines(counter_path), "computed")
)

cat("Two fresh stores and two target names used one computation.\n")
print(first)
cat("Example files are under:", example_root, "\n")

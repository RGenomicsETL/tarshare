shared_test_file_vector <- function() {
  shared_file(c(first = tempfile(), second = tempfile()),
              id = c("content:first", "content:second"))
}

test_that("base extraction keeps paths, identities, and roles aligned", {
  x <- shared_test_file_vector()
  selected <- x[c(2L, 1L, 2L)]
  expect_s3_class(selected, "tarshare_file")
  expect_identical(as.character(selected), as.character(x)[c(2L, 1L, 2L)])
  expect_identical(attr(selected, "tarshare_id"),
                   c("content:second", "content:first", "content:second"))
  expect_identical(names(selected), c("second", "first", "second"))
  expect_identical(x[], x)
  expect_identical(x["second"], x[2L])
  expect_identical(x[-1L], x[2L])
  expect_identical(x[c(FALSE, TRUE)], x[2L])

  scalar <- x[["second"]]
  expect_s3_class(scalar, "tarshare_file")
  expect_identical(attr(scalar, "tarshare_id"), "content:second")
  expect_identical(as.character(scalar), as.character(x)[2L])
  expect_null(names(scalar))

  empty <- x[integer()]
  expect_s3_class(empty, "tarshare_file")
  expect_identical(attr(empty, "tarshare_id"), character())
  expect_length(empty, 0L)
  missing <- x[c(NA_integer_, 2L, 3L)]
  expect_identical(attr(missing, "tarshare_id"),
                   c(NA_character_, "content:second", NA_character_))
  expect_identical(is.na(as.character(missing)), c(TRUE, FALSE, TRUE))
})

test_that("concatenation requires and preserves immutable identities", {
  x <- shared_test_file_vector()
  expect_identical(c(x[1L], x[2L]), x)
  expect_identical(c(x, NULL, character()), x)
  combined <- c(group = x[2L], x[1L], use.names = TRUE)
  expect_identical(attr(combined, "tarshare_id"),
                   c("content:second", "content:first"))
  expect_identical(names(combined), c("group.second", "first"))
  expect_null(names(c(x, use.names = FALSE)))
  expect_error(c(x, "/unmarked/path"), "only shared_file")
  expect_error(c(x, list(x)), "only shared_file")
})

test_that("base replacement cannot silently retain an obsolete identity", {
  x <- shared_test_file_vector()
  expect_error(x[1L] <- "/replacement", "rebuild with shared_file")
  expect_error(x[[1L]] <- "/replacement", "rebuild with shared_file")
  expect_error(length(x) <- 1L, "rebuild with shared_file")
})

test_that("vctrs slices and combines the paired identity data", {
  x <- shared_test_file_vector()
  selected <- vctrs::vec_slice(x, c(2L, 1L, 2L))
  expect_identical(selected, x[c(2L, 1L, 2L)])
  expect_identical(vctrs::vec_slice(x, c(NA_integer_, 2L)),
                   x[c(NA_integer_, 2L)])
  expect_identical(vctrs::vec_slice(x, NA_integer_), x[NA_integer_])
  expect_identical(vctrs::vec_slice(x, integer()), x[integer()])
  expect_identical(vctrs::vec_chop(x), list(x[1L], x[2L]))
  expect_identical(vctrs::vec_restore(vctrs::vec_proxy(x), x), x)
  expect_identical(vctrs::vec_c(x[2L], x[1L]), x[2:1])

  unnamed <- shared_file(tempfile(), id = "content:third")
  combined <- vctrs::vec_c(unnamed, x)
  expect_identical(attr(combined, "tarshare_id"),
                   c("content:third", "content:first", "content:second"))
  expect_identical(names(combined), c("", "first", "second"))
  expect_null(names(vctrs::vec_slice(unnamed, 1L)))
  expect_error(vctrs::vec_c(x, "/unmarked/path"), "combine")
  expect_error(vctrs::vec_c("/unmarked/path", x), "combine")
  expect_error(vctrs::vec_cast("/unmarked/path", x), "convert")
})

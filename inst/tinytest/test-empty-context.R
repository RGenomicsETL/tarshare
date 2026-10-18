library(tarshare)

# No declared providers is an ordinary empty snapshot, not a NULL sort input.
expect_identical(tarshare:::shared_package_records(character()), list())
expect_identical(shared_context()$packages, list())

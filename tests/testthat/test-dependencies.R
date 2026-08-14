test_that("coro is declared as a hard runtime dependency", {
  description <- read.dcf(testthat::test_path("..", "..", "DESCRIPTION"))
  packages <- function(field) {
    values <- trimws(strsplit(description[1L, field], ",", fixed = TRUE)[[1L]])
    sub("\\s*\\(.*\\)$", "", values)
  }

  expect_true("coro" %in% packages("Imports"))
  expect_false("coro" %in% packages("Suggests"))
})

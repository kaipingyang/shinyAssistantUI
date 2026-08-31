test_that("coro is declared as a hard runtime dependency", {
  description_path <- testthat::test_path("..", "..", "DESCRIPTION")
  if (!file.exists(description_path)) {
    description_path <- system.file("DESCRIPTION", package = "shinyAssistantUI")
  }
  description <- read.dcf(description_path)
  packages <- function(field) {
    values <- trimws(strsplit(description[1L, field], ",", fixed = TRUE)[[1L]])
    sub("\\s*\\(.*\\)$", "", values)
  }

  expect_true("coro" %in% packages("Imports"))
  expect_false("coro" %in% packages("Suggests"))
})

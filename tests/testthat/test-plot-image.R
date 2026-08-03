# Plan 47 A4 — plot_data_uri(): capture a plot as a PNG data URI for on_image().
test_that("plot_data_uri returns a PNG data URI for base graphics", {
  skip_if_not_installed("base64enc")
  uri <- plot_data_uri(plot(1:5, 1:5))
  expect_true(is.character(uri) && length(uri) == 1L)
  expect_true(startsWith(uri, "data:image/png;base64,"))
  raw <- base64enc::base64decode(sub("^data:image/png;base64,", "", uri))
  # PNG magic number: 89 50 4E 47
  expect_identical(as.integer(raw[1:4]), c(137L, 80L, 78L, 71L))
})

test_that("plot_data_uri prints objects that only draw when printed (inherits path)", {
  skip_if_not_installed("base64enc")
  # A minimal S3 object whose print method draws — mimics ggplot/lattice (draw-on-print).
  obj <- structure(list(), class = "gg")
  registerS3method("print", "gg", function(x, ...) plot(1:3), envir = environment())
  uri <- plot_data_uri(obj)
  expect_true(startsWith(uri, "data:image/png;base64,"))
})

test_that("plot_data_uri closes the device even when the expr errors", {
  skip_if_not_installed("base64enc")
  before <- length(grDevices::dev.list())
  expect_error(plot_data_uri(stop("boom")))
  expect_identical(length(grDevices::dev.list()), before)  # no leaked device
})

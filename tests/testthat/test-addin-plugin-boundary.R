test_that("generic assistantUIServer has no copilot-specific API", {
  api <- names(formals(assistantUIServer))
  expect_false(any(c(
    "auto_start_copilot_api",
    "on_toggle_auto_start_copilot_api",
    "service_status",
    "on_retry_service"
  ) %in% api))

  controls <- NULL
  handler <- function(message, on_chunk, on_done, on_error) NULL
  attr(handler, "ui_addons") <- list(
    fixture = list(version = 1L, value = "opaque")
  )

  shiny::testServer(function(input, output, session) {
    controls <<- assistantUIServer("chat", handler = handler)
  }, {
    expect_false("send_service_status" %in% names(controls))
    rendered <- session$getOutput("chat")
    expect_identical(
      rendered$config$addons,
      list(fixture = list(version = 1L, value = "opaque"))
    )
  })
})

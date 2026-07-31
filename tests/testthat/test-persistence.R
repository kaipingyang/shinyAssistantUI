test_that("assistantUIServer sends explicit persistence in the initial config", {
  handler <- function(...) NULL

  for (mode in c("client", "server", "none")) {
    shiny::testServer(function(input, output, session) {
      assistantUIServer("chat", handler = handler, persistence = mode)
    }, {
      expect_identical(widget_config(output$chat)$persistence, mode)
    })
  }
})

test_that("assistantUIServer defaults persistence to client", {
  handler <- function(...) NULL

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    expect_identical(widget_config(output$chat)$persistence, "client")
  })
})

test_that("assistantUIServer rejects unsupported persistence modes", {
  handler <- function(...) NULL

  expect_error(
    shiny::testServer(function(input, output, session) {
      assistantUIServer("chat", handler = handler, persistence = "browser")
    }),
    "persistence"
  )
})

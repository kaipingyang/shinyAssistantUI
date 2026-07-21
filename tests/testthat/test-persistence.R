test_that("assistantUIServer sends explicit persistence in the initial config", {
  handler <- function(...) NULL

  for (mode in c("client", "server", "none")) {
    shiny::testServer(function(input, output, session) {
      assistantUIServer("chat", handler = handler, persistence = mode)
    }, {
      widget <- jsonlite::fromJSON(output$chat, simplifyVector = FALSE)
      expect_identical(widget$x$config$persistence, mode)
    })
  }
})

test_that("assistantUIServer defaults persistence to client", {
  handler <- function(...) NULL

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    widget <- jsonlite::fromJSON(output$chat, simplifyVector = FALSE)
    expect_identical(widget$x$config$persistence, "client")
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

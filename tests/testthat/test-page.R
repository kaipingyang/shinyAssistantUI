test_that("assistantUIPage creates a dedicated full-height assistant page", {
  page <- assistantUIPage(
    assistantUIOutput("chat", height = "100%"),
    title = "Chat <safe>",
    padding = "8px"
  )
  rendered <- htmltools::renderTags(page)
  html <- rendered$html
  document <- paste(rendered$head, rendered$html, sep = "\n")
  deps <- rendered$dependencies

  body <- page[[2L]]
  expect_s3_class(page, "shiny.tag.list")
  expect_s3_class(body, "shiny.tag")
  expect_identical(body$name, "body")
  expect_match(html, 'class="aui-page html-fill-container"', fixed = TRUE)
  expect_match(document, '<meta name="viewport"', fixed = TRUE)
  expect_match(document, "<title>Chat &lt;safe&gt;</title>", fixed = TRUE)
  expect_match(document, "body.aui-page", fixed = TRUE)
  expect_match(document, "padding: 8px", fixed = TRUE)
  expect_match(html, 'id="chat"', fixed = TRUE)
  expect_match(html, "height:100%", fixed = TRUE)
  expect_true("htmltools-fill" %in% vapply(deps, `[[`, character(1), "name"))
})

test_that("assistantUIPage suppresses descendant Bootstrap by default", {
  page <- assistantUIPage(
    shiny::bootstrapPage(shiny::div("content"))
  )
  deps <- htmltools::renderTags(page)$dependencies
  bootstrap <- Filter(function(x) identical(x$name, "bootstrap"), deps)

  expect_length(bootstrap, 1L)
  expect_identical(bootstrap[[1L]]$version, "9999")
  expect_null(bootstrap[[1L]]$stylesheet)
  expect_null(bootstrap[[1L]]$script)
})

test_that("assistantUIPage can preserve an explicitly requested Bootstrap dependency", {
  page <- assistantUIPage(
    shiny::bootstrapPage(shiny::div("content")),
    suppress_bootstrap = FALSE
  )
  deps <- htmltools::renderTags(page)$dependencies
  bootstrap <- Filter(function(x) identical(x$name, "bootstrap"), deps)

  expect_length(bootstrap, 1L)
  expect_false(identical(bootstrap[[1L]]$version, "9999"))
  expect_true(length(bootstrap[[1L]]$stylesheet) > 0L)
})

test_that("assistantUIPage omits title when it is NULL and validates padding", {
  page <- assistantUIPage(shiny::div("content"))
  expect_false(grepl("<title>", htmltools::renderTags(page)$html, fixed = TRUE))
  expect_error(assistantUIPage(padding = c("1px", "2px")), "single")
  expect_error(assistantUIPage(padding = NA_character_), "padding")
})

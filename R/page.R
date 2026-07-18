#' Create a standalone assistant UI page
#'
#' Creates a full-height Shiny page for assistant-ui widgets. The page adds an
#' `aui-page` body class, establishes the `html`/`body` height chain, and
#' suppresses Bootstrap by default so its global styles do not override the
#' widget's Tailwind/shadcn styles.
#'
#' Use this for a standalone assistant application. When embedding
#' [assistantUIOutput()] in an existing `bslib` or Bootstrap page, use that
#' page's layout functions instead.
#'
#' @param ... Contents of the document body. Typically one
#'   `assistantUIOutput("chat", height = "100%")`.
#' @param title Optional browser page title.
#' @param padding CSS padding applied to the page body. Must be a single CSS
#'   unit; defaults to `0`.
#' @param suppress_bootstrap Logical. If `TRUE` (the default), suppress any
#'   Bootstrap dependency contributed by descendants. Set to `FALSE` only when
#'   the page intentionally combines assistant-ui with Bootstrap components.
#'
#' @return An HTML tag list suitable for the `ui` argument of [shiny::shinyApp()].
#' @export
#'
#' @examples
#' assistantUIPage(
#'   assistantUIOutput("chat", height = "100%")
#' )
assistantUIPage <- function(..., title = NULL, padding = 0,
                            suppress_bootstrap = TRUE) {
  if (length(padding) != 1L || is.na(padding)) {
    stop("`padding` must be a single, non-missing CSS unit.", call. = FALSE)
  }
  padding <- htmltools::validateCssUnit(padding)

  if (!is.null(title) && (!is.character(title) || length(title) != 1L || is.na(title))) {
    stop("`title` must be NULL or a single, non-missing string.", call. = FALSE)
  }
  if (!is.logical(suppress_bootstrap) || length(suppress_bootstrap) != 1L ||
      is.na(suppress_bootstrap)) {
    stop("`suppress_bootstrap` must be TRUE or FALSE.", call. = FALSE)
  }

  page_head <- shiny::tags$head(
    shiny::tags$meta(
      name = "viewport",
      content = "width=device-width, initial-scale=1"
    ),
    if (!is.null(title)) shiny::tags$title(title),
    shiny::tags$style(shiny::HTML(sprintf(
      paste0(
        "html { width: 100%%; height: 100%%; overflow: hidden; }\n",
        "body.aui-page { width: 100%%; height: 100%%; margin: 0; ",
        "padding: %s; overflow: hidden; box-sizing: border-box; }\n",
        "body.aui-page > .assistantUI { min-height: 0 !important; }"
      ),
      padding
    )))
  )

  page_body <- shiny::tags$body(
    class = "aui-page",
    if (isTRUE(suppress_bootstrap)) htmltools::suppressDependencies("bootstrap"),
    ...
  )
  page_body <- htmltools::bindFillRole(page_body, container = TRUE)

  htmltools::tagList(page_head, page_body)
}

#' AI Assistant Chat UI Output
#'
#' Creates an htmlwidget output placeholder for the assistant UI chat component.
#'
#' @param outputId Output variable to read from.
#' @param width,height Width and height of the widget (CSS values).
#' @param modal Logical. If `TRUE`, sizes the widget for floating modal use.
#' @param ... Additional arguments passed to [htmlwidgets::shinyWidgetOutput()].
#'
#' @return An HTML output element.
#' @export
assistantUIOutput <- function(outputId, width = "100%", height = "600px",
                              modal = FALSE, ...) {
  if (modal) {
    width  <- "auto"
    height <- "auto"
  }
  htmlwidgets::shinyWidgetOutput(
    outputId  = outputId,
    name      = "assistantUI",
    width     = width,
    height    = height,
    package   = "shinyAssistantUI",
    ...
  )
}

#' Render an Assistant UI Widget
#'
#' Server-side render function for [assistantUIOutput()]. Typically used inside
#' [assistantUIServer()] rather than called directly.
#'
#' @param config Optional named list of configuration options.
#' @param outputId The output ID used in [assistantUIOutput()].  The widget
#'   uses this to derive the Shiny input name that carries user messages.
#'
#' @return A render function suitable for assigning to `output[[outputId]]`.
#' @export
renderAssistantUI <- function(config = list(), outputId = NULL) {
  force(outputId)
  force(config)
  # Plan 34 (fix): 当 latex 开启时,附加本地 KaTeX 依赖(css + woff2 字体从包内 www/katex 提供,
  # 非 CDN)——消除字体异步加载导致的公式"忽大忽小"重排,且离线可用。
  katex_dep <- if (isTRUE(config$latex)) {
    list(htmltools::htmlDependency(
      name       = "katex",
      version    = "0.16.47",
      src        = c(file = system.file("www/katex", package = "shinyAssistantUI")),
      stylesheet = "katex.min.css"
    ))
  } else NULL
  # bquote 将 outputId / config 的值直接内联进表达式，
  # 避免通过 env 传递自由变量（shinyRenderWidget 内部 cacheHint="auto"
  # 会检索 env 里的 id，导致 "object 'id' not found" 错误）。
  expr <- bquote(
    htmlwidgets::createWidget(
      name    = "assistantUI",
      x       = list(
        inputId = paste0(.(outputId), "_input"),
        config  = .(config)
      ),
      package = "shinyAssistantUI",
      dependencies = .(katex_dep)
    )
  )
  htmlwidgets::shinyRenderWidget(expr, assistantUIOutput, baseenv(), quoted = TRUE)
}

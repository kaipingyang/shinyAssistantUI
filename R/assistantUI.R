#' AI Assistant Chat UI Output
#'
#' Creates a Shiny output placeholder for the assistant UI chat component.
#'
#' The component is a native Shiny output binding (not an htmlwidget): a plain
#' `<div class="assistantUI assistantUI-output">` plus an [htmltools::htmlDependency()]
#' that provides the bundled JS/CSS. The React app mounts into the div when the
#' server sends its value via [renderAssistantUI()]; all streaming/interaction
#' then flows over `session$sendCustomMessage()` and `Shiny.setInputValue()`.
#'
#' @param outputId Output variable to read from.
#' @param width,height Width and height of the widget (CSS values).
#' @param modal Logical. If `TRUE`, sizes the widget for floating modal use.
#' @param ... Additional attributes passed to the container `<div>`.
#'
#' @return An HTML output element with its JS/CSS dependency attached.
#' @export
assistantUIOutput <- function(outputId, width = "100%", height = "600px",
                              modal = FALSE, ...) {
  if (modal) {
    width  <- "auto"
    height <- "auto"
  }
  htmltools::attachDependencies(
    shiny::tags$div(
      id    = outputId,
      class = "assistantUI assistantUI-output",
      style = htmltools::css(
        width  = htmltools::validateCssUnit(width),
        height = htmltools::validateCssUnit(height)
      ),
      ...
    ),
    # KaTeX 依赖无条件附加:CSS 惰性(无 .katex 元素时浏览器不取字体),config$latex
    # 仍在前端门禁 remark-math/rehype-katex,故 latex 关时公式不渲染、字体零成本。
    list(.assistantui_dependency(), .katex_dependency())
  )
}

# 组件 JS/CSS 依赖(bundle 产物在 inst/www/)。version 取构建期写入的 widget 版本
# (时间戳,做缓存击穿),取不到则回落包版本。
.assistantui_widget_version <- function() {
  yaml <- system.file("htmlwidgets", "assistantUI.yaml", package = "shinyAssistantUI")
  v <- NULL
  if (nzchar(yaml)) {
    v <- tryCatch({
      line <- grep("version:", readLines(yaml, warn = FALSE), value = TRUE)[1]
      if (!is.na(line)) trimws(sub(".*version:", "", line)) else NULL
    }, error = function(e) NULL)
  }
  if (is.null(v) || !nzchar(v)) v <- as.character(utils::packageVersion("shinyAssistantUI"))
  v
}

.assistantui_dependency <- function() {
  htmltools::htmlDependency(
    name       = "shinyAssistantUI",
    version    = .assistantui_widget_version(),
    src        = c(file = system.file("www", package = "shinyAssistantUI")),
    script     = "shinyAssistantUI.js",
    stylesheet = "style.css"
  )
}

.katex_dependency <- function() {
  htmltools::htmlDependency(
    name       = "katex",
    version    = "0.16.47",
    src        = c(file = system.file("www/katex", package = "shinyAssistantUI")),
    stylesheet = "katex.min.css"
  )
}

#' Render an Assistant UI Widget
#'
#' Server-side render function for [assistantUIOutput()]. Typically used inside
#' [assistantUIServer()] rather than called directly. Sends `{inputId, config}`
#' to the client-side output binding, which mounts the React app.
#'
#' @param config Optional named list of configuration options.
#' @param outputId The output ID used in [assistantUIOutput()]. The widget
#'   uses this to derive the Shiny input name that carries user messages.
#'
#' @return A render function suitable for assigning to `output[[outputId]]`.
#' @export
renderAssistantUI <- function(config = list(), outputId = NULL) {
  force(config)
  force(outputId)
  shiny::createRenderFunction(
    function() {
      list(inputId = paste0(outputId, "_input"), config = config)
    },
    transform = function(value, session, name, ...) value,
    outputFunc = assistantUIOutput,
    outputArgs = list()
  )
}

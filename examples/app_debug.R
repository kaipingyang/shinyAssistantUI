library(shiny)
devtools::load_all(here::here())

ui <- fluidPage(
  tags$h3("Debug: 诊断每一层"),

  # 层1: 纯 uiOutput (最基础的 Shiny 输出)
  tags$h4("层1: uiOutput (基础Shiny)"),
  uiOutput("test_ui"),

  # 层2: htmlwidgets 内置 sample widget (排除包本身的问题)
  # tags$h4("层2: assistantUIOutput"),
  assistantUIOutput("chat", height = "60vh"),

  tags$hr(),
  # 调试信息
  verbatimTextOutput("debug_info")
)

server <- function(input, output, session) {

  # 捕获所有错误
  tryCatch({

    # 层1: 最基础的 renderUI
    output[["test_ui"]] <- renderUI({
      tags$p("✓ uiOutput 正常工作", style="color:green;font-weight:bold;")
    })

    # 层2: renderAssistantUI
    output[["chat"]] <- renderAssistantUI(config = list(), outputId = "chat")

    output[["debug_info"]] <- renderText({
      paste0(
        "output class: ", paste(class(output), collapse=", "), "\n",
        "session$output is output: ", identical(output, session$output), "\n",
        "getDefaultReactiveDomain() class: ",
           paste(class(shiny::getDefaultReactiveDomain()), collapse=", "), "\n",
        "All registrations succeeded!"
      )
    })

  }, error = function(e) {
    # 如果上面任何一行报错，这里会捕获
    msg <- paste("SERVER ERROR:", conditionMessage(e), "\n",
                 "call:", deparse(e$call))
    cat(msg, "\n")  # 打印到 R console
    output[["debug_info"]] <- renderText(msg)
  })

  observeEvent(input[["chat_input"]], {
    msg <- input[["chat_input"]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()
    session$sendCustomMessage("chat_input:chunk", list(text = paste0("回声: ", msg$text, " ")))
    session$sendCustomMessage("chat_input:done", list())
  }, ignoreNULL = TRUE, ignoreInit = TRUE)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

shinyApp(ui, server)

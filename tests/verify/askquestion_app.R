# Fixture:验证 AskUserQuestion 交互卡 UI→答案回传路径(自定义 handler,不需真 CLI)。
library(shiny)
library(shinyAssistantUI)
library(coro)
`%||%` <- function(x, y) if (is.null(x)) y else x

qs <- list(
  list(question = "Fav color?", header = "Color", multiSelect = FALSE,
       options = list(list(label = "Red"), list(label = "Blue"))),
  list(question = "Which langs?", header = "Langs", multiSelect = TRUE,
       options = list(list(label = "R"), list(label = "Python")))
)

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                on_tool_result, wait_for_approval,
                                on_tool_call_start, on_tool_call_delta, ...) {
  tcid <- paste0("ask-", as.integer(Sys.time()), "-", sample.int(1e6, 1))
  on_chunk("asking...\n")
  args <- list(questions = qs)
  args_json <- as.character(jsonlite::toJSON(args, auto_unbox = TRUE))
  on_tool_call_start(tcid, "AskUserQuestion", annotations = list())
  cut <- max(1L, floor(nchar(args_json) / 3L))
  starts <- seq.int(1L, nchar(args_json), by = cut)
  for (start in starts) {
    on_tool_call_delta(tcid, substr(args_json, start, min(nchar(args_json), start + cut - 1L)))
  }
  # 留出一个浏览器绘制周期，确保测试真实经过stream shell再进入审批态。
  await(promises::promise(function(resolve, reject) {
    later::later(function() resolve(NULL), delay = 0.25)
  }))
  on_tool_call(tcid, "AskUserQuestion", args,
               annotations = list(requiresApproval = TRUE, defaultOpen = TRUE))
  decision <- await(wait_for_approval(tcid))
  decrec(as.character(jsonlite::toJSON(decision$answers %||% NA, auto_unbox = TRUE)))
  on_tool_result(
    tcid,
    paste(sprintf("answer result line %03d", seq_len(160)), collapse = "\n"),
    is_error = FALSE
  )
  on_chunk("done"); on_done()
})

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "70vh")),
  verbatimTextOutput("decision")
)
server <- function(input, output, session) {
  decrec <<- reactiveVal(NULL)
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      args <- list(
        questions = qs,
        answers = list("Fav color?" = "Teal", "Which langs?" = c("R", "SQL"))
      )
      send_thread(messages = list(
        list(id = "hist-ask-u", role = "user",
             content = list(list(type = "text", text = "Historical AskUserQuestion"))),
        list(id = "hist-ask-a", role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(
               list(type = "tool-call", toolCallId = "hist-ask-tool",
                    toolName = "AskUserQuestion", args = args,
                    argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
                    result = "Answers submitted", isError = FALSE,
                    artifact = list(defaultOpen = TRUE, approvalResult = "approved")),
               list(type = "text", text = "Historical answers restored")
             ))
      ), has_more = FALSE)
    }
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "ask-history", title = "Ask history",
           preview = "Historical AskUserQuestion", createdAt = as.numeric(Sys.time()) * 1000)
    )))
  }, once = TRUE)
  output$decision <- renderText(decrec() %||% "none")
}
shinyApp(ui, server)

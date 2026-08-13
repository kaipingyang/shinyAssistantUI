library(shiny)
library(bslib)
library(promises)
library(shinyAssistantUI)

# 忠实复现 addin(Claude 路径)的时序：工具先 on_tool_call_start(折叠挂载)，
# 之后才带 requiresApproval（合并同一张卡）。并发两个工具 + 一段长回复。
repro_handler <- function(message, thread_id, on_chunk, on_done,
                          on_tool_call, on_tool_result, on_tool_call_start,
                          on_tool_call_delta, wait_for_approval, on_task = NULL, ...) {
  if (grepl("stucktask", message, fixed = TRUE)) {
    # 两个并行 background task：每个都必须有独立大卡/Stop，且只能由自己的
    # SDK terminal event 移出。第一项在 turn 内完成并成为 latest activity；
    # 第二项跨越 on_done 后仍保持 active，稍后收到 killed 才消失。
    if (!is.null(on_task)) {
      on_task("task-read", "started", description = "Inspect repository",
              status = "running", tool_name = "Read")
      on_task("task-tests", "started", description = "Run test suite",
              status = "running", tool_name = "Bash")
    }
    on_tool_call("gate-tool", "Bash",
                 args = list(command = "ls"),
                 annotations = list(requiresApproval = TRUE, title = "finish run"))
    promises::then(wait_for_approval("gate-tool"), function(d) {
      on_tool_result("gate-tool", "ok", is_error = FALSE)
      if (!is.null(on_task))
        on_task("task-read", "notification", description = "Inspect repository",
                status = "completed", tool_name = "Read")
      later::later(function() {
        on_chunk("background turn done")
        on_done()
        later::later(function() {
          if (!is.null(on_task))
            on_task("task-tests", "updated", description = "Run test suite",
                    status = "killed", tool_name = "Bash")
        }, 1.5)
      }, 0.7)
    })
    return(invisible(NULL))
  }
  if (grepl("editdiff", message, fixed = TRUE)) {
    # Edit 工具 → 工具卡应自动渲染 git 式 diff（old_string→new_string）
    on_tool_call("edit-1", "Edit",
                 args = list(file_path = "/tmp/demo.R",
                             old_string = "x <- 1\nprint(x)",
                             new_string = "x <- 2\nprint(x)"),
                 annotations = list(icon = "pencil", defaultOpen = TRUE))
    on_tool_result("edit-1", "ok", is_error = FALSE)
    on_chunk("done")
    on_done()
    return(invisible(NULL))
  }
  if (grepl("diffblock", message, fixed = TRUE)) {
    # 手动打印的 ```diff 块（裸 +/- 无 hunk 头）应上色为红绿
    on_chunk("Diff:\n\n```diff\n- x <- 1\n+ x <- 2\n```\n")
    on_done()
    return(invisible(NULL))
  }
  if (grepl("codeblock", message, fixed = TRUE)) {
    # 裸 ``` 代码块（无语言标签）→ assistant-ui 记为 "unknown" → 期望本 addin 按 R 处理
    on_chunk("Here is some code:\n\n```\nx <- 1\nprint(x)\n```\n")
    on_done()
    return(invisible(NULL))
  }
  if (grepl("slow scroll", message, fixed = TRUE)) {
    # 在第20行停顿，让浏览器产生稳定scrollHeight；验证用户此时主动上滚后，
    # 后续chunk不会被auto-follow强拉回底部。
    i <- 0L
    emit <- function() {
      i <<- i + 1L
      on_chunk(sprintf("Slow line %03d: streaming content for user-scroll verification.\n", i))
      if (i >= 80L) {
        on_done()
      } else {
        later::later(emit, if (i == 20L) 1.5 else 0.03)
      }
    }
    emit()
    return(invisible(NULL))
  }
  if (grepl("scroll", message, fixed = TRUE)) {
    # 问题1：流式一段远超视口高度的长回复（逐块，模拟 token 流）
    for (i in 1:120) on_chunk(sprintf("Line %03d: the quick brown fox jumps over the lazy dog and keeps typing.\n", i))
    on_done()
    return(invisible(NULL))
  }
  # 问题2：忠实串行——先只发工具 A(start→delta→requiresApproval)，等它审批解决后才发工具 B。
  on_tool_call_start("tool-write", "Write", annotations = list(icon = "pencil"))
  if (!is.null(on_tool_call_delta)) {
    on_tool_call_delta("tool-write", '{"file_path":"/tmp/te')
    Sys.sleep(0.1)
    on_tool_call_delta("tool-write", 'st.R","content":"print(1)"}')
  }
  Sys.sleep(0.15)
  on_tool_call("tool-write", "Write",
               args = list(file_path = "/tmp/test.R", content = "print(1)"),
               annotations = list(requiresApproval = TRUE, title = "Write /tmp/test.R"))
  promises::then(wait_for_approval("tool-write"), function(dw) {
    on_tool_result("tool-write", "written", is_error = FALSE)
    # A 解决后才出现 B —— 与真实 Claude 循环 coro::await 串行一致
    on_tool_call_start("tool-bash", "Bash", annotations = list(icon = "terminal"))
    if (!is.null(on_tool_call_delta)) on_tool_call_delta("tool-bash", '{"command":"Rscript /tmp/test.R"}')
    Sys.sleep(0.15)
    on_tool_call("tool-bash", "Bash",
                 args = list(command = "Rscript /tmp/test.R"),
                 annotations = list(requiresApproval = TRUE, title = "Run Rscript /tmp/test.R"))
    promises::then(wait_for_approval("tool-bash"), function(db) {
      on_tool_result("tool-bash", "1", is_error = FALSE)
      on_chunk("done")
      on_done()
    })
  })
}

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  assistantUIOutput("chat", height = "100vh")
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = repro_handler, show_thread_list = TRUE)
}
shinyApp(ui, server)

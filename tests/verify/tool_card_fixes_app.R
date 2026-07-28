# Fixture:验证 ③ Edit 标题(不再 Edit(false))+ ④ diff 真实行号(从文件真实行,非 1)。
library(shiny)
library(shinyAssistantUI)

# 真实文件:old_string 落在第 4 行。server 会算出 diffStartLine=4。
tmp <- file.path(tempdir(), "edit_target_demo.R")
writeLines(c(
  "# header line 1",
  "# line 2",
  "# line 3",
  "old_target <- 1",
  "# line 5"
), tmp)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  on_chunk("editing:\n")
  # ③ 复现:布尔字段 replace_all 放首位(旧逻辑会把标题显示成 Edit(false))。
  # ④ old_string 在第 4 行 → diff 应显示行号 4。
  on_tool_call(
    "e1", "Edit",
    list(replace_all = FALSE, file_path = tmp,
         old_string = "old_target <- 1", new_string = "old_target <- 2"),
    annotations = list(defaultOpen = TRUE)
  )
  on_tool_result("e1", "ok", is_error = FALSE)
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "82vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)

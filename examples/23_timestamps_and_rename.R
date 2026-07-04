library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── 消息时间戳 + 线程重命名示例 ───────────────────────────────────────────────
# show_timestamps = TRUE 让每条消息显示发送时间(HH:MM)。
# show_thread_list = TRUE 后,侧边栏线程项的 "…" 菜单里有 Rename;
# on_rename 回调可用于把新标题同步到服务端 session 存储。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("You said:", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.03) }
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo,
    show_timestamps  = TRUE,
    show_thread_list = TRUE,
    on_rename = function(thread_id, title) {
      message(sprintf("[rename] %s -> %s", thread_id, title))
    }
  )
}
shinyApp(ui, server)

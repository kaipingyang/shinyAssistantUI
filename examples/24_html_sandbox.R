library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── HTML 工具结果沙箱示例 ─────────────────────────────────────────────────────
# resultType = "html" 的工具结果默认渲染进 sandbox='' 的 iframe(无脚本、无同源),
# 隔离不可信 HTML(如网页抓取内容),杜绝 XSS。
# annotations$htmlSandbox = FALSE 可 opt-out(仅用于可信、需 Shiny 绑定的交互 HTML)。

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  on_tool_call("fetch-1", "web_fetch",
               args = list(url = "https://example.com"),
               annotations = list(title = "web_fetch", resultType = "html", resultHeight = 180))
  # 含 <script> 的不可信 HTML —— 沙箱会阻断脚本执行
  html <- paste0(
    "<div style='font-family:sans-serif;padding:8px'>",
    "<h3>Fetched Page</h3><p>This HTML came from an untrusted source.</p>",
    "<script>document.body.innerHTML='HACKED';</script></div>"
  )
  on_tool_result("fetch-1", html, is_error = FALSE)
  on_chunk("Fetched and rendered the page safely in a sandbox. ")
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = handler,
    suggestions = list(list(prompt = "Fetch example.com", text = "Fetch a page"))
  )
}
shinyApp(ui, server)

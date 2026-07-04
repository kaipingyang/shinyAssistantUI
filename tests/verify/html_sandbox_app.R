library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# handler:发一个 html 工具结果(含 <script> 试图写 window.__pwned__ 证明被沙箱阻断)
h <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  on_tool_call("html-1", "render_report",
               args = list(topic = "x"),
               annotations = list(title = "render_report", resultType = "html"))
  html <- "<div id='reportbox' style='color:teal'>Sandboxed Report OK</div><script>window.parent.__pwned__=true;</script>"
  on_tool_result("html-1", html, is_error = FALSE)
  on_chunk("done")
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) assistantUIServer("chat", handler = h)
shinyApp(ui, server)

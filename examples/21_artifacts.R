library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Artifacts 侧面板示例 ──────────────────────────────────────────────────────
# handler 用 on_artifact(id, title, content, type, lang) 在右侧面板展示文档/代码/HTML。
# type ∈ "markdown" | "code" | "html" | "text"。同 id 再次调用 = 更新(增量编辑)。

handler <- function(message, on_chunk, on_done, on_artifact, ...) {
  msg <- tolower(message)
  if (grepl("code|function|script", msg)) {
    on_chunk("Here's a function — see the panel on the right. ")
    on_artifact(
      id = "code-1", title = "fib.R", type = "code", lang = "r",
      content = "fib <- function(n) {\n  if (n < 2) return(n)\n  fib(n - 1) + fib(n - 2)\n}\n\nsapply(0:10, fib)"
    )
  } else if (grepl("html|chart|plot", msg)) {
    on_chunk("Rendered an HTML preview (sandboxed) on the right. ")
    on_artifact(
      id = "html-1", title = "Preview", type = "html",
      content = "<h2 style='font-family:sans-serif'>Sales Report</h2><p>Q3 revenue up 24%.</p><progress value='0.74'></progress>"
    )
  } else {
    on_chunk("I've drafted a document — open on the right. ")
    on_artifact(
      id = "doc-1", title = "Project Plan", type = "markdown",
      content = "# Project Plan\n\n1. **Research** — 2 weeks\n2. **Build** — 4 weeks\n3. **Ship** — 1 week\n\n> Deadline: end of Q3"
    )
  }
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = handler,
    suggestions = list(
      list(prompt = "Draft a project plan", text = "Draft a plan (markdown)"),
      list(prompt = "Write a code artifact", text = "Code artifact"),
      list(prompt = "Show an html preview", text = "HTML artifact")
    )
  )
}
shinyApp(ui, server)

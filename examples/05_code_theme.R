library(shiny)
library(bslib)
devtools::load_all(here::here())

# 测试 code_theme 参数。
# 从 URL query string 读取主题（?theme=dracula），
# 切换主题时更新 URL 并重载页面。
# 打开 app 后在地址栏末尾加 ?theme=<名称> 来切换。
#
# 可用主题：
#   浅色：one-light（默认）、ghcolors、vs、solarized-light
#   深色：vsc-dark-plus、dracula、nord、night-owl、one-dark

VALID_THEMES <- c(
  "one-light", "ghcolors", "vs", "solarized-light",
  "vsc-dark-plus", "dracula", "nord", "night-owl", "one-dark"
)

DEMO_REPLY <- paste0(
  "以下是几段代码示例，测试语法高亮：\n\n",
  "### R\n",
  "```r\n",
  "df <- read.csv(\"data.csv\")\n",
  "fit <- lm(y ~ x1 + x2, data = df)\n",
  "summary(fit)\n",
  "```\n\n",
  "### Python\n",
  "```python\n",
  "import pandas as pd\n",
  "df = pd.read_csv('data.csv')\n",
  "from sklearn.linear_model import LinearRegression\n",
  "model = LinearRegression().fit(df[['x1','x2']], df['y'])\n",
  "print(model.coef_)\n",
  "```\n\n",
  "### SQL\n",
  "```sql\n",
  "SELECT user_id, COUNT(*) AS n, SUM(amount) AS revenue\n",
  "FROM orders\n",
  "WHERE created_at >= '2024-01-01'\n",
  "GROUP BY user_id\n",
  "ORDER BY revenue DESC;\n",
  "```\n\n",
  "### Bash\n",
  "```bash\n",
  "for f in *.csv; do\n",
  "  mv \"$f\" \"${f%.csv}_backup.csv\"\n",
  "done\n",
  "```\n"
)

ui <- page_fluid(
  h3("code_theme 参数测试"),
  layout_columns(
    col_widths = c(3, 9),
    card(
      selectInput("theme_select", "切换主题（点 Apply 重载）",
                  choices  = setNames(VALID_THEMES, VALID_THEMES),
                  selected = "one-light"),
      actionButton("apply_theme", "Apply theme", class = "btn-primary"),
      p(tags$small(
        "发送任意消息，assistant 会回复包含 R / Python / SQL / Bash 代码块的示例。"
      ))
    ),
    assistantUIOutput("chat", height = "80vh")
  )
)

server <- function(input, output, session) {
  # 从 URL query string 读取主题，默认 one-light
  theme <- local({
    qs <- shiny::parseQueryString(isolate(session$clientData$url_search))
    t  <- qs[["theme"]] %||% "one-light"
    if (!t %in% VALID_THEMES) "one-light" else t
  })

  # 初始化 selectInput 的选中值与 URL 保持一致
  updateSelectInput(session, "theme_select", selected = theme)

  # 切换主题：更新 URL query string 并重载页面
  observeEvent(input$apply_theme, {
    session$sendCustomMessage("__reload_with_theme__",
                              list(theme = input$theme_select))
  })

  # 注入一段 JS，监听 reload 消息并跳转
  insertUI("head", "beforeEnd", immediate = TRUE,
    tags$script(HTML(
      "Shiny.addCustomMessageHandler('__reload_with_theme__', function(msg) {",
      "  window.location.search = '?theme=' + encodeURIComponent(msg.theme);",
      "});"
    ))
  )

  assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, ...) {
      lines <- strsplit(DEMO_REPLY, "\n")[[1]]
      for (line in lines) {
        on_chunk(paste0(line, "\n"))
        Sys.sleep(0.005)
      }
      on_done()
    },
    code_theme = theme
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

shinyApp(ui, server)

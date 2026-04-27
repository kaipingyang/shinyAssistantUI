# 测试 rich tool result 渲染
# 不需要 LLM API key，handler 直接 mock 工具调用
# 运行：devtools::load_all(); shiny::runApp("examples/test_rich_results.R")
#
# 触发关键词：
#   "table"    → 渲染数据表（TableResult）
#   "markdown" → 渲染 markdown（SimpleMarkdown）
#   "code"     → 渲染语法高亮代码（PrismLight）
#   "image"    → 渲染图片（<img>）
#   "file"     → 渲染下载按钮（CSV data URL）
#   "html"     → 渲染 HTML 字符串（dangerouslySetInnerHTML）
#   其他       → 普通 auto 渲染（<pre>）

library(shiny)
library(promises)
library(jsonlite)
devtools::load_all(here::here())

handler <- coro::async(function(
  message, thread_id, on_chunk, on_done, on_error,
  on_tool_call, on_tool_result
) {
  msg <- tolower(trimws(message))
  # 每次调用生成唯一 ID，避免同一 thread 重复发相同类型请求时 ID 碰撞
  rid <- paste0(format(Sys.time(), "%s"), sample(1000:9999, 1))

  if (grepl("table", msg)) {
    # ── table：JSON 数组，JS 渲染为 HTML 表格 ──────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Running a query... ")
    on_tool_call(
      paste0("tc-table-", rid), "query_patients",
      args        = list(filter = "age > 30", limit = 5),
      annotations = list(
        icon       = "database",
        title      = "Query: patients",
        resultType = "table"
      )
    )
    Sys.sleep(0.5)
    df <- data.frame(
      USUBJID   = paste0("SUBJ-00", 1:5),
      AGE       = c(34L, 45L, 52L, 38L, 61L),
      SEX       = c("M", "F", "M", "F", "M"),
      TRTA      = c("Drug A", "Placebo", "Drug A", "Drug A", "Placebo"),
      AVAL      = round(c(12.3, 8.7, 15.1, 11.9, 9.4), 1)
    )
    on_tool_result(paste0("tc-table-", rid), jsonlite::toJSON(df, auto_unbox = FALSE))
    on_chunk("Here is the query result rendered as a table.")

  } else if (grepl("markdown", msg)) {
    # ── markdown：渲染格式化文本 ───────────────────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Generating a markdown report... ")
    on_tool_call(
      paste0("tc-md-", rid), "generate_report",
      args        = list(topic = "clinical summary"),
      annotations = list(
        icon       = "code",
        title      = "Report Generator",
        resultType = "markdown"
      )
    )
    Sys.sleep(0.4)
    md_result <- paste0(
      "## Clinical Summary\n\n",
      "**Study**: Phase III, randomized, double-blind\n\n",
      "### Key Findings\n\n",
      "- Primary endpoint **met** (p < 0.001)\n",
      "- Response rate: *42%* vs *18%* in placebo\n",
      "- Median OS: `14.2 months` vs `9.8 months`\n\n",
      "### Safety\n\n",
      "No unexpected safety signals. Most common AEs:\n\n",
      "1. Nausea (23%)\n",
      "2. Fatigue (18%)\n",
      "3. Headache (12%)\n\n",
      "---\n\n",
      "See [full protocol](https://example.com/protocol) for details."
    )
    on_tool_result(paste0("tc-md-", rid), md_result)
    on_chunk("Here is the markdown-rendered report.")

  } else if (grepl("code", msg)) {
    # ── code：语法高亮（R 代码）────────────────────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Generating R code... ")
    on_tool_call(
      paste0("tc-code-", rid), "gen_analysis_code",
      args        = list(analysis = "MMRM"),
      annotations = list(
        icon       = "terminal",
        title      = "Code Generator",
        resultType = "code",
        resultLang = "r"
      )
    )
    Sys.sleep(0.4)
    r_code <- paste0(
      "library(mmrm)\n\n",
      "# Fit MMRM model\n",
      "fit <- mmrm(\n",
      "  formula = AVAL ~ TRTA + AVISIT + TRTA:AVISIT +\n",
      "            USUBJID + us(AVISIT | USUBJID),\n",
      "  data    = adqs\n",
      ")\n\n",
      "# Extract LS means\n",
      "emm <- emmeans(fit, ~ TRTA | AVISIT)\n",
      "contrast(emm, method = \"pairwise\", adjust = \"none\")"
    )
    on_tool_result(paste0("tc-code-", rid), r_code)
    on_chunk("Here is the generated R code with syntax highlighting.")

  } else if (grepl("image|plot", msg)) {
    # ── image：用 R grDevices 生成真实 PNG，base64 encode 后发送 ───────────
    Sys.sleep(0.3)
    on_chunk("Generating plot... ")
    on_tool_call(
      paste0("tc-img-", rid), "render_plot",
      args        = list(type = "KM curve"),
      annotations = list(
        icon       = "flask",
        title      = "Plot Renderer",
        resultType = "image"
      )
    )
    tmp <- tempfile(fileext = ".png")
    on.exit(unlink(tmp), add = TRUE)
    grDevices::png(tmp, width = 480, height = 320)
    t  <- seq(0, 24, by = 0.1)
    s1 <- exp(-0.05 * t)
    s2 <- exp(-0.08 * t)
    plot(t, s1, type = "l", col = "#2563eb", lwd = 2,
         ylim = c(0, 1), xlab = "Time (months)", ylab = "Survival",
         main = "KM Curve (mock)")
    lines(t, s2, col = "#dc2626", lwd = 2, lty = 2)
    legend("topright", legend = c("Drug A", "Placebo"),
           col = c("#2563eb", "#dc2626"), lwd = 2, lty = c(1, 2))
    grDevices::dev.off()
    img_bytes <- readBin(tmp, "raw", file.size(tmp))
    img_b64   <- paste0("data:image/png;base64,",
                        jsonlite::base64_enc(img_bytes))
    on_tool_result(paste0("tc-img-", rid), img_b64)
    on_chunk("The plot is rendered as an image above.")

  } else if (grepl("file", msg)) {
    # ── file：CSV data URL → 下载按钮 ──────────────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Exporting data... ")
    on_tool_call(
      paste0("tc-file-", rid), "export_csv",
      args        = list(dataset = "ADSL", n_rows = 5),
      annotations = list(
        icon           = "database",
        title          = "Export: ADSL",
        resultType     = "file",
        resultFilename = "ADSL_export.csv"
      )
    )
    Sys.sleep(0.3)
    csv_text <- paste(
      "USUBJID,AGE,SEX,TRTA",
      "SUBJ-001,34,M,Drug A",
      "SUBJ-002,45,F,Placebo",
      "SUBJ-003,52,M,Drug A",
      "SUBJ-004,38,F,Drug A",
      "SUBJ-005,61,M,Placebo",
      sep = "\n"
    )
    csv_b64 <- paste0("data:text/csv;base64,",
                      jsonlite::base64_enc(chartr("", "", csv_text)))
    on_tool_result(paste0("tc-file-", rid), csv_b64)
    on_chunk("Click the button in the tool card to download the CSV.")

  } else if (grepl("html", msg)) {
    # ── html：HTML 字符串直接渲染 ───────────────────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Generating HTML report... ")
    on_tool_call(
      paste0("tc-html-", rid), "render_html",
      args        = list(type = "summary table"),
      annotations = list(
        icon       = "code",
        title      = "HTML Renderer",
        resultType = "html"
      )
    )
    Sys.sleep(0.3)
    html_result <- paste0(
      "<div style='font-size:13px'>",
      "<p><strong>Primary Endpoint Summary</strong></p>",
      "<table style='border-collapse:collapse;width:100%'>",
      "<thead><tr>",
      "<th style='border:1px solid #e5e7eb;padding:4px 8px;background:#f9fafb;text-align:left'>Parameter</th>",
      "<th style='border:1px solid #e5e7eb;padding:4px 8px;background:#f9fafb;text-align:left'>Drug A</th>",
      "<th style='border:1px solid #e5e7eb;padding:4px 8px;background:#f9fafb;text-align:left'>Placebo</th>",
      "<th style='border:1px solid #e5e7eb;padding:4px 8px;background:#f9fafb;text-align:left'>p-value</th>",
      "</tr></thead><tbody>",
      "<tr><td style='border:1px solid #e5e7eb;padding:4px 8px'>ORR</td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px;color:#16a34a'><strong>42%</strong></td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px'>18%</td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px'>&lt;0.001</td></tr>",
      "<tr style='background:#f9fafb'><td style='border:1px solid #e5e7eb;padding:4px 8px'>Median OS</td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px;color:#16a34a'><strong>14.2 mo</strong></td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px'>9.8 mo</td>",
      "<td style='border:1px solid #e5e7eb;padding:4px 8px'>0.003</td></tr>",
      "</tbody></table>",
      "<p style='color:#6b7280;font-size:12px;margin-top:6px'>",
      "mo = months; ORR = objective response rate</p>",
      "</div>"
    )
    on_tool_result(paste0("tc-html-", rid), html_result)
    on_chunk("HTML report rendered in the tool card.")

  } else {
    # ── auto（default）：JSON 对象，渲染为 <pre> ────────────────────────────
    Sys.sleep(0.3)
    on_chunk("Running default tool... ")
    on_tool_call(
      paste0("tc-auto-", rid), "fetch_metadata",
      args        = list(id = "STUDY-001")
    )
    Sys.sleep(0.3)
    on_tool_result(paste0("tc-auto-", rid), list(
      study_id = "STUDY-001",
      phase    = "III",
      status   = "ongoing",
      sites    = 24L
    ))
    on_chunk("Default result rendered as JSON in a <pre> block.")
  }

  on_done()
})

ui <- tagList(
  tags$head(tags$style(HTML("html,body{height:100%;margin:0;padding:0;overflow:hidden}"))),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = handler,
    suggestions = list(
      list(prompt = "table",    text = "table"),
      list(prompt = "markdown", text = "markdown"),
      list(prompt = "code",     text = "code"),
      list(prompt = "image",    text = "image"),
      list(prompt = "file",     text = "file"),
      list(prompt = "html",     text = "html")
    )
  )
}

shinyApp(ui, server)

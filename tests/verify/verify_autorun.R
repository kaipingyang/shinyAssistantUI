suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9291L
unlink(c("/tmp/aui-ar.out", "/tmp/aui-ar.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/autorun_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-ar.out", stderr = "/tmp/aui-ar.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-ar.err") && any(grepl("Listening on", readLines("/tmp/aui-ar.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-ar.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 820, height = 780)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 12, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))

# 角度B:R 侧 auto_run=FALSE → config$auto_run → autoRunEnabled → 开关渲染(证明 R→JS 配置贯通)
chk("Auto-run switch renders from server config",
    wait_for("!!document.querySelector('[data-slot=\"aui_auto_run\"]')", 10))
chk("Auto-run switch reflects initial off state",
    isTRUE(value("document.querySelector('[data-slot=\"aui_auto_run\"] input')?.checked === false")))

# 切换 → 前端发 _auto_run_enabled → R on_toggle_auto_run 记录(证明输入回环贯通)
value("document.querySelector('[data-slot=\"aui_auto_run\"] input')?.click()")
chk("toggling reports to server (autorun = toggled:TRUE)",
    wait_for("(document.getElementById('autorun')?.textContent||'').includes('toggled:TRUE')", 8),
    value("document.getElementById('autorun')?.textContent"))

chk("no browser console errors", length(console_errors) == 0,
    if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("AUTORUN_VERIFY_DONE\n")

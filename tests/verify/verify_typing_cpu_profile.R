#!/usr/bin/env Rscript
# 抓敲字期间的 CPU profile,定位 JS 时间到底花在哪个函数。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("PROFILE_PORT", "9380"))
HIST_N <- Sys.getenv("SYNTH_HISTORY_N", "300")

p <- callr::r_bg(function(proj, port, n) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = n, SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT, n = HIST_N), stdout = "/tmp/pf.o", stderr = "/tmp/pf.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/pf.e"), 10), sep="\n"); quit(status=1) }

b <- chromote::ChromoteSession$new()
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(3)

for (i in 1:20) {
  r <- ev("(function(){var items=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'));var it=items.find(e=>/Synthetic Big History/.test(e.innerText));if(!it)return null;var b=it.getBoundingClientRect();return JSON.stringify({x:b.x+20,y:b.y+b.height/2});})()")
  if (!is.na(r) && !is.null(r)) break
  Sys.sleep(0.5)
}
xy <- jsonlite::fromJSON(r)
b$Input$dispatchMouseEvent(type="mousePressed", x=xy$x, y=xy$y, button="left", clickCount=1)
b$Input$dispatchMouseEvent(type="mouseReleased", x=xy$x, y=xy$y, button="left", clickCount=1)
prev <- -1; for (i in 1:60) { Sys.sleep(0.3); now <- as.integer(ev("document.querySelectorAll('*').length")); if (identical(now,prev)) break; prev <- now }
cat("DOM 节点 =", prev, "\n")

ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el)el.focus();return !!el})()")
Sys.sleep(0.5)

b$Profiler$enable()
b$Profiler$setSamplingInterval(interval = 100)  # 100us,够细
b$Profiler$start()
for (ch in strsplit("hello world typing test", "")[[1]]) { b$Input$insertText(text = ch); Sys.sleep(0.02) }
Sys.sleep(0.5)
prof <- b$Profiler$stop()$profile
b$Profiler$disable()

nodes <- prof$nodes
total_hits <- sum(vapply(nodes, function(n) n$hitCount %||% 0, numeric(1)))
interval_ms <- 0.1
cat(sprintf("\n采样总数 %.0f (约 %.0f ms CPU)\n", total_hits, total_hits * interval_ms))

rows <- lapply(nodes, function(n) {
  cf <- n$callFrame
  data.frame(
    hits = n$hitCount %||% 0,
    fn = if (nzchar(cf$functionName %||% "")) cf$functionName else "(anonymous)",
    loc = sprintf("%s:%s", sub(".*/", "", cf$url %||% ""), (cf$lineNumber %||% 0) + 1),
    stringsAsFactors = FALSE
  )
})
df <- do.call(rbind, rows)
df <- df[df$hits > 0, ]
df <- df[order(-df$hits), ]
df$ms <- round(df$hits * interval_ms, 1)
df$pct <- round(df$hits / max(total_hits, 1) * 100, 1)

cat("\n=== 自身耗时 top 20 ===\n")
print(head(df[, c("ms", "pct", "fn", "loc")], 20), row.names = FALSE)

b$close(); p$kill()
cat("\nPROFILE_DONE\n")

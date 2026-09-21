#!/usr/bin/env Rscript
# 用 CDP Performance 指标区分成本到底在「样式重算」还是「布局」。
# RecalcStyleCount/Duration vs LayoutCount/Duration,敲字前后取差值。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("PERFMETRIC_PORT", "9370"))
CSS  <- Sys.getenv("PERFMETRIC_CSS", "")

p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = "300", SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/pm.o", stderr = "/tmp/pm.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/pm.e"), 10), sep="\n"); quit(status=1) }

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

if (nzchar(CSS)) {
  cat("注入 CSS:", CSS, "\n")
  ev(sprintf("(function(){var s=document.createElement('style');s.textContent=%s;document.head.appendChild(s);return true})()",
             jsonlite::toJSON(CSS, auto_unbox = TRUE)))
  Sys.sleep(0.8)
}

ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el)el.focus();return !!el})()")
Sys.sleep(0.5)

b$Performance$enable()
grab <- function() {
  m <- b$Performance$getMetrics()$metrics
  out <- list(); for (x in m) out[[x$name]] <- x$value; out
}
before <- grab()
for (ch in strsplit("hello world typing test", "")[[1]]) { b$Input$insertText(text = ch); Sys.sleep(0.02) }
Sys.sleep(1)
after <- grab()

d <- function(k) (after[[k]] %||% 0) - (before[[k]] %||% 0)
cat("\n=== 敲 23 个字符期间的引擎侧开销 ===\n")
cat(sprintf("样式重算 次数 : %6.0f    耗时 : %7.1f ms\n", d("RecalcStyleCount"), d("RecalcStyleDuration")*1000))
cat(sprintf("布局     次数 : %6.0f    耗时 : %7.1f ms\n", d("LayoutCount"), d("LayoutDuration")*1000))
cat(sprintf("脚本执行 耗时 : %7.1f ms\n", d("ScriptDuration")*1000))
cat(sprintf("总任务   耗时 : %7.1f ms\n", d("TaskDuration")*1000))
cat(sprintf("节点数        : %6.0f\n", after[["Nodes"]] %||% 0))

b$close(); p$kill()
cat("PERFMETRIC_DONE\n")

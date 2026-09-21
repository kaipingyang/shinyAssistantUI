#!/usr/bin/env Rscript
# 量化 computeActiveQuestion 的强制同步布局成本:
# querySelectorAll('[data-role="user"]') + 对每条调 getBoundingClientRect()。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("SCROLLSPY_PORT", "9295"))
HIST_N <- Sys.getenv("SYNTH_HISTORY_N", "300")

p <- callr::r_bg(function(proj, port, n) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = n, SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT, n = HIST_N), stdout = "/tmp/ss.o", stderr = "/tmp/ss.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/ss.e"), 10), sep = "\n"); quit(status = 1) }

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
prev <- -1; for (i in 1:60) { Sys.sleep(0.3); now <- as.integer(ev("document.querySelectorAll('*').length")); if (identical(now, prev)) break; prev <- now }

# 复刻 computeActiveQuestion 的实现并计时(不改产品代码,只测同等成本)
res <- ev("
(function(){
  const vp = document.querySelector('[data-slot=aui_thread-viewport]');
  if (!vp) return JSON.stringify({error:'no viewport'});
  const users = vp.querySelectorAll('[data-role=\"user\"]');
  const runOnce = () => {
    // 与 computeActiveQuestion 等价:先读 viewport 再逐条读 rect
    const threshold = vp.getBoundingClientRect().top + 40;
    let idx = -1;
    users.forEach((el, i) => { if (el.getBoundingClientRect().top <= threshold) idx = i; });
    return idx;
  };
  runOnce();
  const t0 = performance.now();
  for (let k = 0; k < 20; k++) {
    // 每轮先制造一次样式写入,强制布局失效 —— 模拟 ResizeObserver 场景下
    // 『写样式 -> 读 rect』交替发生的 layout thrashing
    vp.style.setProperty('--probe', String(k));
    runOnce();
  }
  const perCall = (performance.now() - t0) / 20;
  // 对照:只读一次 rect 的成本
  const t1 = performance.now();
  for (let k = 0; k < 20; k++) { vp.style.setProperty('--probe2', String(k)); vp.getBoundingClientRect(); }
  const baseline = (performance.now() - t1) / 20;
  return JSON.stringify({
    userMessages: users.length,
    totalNodes: document.querySelectorAll('*').length,
    perComputeMs: perCall,
    singleRectMs: baseline
  });
})();
")
m <- jsonlite::fromJSON(res)
cat("\n=== computeActiveQuestion 成本实测 ===\n")
cat(sprintf("历史消息总节点数        : %s\n", m$totalNodes))
cat(sprintf("[data-role=user] 条数   : %s\n", m$userMessages))
cat(sprintf("单次 computeActiveQuestion: %.2f ms\n", m$perComputeMs))
cat(sprintf("对照(仅 1 次 rect 读取)  : %.3f ms\n", m$singleRectMs))
cat(sprintf("倍数                     : %.0fx\n", m$perComputeMs / max(m$singleRectMs, 0.001)))
cat("\n说明: 敲一个字符会让 composer 高度变化 -> ResizeObserver 触发 -> 执行一次上述计算。\n")

b$close(); p$kill()
cat("SCROLLSPY_COST_DONE\n")

#!/usr/bin/env Rscript
# 定位"重启后加载历史 session + 点 Refresh + 打字就卡"的真正原因。
# 隔离变量:用合成消息(不走真实 SDK)测「历史消息挂载量」对打字延迟的影响,
# 对照组是同一个 app 在加载历史之前(0 条消息)的打字延迟。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
main <- function() {
source("tests/verify/owned_process_cleanup.R", local = TRUE)
source("tests/verify/window_error_capture.R", local = TRUE)
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("TYPING_LAG_PORT", as.character(httpuv::randomPort())))
HIST_N <- Sys.getenv("SYNTH_HISTORY_N", "300")
HIST_KIND <- Sys.getenv("SYNTH_HISTORY_KIND", "mixed")
cat(sprintf("=== 配置: %s 条 %s 历史 ===\n", HIST_N, HIST_KIND))
log_paths <- c(tempfile("aui-typing-out-"), tempfile("aui-typing-err-"))
b <- NULL

p <- callr::r_bg(function(proj, port, n, kind) {
  setwd(proj)
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = n, SYNTH_HISTORY_KIND = kind)
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT, n = HIST_N, kind = HIST_KIND),
   stdout = log_paths[[1L]], stderr = log_paths[[2L]])
cleanup <- make_verification_cleanup(
  browser_session = function() b, app_process = function() p, paths = log_paths
)
on.exit(cleanup(), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) {
  cat(tail(readLines(log_paths[[2L]]), 15), sep = "\n")
  stop("Typing fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
  "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload"
)))
b <- chromote::ChromoteSession$new()
errs <- c()
window_errors <- capture_browser_window_errors(b, function() "typing-history")
b$Performance$enable()
metrics <- function() {
  values <- b$Performance$getMetrics()$metrics
  stats::setNames(vapply(values, function(x) x$value, numeric(1)),
                  vapply(values, function(x) x$name, character(1)))
}
b$Runtime$consoleAPICalled(callback_ = function(m) {
  if (identical(m$type, "error")) {
    errs <<- c(errs, paste(sapply(m$args, function(a) a$value %||% a$description %||% ""), collapse = " "))
  }
})
b$Runtime$exceptionThrown(callback_ = function(m) {
  errs <<- c(errs, paste("EXC:", m$exceptionDetails$exception$description %||% m$exceptionDetails$text %||% ""))
})
ev <- function(js) {
  result <- b$Runtime$evaluate(js, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}

b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
b$Page$loadEventFired()
Sys.sleep(3)
stopifnot(isTRUE(ev("window.__auiWindowErrorProbeReady")))

# 安装 long task + composer keydown 延迟探针(在页面里跑,不依赖 CDP 往返计时)。
ev("
window.__probe = { longtasks: [], keyTimes: [] };
document.addEventListener('beforeinput', event => {
  if (!event.target?.closest?.('.aui-lexical-input')) return;
  const start = performance.now();
  requestAnimationFrame(() => window.__probe.keyTimes.push(performance.now() - start));
}, true);
try {
  const po = new PerformanceObserver((list) => {
    for (const e of list.getEntries()) window.__probe.longtasks.push(e.duration);
  });
  po.observe({ entryTypes: ['longtask'] });
} catch (e) {}
")

read_probe_array <- function(field) {
  raw <- ev(sprintf("JSON.stringify(window.__probe.%s)", field))
  as.numeric(unlist(jsonlite::fromJSON(raw)))
}
dom_count <- function() as.integer(ev("document.querySelectorAll('*').length"))
focus_composer <- function() ev(
  "(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el)el.focus();return !!el;})()"
)

# 逐字符打字,页面内测每次 keydown 到下一帧的耗时(不含 CDP round-trip,反映真实渲染压力)。
type_and_measure <- function(text) {
  ev("window.__probe.keyTimes = []; window.__typing_t0 = performance.now();")
  chars <- strsplit(text, "")[[1]]
  for (ch in chars) {
    b$Input$insertText(text = ch)
    Sys.sleep(0.01)
  }
  Sys.sleep(0.3)
  ev("performance.now() - window.__typing_t0")
}

# ---- 阶段 1:空历史基线 ----
cat("等待 composer 挂载(空历史)...\n")
for (i in 1:20) { if (isTRUE(focus_composer())) break; Sys.sleep(0.3) }
dom0 <- dom_count()
ev("window.__probe.longtasks = [];")
metrics_empty_start <- metrics()
elapsed_empty <- type_and_measure("hello world baseline test 12345")
metrics_empty <- metrics() - metrics_empty_start
frames_empty <- read_probe_array("keyTimes")
longtasks_empty <- read_probe_array("longtasks")
cat(sprintf("[空历史]   DOM 节点=%d  打字总耗时=%.0fms  单帧最大=%.1fms  单帧p95=%.1fms  long tasks=%d(合计%.0fms)\n",
            dom0, elapsed_empty, max(frames_empty, 0), quantile(frames_empty, 0.95, na.rm=TRUE),
            length(longtasks_empty), sum(longtasks_empty)))
b$Input$dispatchKeyEvent(type = "keyDown", key = "a", code = "KeyA", modifiers = 2L, windowsVirtualKeyCode = 65L)
b$Input$dispatchKeyEvent(type = "keyUp", key = "a", code = "KeyA", modifiers = 2L, windowsVirtualKeyCode = 65L)
b$Input$dispatchKeyEvent(type = "keyDown", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)
b$Input$dispatchKeyEvent(type = "keyUp", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)

# ---- 阶段 2:真实点击侧栏 session,走前端完整的 requestSessionLoad 路径 ----
# (不能伪造 setInputValue:前端用 historyReplaceRequestsRef 做 requestId 配对,
#  伪造的 requestId 不匹配会被直接丢弃。)
n_items <- as.integer(ev("document.querySelectorAll('[data-slot=aui_thread-list-item]').length"))
items_text <- ev("JSON.stringify(Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).map(e=>e.innerText))")
cat("侧栏 session 条目数:", n_items, " 内容:", items_text, "\n")
if (is.na(n_items) || n_items < 1) {
  cat("FAIL: 侧栏没有 session 条目,无法触发历史加载\n")
  stop("History fixture has no session entry")
}
# 必须点服务器下发的那条(Synthetic Big History),不是本地新建的空 thread:
# 前端 requestSessionLoad 对已是当前活动的 thread 会直接 return,不会发请求。
rect <- ev("(function(){var items=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'));var it=items.find(e=>/Synthetic Big History/.test(e.innerText))||items[items.length-1];if(!it)return null;var r=it.getBoundingClientRect();return JSON.stringify({x:r.x+20,y:r.y+r.height/2});})()")
if (is.null(rect) || is.na(rect)) stop("History fixture session cannot be clicked")
xy <- jsonlite::fromJSON(rect)
cat("点击坐标:", xy$x, xy$y, "\n")
b$Input$dispatchMouseEvent(type = "mousePressed", x = xy$x, y = xy$y, button = "left", clickCount = 1)
b$Input$dispatchMouseEvent(type = "mouseReleased", x = xy$x, y = xy$y, button = "left", clickCount = 1)
Sys.sleep(0.5)
# 轮询直到 DOM 节点数稳定(历史消息挂载完成)
prev <- dom_count(); stable <- 0
for (i in 1:60) {
  Sys.sleep(0.3)
  now <- dom_count()
  if (identical(now, prev)) { stable <- stable + 1; if (stable >= 3) break } else stable <- 0
  prev <- now
}
dom1 <- dom_count()
n_tool_cards <- as.integer(ev("document.querySelectorAll('[data-tool-depth]').length"))
n_messages_dom <- as.integer(ev("document.querySelectorAll('[data-role]').length"))
cat(sprintf("历史挂载后: DOM 节点=%d (+%d)  可见 tool-call 卡片=%s  带 role 的消息节点=%s\n",
            dom1, dom1 - dom0, n_tool_cards, n_messages_dom))
cat("窗口几何:", ev("JSON.stringify((()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]'),l=document.querySelector('[data-slot=aui_virtualized-messages]'),rows=[...document.querySelectorAll('[data-slot=aui_message-slot]')];return {screen:innerHeight,viewport:v?.clientHeight,top:v?.scrollTop,scrollHeight:v?.scrollHeight,listHeight:l?.getBoundingClientRect().height,rowHeights:rows.slice(-5).map(x=>x.getBoundingClientRect().height),spacers:document.querySelectorAll('[data-slot=aui_message-spacer]').length,first:rows[0]?.dataset.messageIndex,last:rows.at(-1)?.dataset.messageIndex}})())"), "\n")

# ---- 阶段 3:大历史挂载后的打字延迟 ----
# TYPING_LAG_CSS 可注入一段实验性 CSS,用来 A/B 验证某条布局耦合是否是成本来源。
extra_css <- Sys.getenv("TYPING_LAG_CSS", "")
if (nzchar(extra_css)) {
  cat("注入实验 CSS:", extra_css, "\n")
  ev(sprintf(
    "(function(){var s=document.createElement('style');s.textContent=%s;document.head.appendChild(s);return true})()",
    jsonlite::toJSON(extra_css, auto_unbox = TRUE)
  ))
  Sys.sleep(0.8)
}
for (i in 1:10) { if (isTRUE(focus_composer())) break; Sys.sleep(0.3) }
ev("window.__probe.longtasks = [];")
metrics_loaded_start <- metrics()
profile_enabled <- identical(Sys.getenv("TYPING_LAG_PROFILE", ""), "1")
if (profile_enabled) {
  b$Profiler$enable()
  b$Profiler$setSamplingInterval(interval = 1000L)
  b$Profiler$start()
}
elapsed_loaded <- type_and_measure("hello world after history load 12345")
metrics_loaded <- metrics() - metrics_loaded_start
if (profile_enabled) {
  profile <- b$Profiler$stop()$profile
  b$Profiler$disable()
  profile_rows <- do.call(rbind, lapply(profile$nodes, function(node) {
    frame <- node$callFrame
    data.frame(
      hits = node$hitCount %||% 0,
      fn = frame$functionName %||% "",
      line = (frame$lineNumber %||% 0) + 1,
      column = frame$columnNumber %||% 0,
      file = basename(frame$url %||% ""),
      stringsAsFactors = FALSE
    )
  }))
  profile_rows <- aggregate(hits ~ fn + line + column + file, profile_rows, sum)
  cat("CPU profile hot functions:\n")
  print(head(profile_rows[order(-profile_rows$hits), ], 35L), row.names = FALSE)
}
frames_loaded <- read_probe_array("keyTimes")
longtasks_loaded <- read_probe_array("longtasks")
cat(sprintf("[大历史后] DOM 节点=%d  打字总耗时=%.0fms  单帧最大=%.1fms  单帧p95=%.1fms  long tasks=%d(合计%.0fms)\n",
            dom1, elapsed_loaded, max(frames_loaded, 0), quantile(frames_loaded, 0.95, na.rm=TRUE),
            length(longtasks_loaded), sum(longtasks_loaded)))

cat("\n=== 对比 ===\n")
cat(sprintf("打字总耗时:      %.0fms -> %.0fms  (%.1fx)\n", elapsed_empty, elapsed_loaded, elapsed_loaded / max(elapsed_empty,1)))
cat(sprintf("单帧最大耗时:    %.1fms -> %.1fms\n", max(frames_empty,0), max(frames_loaded,0)))
cat(sprintf("单帧 p95:        %.1fms -> %.1fms\n", quantile(frames_empty,0.95,na.rm=TRUE), quantile(frames_loaded,0.95,na.rm=TRUE)))
cat(sprintf("long tasks 数量: %d -> %d\n", length(longtasks_empty), length(longtasks_loaded)))
cat(sprintf("DOM 节点数:      %d -> %d\n", dom0, dom1))
for (metric in c("ScriptDuration", "LayoutDuration", "RecalcStyleDuration", "TaskDuration")) {
  cat(sprintf("%s: %.1f -> %.1f ms\n", metric,
              metrics_empty[[metric]] * 1000, metrics_loaded[[metric]] * 1000))
}

cat("\nconsole/runtime errors:", length(errs), "\n")
cat("direct window errors:", length(window_errors()), "\n")
if (length(errs)) cat(head(unique(errs), 5), sep = "\n")

mounted <- as.integer(ev("document.querySelectorAll('[data-slot=aui_message-slot]').length"))
limit <- max(33.4, as.numeric(quantile(frames_empty, 0.95, na.rm = TRUE)) * 1.75)
loaded_p95 <- as.numeric(quantile(frames_loaded, 0.95, na.rm = TRUE))
cat(sprintf("虚拟窗口验收: mounted=%d (<=48), p95=%.1fms (<=%.1fms)\n",
            mounted, loaded_p95, limit))
stopifnot(length(frames_empty) == nchar("hello world baseline test 12345"),
          length(frames_loaded) == nchar("hello world after history load 12345"))
stopifnot(length(errs) == 0L, length(window_errors()) == 0L,
          mounted > 0L, mounted <= 48L, loaded_p95 <= limit)
stopifnot(isTRUE(ev("document.querySelector('[data-slot=aui_thread-viewport]').clientHeight <= innerHeight + 1")))
cleanup()
cat("TYPING_LAG_DONE\n")
}
main()

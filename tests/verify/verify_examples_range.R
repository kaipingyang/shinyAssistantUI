#!/usr/bin/env Rscript
# 批量验证 examples/ 的一个【索引区间】,供多个子进程/子agent并行(每个只跑一半)。
# 用法: Rscript verify_examples_range.R <start> <end>
#   区间按 sort(examples) 的 1-based 全局索引(端点含)。
#   端口用全局索引 8940+i,两个区间互不冲突。
# 每个 app:callr 后台启动 -> chromote 验证 .aui-root 渲染 -> 立即 kill + 关闭会话(严格清理,防 OOM)。
suppressMessages({ library(chromote); library(callr) })

PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
apps <- sort(list.files(file.path(PROJ, "examples"), pattern = "\\.R$"))
nwidget <- c(dual_widget_approval.R = 2, strings.R = 2, theming.R = 3)

args  <- commandArgs(trailingOnly = TRUE)
start <- as.integer(args[[1]]); end <- as.integer(args[[2]])
stopifnot(!is.na(start), !is.na(end), start >= 1, end <= length(apps), start <= end)

run_one <- function(app, port) {
  logf <- sprintf("/tmp/exr_%s.log", app); errf <- sprintf("/tmp/exr_%s.err", app)
  proc <- callr::r_bg(function(proj, app, port) {
    setwd(proj); suppressMessages(library(shiny))
    shiny::runApp(file.path("examples", app), host = "127.0.0.1",
                  port = port, launch.browser = FALSE)
  }, args = list(proj = PROJ, app = app, port = port), stdout = logf, stderr = errf)

  Sys.sleep(8)
  boot <- proc$is_alive(); rendered <- FALSE; widgets <- 0L; note <- ""
  if (!boot) {
    note <- tryCatch(paste(tail(readLines(errf), 3), collapse = " | "),
                     error = function(e) "crashed (no err log)")
  } else {
    b <- tryCatch({
      s <- ChromoteSession$new()
      s$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); s$Page$loadEventFired()
      Sys.sleep(4); s
    }, error = function(e) NULL)
    if (!is.null(b)) {
      ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
      widgets <- suppressWarnings(as.integer(ev("document.querySelectorAll('.aui-root').length")))
      if (is.na(widgets)) widgets <- 0L
      ce <- suppressWarnings(as.integer(ev("document.querySelectorAll('[contenteditable=true]').length")))
      if (is.na(ce)) ce <- 0L
      rendered <- widgets >= 1L
      body_len <- ev("document.body.innerText.length")
      note <- sprintf("aui-root=%d, contenteditable=%d, bodyText=%s", widgets, ce, body_len)
      try(b$close(), silent = TRUE)
      try(b$parent$get_browser()$get_process()$kill(), silent = TRUE)  # 关闭底层 Chrome,防累积
    } else note <- "chromote session failed"
  }
  try(proc$kill(), silent = TRUE)
  Sys.sleep(1)
  list(boot = boot, rendered = rendered, widgets = widgets, note = note)
}

npass <- 0L
for (i in start:end) {
  app <- apps[i]
  r <- run_one(app, 8940 + i)
  exp_w <- if (!is.na(nwidget[app])) nwidget[[app]] else 1L
  ok <- r$boot && r$rendered && r$widgets >= exp_w
  if (r$boot && r$rendered) npass <- npass + 1L
  cat(sprintf("[%s] %-34s boot=%s rendered=%s widgets=%d(exp>=%d) | %s\n",
              if (ok) "PASS" else "FAIL", app, r$boot, r$rendered, r$widgets, exp_w, r$note))
  # 每个 app 后强制回收残留 chrome,严格控制峰值内存
  suppressWarnings(chromote::default_chromote_object()$get_browser()$get_process()$kill())
  try(chromote::set_default_chromote_object(chromote::Chromote$new()), silent = TRUE)
}
cat(sprintf("\nRANGE %d-%d: %d / %d boot+render\n", start, end, npass, end - start + 1L))
cat("RANGE_DONE\n")

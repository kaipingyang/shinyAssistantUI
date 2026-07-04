#!/usr/bin/env Rscript
# 批量验证 examples/ 下所有 Shiny app:能否启动 + widget(.aui-root/composer)渲染。
# 需外部 AI 后端的 app 无凭证不发消息,只验证 boot + mount(handler 惰性,不阻塞启动)。
suppressMessages({ library(chromote); library(callr) })

PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
apps <- sort(list.files(file.path(PROJ, "examples"), pattern = "\\.R$"))
# 每个 app 期望的 widget 数(默认 1;多 widget 的单列)
nwidget <- c(dual_widget_approval.R = 2, strings.R = 2, theming.R = 3)

port0 <- 8940
results <- data.frame(app = character(), boot = logical(), rendered = logical(),
                      widgets = integer(), note = character(), stringsAsFactors = FALSE)

run_one <- function(app, port) {
  logf <- sprintf("/tmp/ex_%s.log", app); errf <- sprintf("/tmp/ex_%s.err", app)
  proc <- callr::r_bg(function(proj, app, port) {
    setwd(proj); suppressMessages(library(shiny))
    shiny::runApp(file.path("examples", app), host = "127.0.0.1",
                  port = port, launch.browser = FALSE)
  }, args = list(proj = PROJ, app = app, port = port),
     stdout = logf, stderr = errf)

  Sys.sleep(8)
  boot <- proc$is_alive()
  rendered <- FALSE; widgets <- 0L; note <- ""
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
      widgets  <- ev("document.querySelectorAll('.aui-root').length")
      ce       <- ev("document.querySelectorAll('[contenteditable=true]').length")
      widgets  <- suppressWarnings(as.integer(widgets)); if (is.na(widgets)) widgets <- 0L
      ce       <- suppressWarnings(as.integer(ce)); if (is.na(ce)) ce <- 0L
      rendered <- widgets >= 1L
      # 读 JS 控制台是否有致命报错(可选,记 note)
      body_len <- ev("document.body.innerText.length")
      note     <- sprintf("aui-root=%d, contenteditable=%d, bodyText=%s", widgets, ce, body_len)
      try(b$close(), silent = TRUE)
    } else note <- "chromote session failed"
  }
  try(proc$kill(), silent = TRUE)
  Sys.sleep(1)
  list(boot = boot, rendered = rendered, widgets = widgets, note = note)
}

for (i in seq_along(apps)) {
  app <- apps[i]
  cat(sprintf("\n----- [%d/%d] %s -----\n", i, length(apps), app))
  r <- run_one(app, port0 + i)
  exp_w <- if (!is.na(nwidget[app])) nwidget[[app]] else 1L
  wid_ok <- r$widgets >= exp_w
  status <- if (r$boot && r$rendered && wid_ok) "PASS" else if (r$boot && r$rendered) "PARTIAL" else "FAIL"
  cat(sprintf("[%s] boot=%s rendered=%s widgets=%d(exp>=%d) | %s\n",
              status, r$boot, r$rendered, r$widgets, exp_w, r$note))
  results <- rbind(results, data.frame(app = app, boot = r$boot, rendered = r$rendered,
                                       widgets = r$widgets, note = r$note, stringsAsFactors = FALSE))
}

cat("\n================ SUMMARY ================\n")
for (i in seq_len(nrow(results))) {
  r <- results[i, ]
  st <- if (r$boot && r$rendered) "PASS" else "FAIL"
  cat(sprintf("%-34s %s (widgets=%d)\n", r$app, st, r$widgets))
}
npass <- sum(results$boot & results$rendered)
cat(sprintf("\n%d / %d apps boot + render\n", npass, nrow(results)))
cat("DONE\n")

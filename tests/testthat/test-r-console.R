# Plan 21 / Angle A — .GlobalEnv 执行 + nanonext 回传。

test_that(".addin_run_r_capture captures value / message / warning / error / invisibility", {
  e <- new.env(parent = globalenv())
  # 可见返回值
  r <- shinyAssistantUI:::.addin_run_r_capture("1 + 1", envir = e)
  expect_true(r$ok); expect_match(r$output, "2", fixed = TRUE)
  # 不可见赋值 → 无输出,但对象落在 e
  r <- shinyAssistantUI:::.addin_run_r_capture("zz <- 41 + 1", envir = e)
  expect_true(r$ok); expect_identical(r$output, "")
  expect_identical(get("zz", envir = e), 42)
  # 读它
  r <- shinyAssistantUI:::.addin_run_r_capture("zz", envir = e)
  expect_match(r$output, "42", fixed = TRUE)
  # message
  r <- shinyAssistantUI:::.addin_run_r_capture('message("hi there")', envir = e)
  expect_true(r$ok); expect_match(r$output, "hi there", fixed = TRUE)
  # warning
  r <- shinyAssistantUI:::.addin_run_r_capture('warning("careful")', envir = e)
  expect_match(r$output, "careful", fixed = TRUE)
  # error
  r <- shinyAssistantUI:::.addin_run_r_capture('stop("boom")', envir = e)
  expect_false(r$ok); expect_match(r$error, "boom", fixed = TRUE)
  # 空代码
  expect_true(shinyAssistantUI:::.addin_run_r_capture("")$ok)
})

test_that(".addin_run_r_capture captures cat/print stdout (Bug: run-in-console 报 no visible output)", {
  e <- new.env(parent = globalenv())
  # cat 直接写 stdout —— 之前只捕获可见返回值,cat 文本丢失 → Claude 看到 (no visible output)
  r <- shinyAssistantUI:::.addin_run_r_capture('cat("Hello, World!\n")', envir = e)
  expect_true(r$ok); expect_match(r$output, "Hello, World!", fixed = TRUE)
  # print 也走 stdout
  r <- shinyAssistantUI:::.addin_run_r_capture('print("abc")', envir = e)
  expect_match(r$output, "abc", fixed = TRUE)
  # cat + 可见返回值 混合:两者都在
  r <- shinyAssistantUI:::.addin_run_r_capture('cat("line1\n"); 7 * 6', envir = e)
  expect_match(r$output, "line1", fixed = TRUE)
  expect_match(r$output, "42", fixed = TRUE)
})

test_that(".addin_run_r_remote 无 server 时安全返回错误(不抛)", {
  skip_if_not_installed("nanonext")
  r <- shinyAssistantUI:::.addin_run_r_remote("ipc:///tmp/nonexistent-claude-xyz.sock", "1+1", timeout = 800)
  expect_false(r$ok)
  expect_true(nzchar(r$error))
})

test_that("nanonext round-trip: 客户端在 server 的 .GlobalEnv 执行并取回捕获结果", {
  skip_if_not_installed("nanonext")
  skip_if_not_installed("callr")
  url <- sprintf("ipc:///tmp/claude-console-test-%d.sock", as.integer(Sys.time()) %% 100000L)
  proj <- normalizePath(".")
  srv <- callr::r_bg(function(url, proj) {
    pkgload::load_all(proj, quiet = TRUE)
    assign("SERVER_ONLY_VAR", 123L, envir = globalenv())
    sock <- nanonext::socket("rep", listen = url)
    for (i in 1:300) shinyAssistantUI:::.addin_console_service_once(sock, timeout = 100)
  }, args = list(url = url, proj = proj))
  on.exit(try(srv$kill(), silent = TRUE), add = TRUE)
  Sys.sleep(2)  # 让 server 绑定 + load_all

  r1 <- shinyAssistantUI:::.addin_run_r_remote(url, "1 + 1", timeout = 6000)
  expect_true(r1$ok); expect_match(r1$output, "2", fixed = TRUE)

  r2 <- shinyAssistantUI:::.addin_run_r_remote(url, "SERVER_ONLY_VAR * 2", timeout = 6000)
  expect_true(r2$ok); expect_match(r2$output, "246", fixed = TRUE)   # 读到 server 的 .GlobalEnv

  r3 <- shinyAssistantUI:::.addin_run_r_remote(url, 'stop("boom")', timeout = 6000)
  expect_false(r3$ok); expect_match(r3$error, "boom", fixed = TRUE)
})

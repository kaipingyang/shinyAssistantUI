# Plan 57 — reset_clients disconnect is async (off the R main loop) so switching working
# directory (or model/permission/thinking/run_r) doesn't freeze the addin UI while each CLI
# subprocess is torn down (interrupt+wait+kill+wait ≈ up to 5s each). The registry snapshot +
# clear stays synchronous (so a new connect starts from an empty registry, no stale reuse).

test_that(".cleanup_claude_client_registry async: clears registry synchronously, disconnects only after later flush", {
  skip_if_not_installed("later")
  f <- shinyAssistantUI:::.cleanup_claude_client_registry
  disc <- 0L
  fake <- list(disconnect = function() disc <<- disc + 1L)
  reg <- list(fake, fake)
  cleared <- FALSE
  f(get_clients   = function() reg,
    clear_clients = function() { reg <<- list(); cleared <<- TRUE },
    async = TRUE)
  # 同步段:注册表已清空;但断开还没发生(挪到 later 了)→ 调用瞬间返回,不阻塞
  expect_true(cleared)
  expect_length(reg, 0L)
  expect_identical(disc, 0L)
  # later flush 后才真正断开
  later::run_now()
  expect_identical(disc, 2L)
})

test_that(".cleanup_claude_client_registry sync (default): disconnects immediately (session-end path)", {
  f <- shinyAssistantUI:::.cleanup_claude_client_registry
  disc <- 0L
  fake <- list(disconnect = function() disc <<- disc + 1L)
  reg <- list(fake)
  f(get_clients = function() reg, clear_clients = function() reg <<- list())  # async 默认 FALSE
  expect_identical(disc, 1L)
})

test_that(".cleanup_claude_client_registry: empty registry is a no-op (still clears)", {
  f <- shinyAssistantUI:::.cleanup_claude_client_registry
  cleared <- FALSE
  f(get_clients = function() list(), clear_clients = function() cleared <<- TRUE, async = TRUE)
  expect_true(cleared)
  if (requireNamespace("later", quietly = TRUE)) later::run_now()
  succeed()
})

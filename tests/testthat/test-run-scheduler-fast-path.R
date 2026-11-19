# A free permit is taken synchronously so a run never waits for a later promise
# turn (that turn stalled follow-up chip sends inside Shiny ExtendedTask).

direct_tasks <- function() function(fn) list(invoke = function(...) { fn(...); invisible(NULL) })

test_that("an idle scheduler starts the run inside invoke without a promise turn", {
  started <- character()
  s <- shinyAssistantUI:::.new_thread_run_scheduler(
    run = function(thread_id, run_id, ...) { started <<- c(started, run_id); NULL },
    task_factory = direct_tasks()
  )
  s$invoke("t", "r1")
  expect_identical(started, "r1")            # no later::run_now() needed
  s$invoke("t", "r2")
  expect_identical(started, c("r1", "r2"))
  expect_false(s$is_busy())
})

test_that("runs beyond the concurrency limit still queue and start in order", {
  started <- character()
  resolvers <- list()
  s <- shinyAssistantUI:::.new_thread_run_scheduler(
    run = function(thread_id, run_id, ...) {
      started <<- c(started, run_id)
      promises::promise(function(resolve, reject) resolvers[[run_id]] <<- resolve)
    },
    max_concurrent = 1L,
    task_factory = direct_tasks()
  )
  s$invoke("a", "a1")
  s$invoke("b", "b1")
  expect_identical(started, "a1")
  expect_identical(s$waiting_count(), 1L)
  resolvers$a1(NULL)
  for (i in 1:20) later::run_now(0.01)
  expect_identical(started, c("a1", "b1"))
})

# Installed-code gate; the local generator replaces the model, not codeagent.
local({
  suppressPackageStartupMessages(library(shinyAssistantUI))
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  packages <- c("shinyAssistantUI", "codeagent")
  identities <- setNames(vapply(packages, function(package) {
    normalizePath(find.package(package))
  }, character(1)), packages)
  stopifnot(identical(unname(identities), file.path(home, packages)))
  stopifnot(compiler::enableJIT(-1L) > 0L)
  output <- Sys.getenv("AUI_CODEAGENT_LATENCY_OUT", tempfile("codeagent-latency-"))
  root <- tempfile("codeagent-latency-home-")
  dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  withr::local_envvar(c(HOME = root, CODEAGENT_HOME = file.path(root, "settings")))
  withr::local_options(shiny.deepstacktrace = TRUE)

  measure <- function(citations) {
    loop <- later::create_loop(parent = NULL)
    on.exit(later::destroy_loop(loop), add = TRUE)
    state <- new.env(parent = emptyenv())
    state$provider_first <- NA_real_
    state$provider_finished <- NA_real_
    state$codeagent_first <- NA_real_
    state$visible_first <- NA_real_
    state$chunks <- character()
    state$done <- 0L
    state$error <- NULL
    state$settled <- FALSE
    state$started <- proc.time()[["elapsed"]]
    elapsed <- function() proc.time()[["elapsed"]] - state$started
    wait <- function() promises::promise(function(resolve, reject) {
      later::later(function() resolve(NULL), delay = 0.05, loop = loop)
    })
    stream <- coro::async_generator(function() {
      for (index in seq_len(20L)) {
        coro::await(wait())
        if (index == 1L) state$provider_first <- elapsed()
        coro::yield(ellmer::ContentText(sprintf("fragment-%02d ", index)))
      }
      state$provider_finished <- elapsed()
    })
    chat <- list(stream_async = function(...) stream(), last_turn = function(...) NULL)
    client <- structure(list(
      chat = chat, settings = list(
        cwd = root, model = "gpt-4.1", model_limit = 200000L,
        web_citations = citations
      )
    ), class = "CodeagentClient")
    handler <- make_codeagent_handler(
      client_factory = function() client,
      gate_fn = function(...) invisible(NULL),
      stream_fn = function(client, input, on_delta, ...) {
        codeagent::codeagent_stream_async(
          client, input,
          on_delta = function(text) {
            if (is.na(state$codeagent_first)) state$codeagent_first <- elapsed()
            on_delta(text)
          },
          ...
        )
      }
    )
    on.exit(attr(handler, "teardown")(), add = TRUE)
    later::with_loop(loop, {
      result <- shiny::captureStackTraces(handler(
        message = "Synthetic timing fixture", thread_id = "latency-gate",
        attachments = list(),
        on_chunk = function(text) {
          if (is.na(state$visible_first)) state$visible_first <- elapsed()
          state$chunks <- c(state$chunks, text)
        },
        on_done = function(...) state$done <- state$done + 1L,
        on_error = function(message) state$error <- message,
        on_tool_call = function(...) stop("Unexpected tool call"),
        on_tool_result = function(...) stop("Unexpected tool result"),
        on_thinking = NULL, on_image = NULL, on_artifact = NULL,
        is_cancelled = function() FALSE,
        wait_for_approval = function(...) stop("Unexpected permission request"),
        register_cancel = function(fn) invisible(NULL)
      ))
      promises::then(result, function(value) {
        state$settled <- TRUE
        NULL
      }, function(error) {
        state$error <- conditionMessage(error)
        state$settled <- TRUE
        NULL
      })
    })
    deadline <- Sys.time() + 10
    while (!state$settled || !later::loop_empty(loop)) {
      later::run_now(0.01, loop = loop)
      if (Sys.time() > deadline) stop("Codeagent latency gate timed out")
    }
    if (!is.null(state$error)) stop(state$error)
    expected <- paste(sprintf("fragment-%02d ", seq_len(20L)), collapse = "")
    stopifnot(state$done == 1L, identical(paste(state$chunks, collapse = ""), expected))
    if (citations) {
      stopifnot(length(state$chunks) == 1L,
                state$visible_first >= state$provider_finished)
    } else {
      stopifnot(length(state$chunks) == 20L,
                state$visible_first < state$provider_finished)
    }
    data.frame(
      web_citations = citations, upstream_chunks = 20L, visible_chunks = length(state$chunks),
      provider_first_seconds = state$provider_first,
      codeagent_first_seconds = state$codeagent_first,
      handler_first_seconds = state$visible_first,
      provider_complete_seconds = state$provider_finished,
      handler_complete_seconds = elapsed(),
      codeagent_delay_seconds = state$codeagent_first - state$provider_first,
      adapter_delay_seconds = state$visible_first - state$codeagent_first
    )
  }
  results <- rbind(measure(FALSE), measure(FALSE), measure(TRUE))
  results$process_run <- seq_len(nrow(results))
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  saveRDS(list(
    kind = "installed codeagent and adapter; synthetic ellmer generator",
    identities = identities,
    versions = setNames(vapply(packages, function(package) {
      as.character(packageVersion(package))
    }, character(1)), packages),
    jit = compiler::enableJIT(-1L), deepstack = getOption("shiny.deepstacktrace"),
    results = results
  ), file.path(output, "latency-results.rds"))
  write.table(results, file.path(output, "latency-results.tsv"),
              sep = "\t", row.names = FALSE, quote = FALSE)
  print(results, row.names = FALSE)
  plain <- results[!results$web_citations, , drop = FALSE]
  stopifnot(
    all(plain$codeagent_delay_seconds + plain$adapter_delay_seconds < 0.15),
    plain$handler_complete_seconds[[2L]] < 1.6
  )
  cat("CODEAGENT_LATENCY_GATES_PASSED; default JIT and Shiny deep stacks preserved\n")
})

# Plan 69: exact /reload-skills must replace the current CLI connection so the
# next init_result is authoritative. These tests intentionally target the new
# orchestration helper before production code implements it.

run_reload_skills <- function(thread_id, result, registry, persist_session,
                              disconnect_client, resume_client,
                              publish_commands) {
  shinyAssistantUI:::.claude_reload_skills_thread(
    thread_id = thread_id,
    result = result,
    get_client = function(id) registry[[id]],
    set_client = function(id, client) {
      registry[[id]] <- client
      invisible(client)
    },
    persist_session = persist_session,
    disconnect_client = disconnect_client,
    resume_client = resume_client,
    publish_commands = publish_commands
  )
}

new_reload_client <- function(server_info = list(commands = list(), output_styles = list())) {
  client <- new.env(parent = emptyenv())
  client$get_server_info <- function() server_info
  client
}

test_that("reload-skills publishes an authoritative empty server command snapshot", {
  registry <- new.env(parent = emptyenv())
  registry$current <- new_reload_client()
  published <- list()

  run_reload_skills(
    thread_id = "current",
    result = list(subtype = "success", is_error = FALSE, session_id = "sid-current"),
    registry = registry,
    persist_session = function(...) invisible(NULL),
    disconnect_client = function(...) invisible(NULL),
    resume_client = function(thread_id, session_id) new_reload_client(),
    publish_commands = function(commands, output_styles) {
      published[[length(published) + 1L]] <<- list(
        commands = commands,
        output_styles = output_styles
      )
    }
  )

  expect_length(published, 1L)
  expect_identical(published[[1L]]$commands, list())
  expect_identical(published[[1L]]$output_styles, list())
})

test_that("reload-skills disconnects only the current thread and resumes the persisted SID", {
  registry <- new.env(parent = emptyenv())
  current <- new_reload_client(list(
    commands = list(list(name = "old-command")), output_styles = list()
  ))
  other <- new_reload_client(list(
    commands = list(list(name = "other-command")), output_styles = list()
  ))
  replacement <- new_reload_client(list(
    commands = list(list(name = "new-command")), output_styles = list()
  ))
  registry$current <- current
  registry$other <- other
  events <- character()
  resumed <- list()
  published <- list()

  run_reload_skills(
    thread_id = "current",
    result = list(subtype = "success", is_error = FALSE, session_id = "sid-current"),
    registry = registry,
    persist_session = function(thread_id, session_id) {
      events <<- c(events, paste("persist", thread_id, session_id, sep = ":"))
    },
    disconnect_client = function(client) {
      expect_identical(client, current)
      events <<- c(events, "disconnect:current")
    },
    resume_client = function(thread_id, session_id) {
      events <<- c(events, paste("resume", thread_id, session_id, sep = ":"))
      resumed[[length(resumed) + 1L]] <<- list(thread_id = thread_id, session_id = session_id)
      replacement
    },
    publish_commands = function(commands, output_styles) {
      events <<- c(events, "publish")
      published <<- list(commands = commands, output_styles = output_styles)
    }
  )

  expect_identical(
    events,
    c(
      "persist:current:sid-current",
      "disconnect:current",
      "resume:current:sid-current",
      "publish"
    )
  )
  expect_identical(published$commands, list(list(name = "new-command")))
  expect_identical(published$output_styles, list())
  expect_identical(resumed, list(list(thread_id = "current", session_id = "sid-current")))
  expect_identical(registry$current, replacement)
  expect_identical(registry$other, other)
})

test_that("reload-skills rejects a failed terminal result before reconnecting", {
  registry <- new.env(parent = emptyenv())
  current <- new_reload_client()
  other <- new_reload_client()
  registry$current <- current
  registry$other <- other
  side_effects <- character()

  expect_error(
    run_reload_skills(
      thread_id = "current",
      result = list(
        subtype = "error", is_error = TRUE, session_id = "sid-current",
        result = "reload command failed"
      ),
      registry = registry,
      persist_session = function(...) side_effects <<- c(side_effects, "persist"),
      disconnect_client = function(...) side_effects <<- c(side_effects, "disconnect"),
      resume_client = function(...) {
        side_effects <<- c(side_effects, "resume")
        new_reload_client()
      },
      publish_commands = function(...) side_effects <<- c(side_effects, "publish")
    ),
    "failed"
  )

  expect_length(side_effects, 0L)
  expect_identical(registry$current, current)
  expect_identical(registry$other, other)
})

test_that("reload-skills resume failure never falls back to a fresh client", {
  registry <- new.env(parent = emptyenv())
  current <- new_reload_client()
  other <- new_reload_client()
  registry$current <- current
  registry$other <- other
  resume_sids <- character()
  published <- FALSE

  expect_error(
    run_reload_skills(
      thread_id = "current",
      result = list(subtype = "success", is_error = FALSE, session_id = "sid-current"),
      registry = registry,
      persist_session = function(...) invisible(NULL),
      disconnect_client = function(...) invisible(NULL),
      resume_client = function(thread_id, session_id) {
        resume_sids <<- c(resume_sids, session_id)
        stop("resume unavailable")
      },
      publish_commands = function(...) published <<- TRUE
    ),
    "resume unavailable"
  )

  expect_identical(resume_sids, "sid-current")
  expect_false(anyNA(resume_sids))
  expect_false(published)
  expect_identical(registry$other, other)
})


test_that("strict resume policy propagates failure without ever calling fresh", {
  events <- character()
  expect_error(
    shinyAssistantUI:::.claude_connect_with_resume_policy(
      stored_sid = "sid-current",
      strict_sid = "sid-current",
      connect_resume = function(sid) {
        events <<- c(events, paste0("resume:", sid))
        stop("still unavailable")
      },
      connect_fresh = function() {
        events <<- c(events, "fresh")
        new_reload_client()
      }
    ),
    "still unavailable"
  )
  expect_identical(events, "resume:sid-current")
})

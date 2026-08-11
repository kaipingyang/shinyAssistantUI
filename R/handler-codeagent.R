#' Use codeagent as the backend engine
#'
#' Adapter that lets [assistantUIServer()] drive a
#' \href{https://github.com/kaipingyang/codeagent}{codeagent} agent instead of a
#' bare `ellmer::Chat` — gaining codeagent's harness (agent loop, central
#' permission gate, compaction, skills/hooks, sessions, and rich tool output).
#'
#' When a client has an active `DataShield`, assistant text is held server-side,
#' scanned as one complete response, and only then released to the browser.
#' Thinking, raw tool arguments, and rich display payloads are suppressed in
#' this mode so they cannot bypass the shield through another UI callback.
#'
#' @param permission_mode A current codeagent permission mode: `"default"`,
#'   `"plan"`, `"accept_edits"`, `"bypass"`, `"dont_ask"`, `"auto"`, or
#'   `"bubble"`. `"bypass"` auto-runs tools and is for trusted environments.
#' @param client_factory `function()` returning a codeagent client. Called once
#'   per thread and cached for the lifetime of this handler.
#' @param approval_tools Optional tool names to additionally force through the
#'   approval card, on top of `permission_mode`.
#' @param store Optional persistence adapter with `save(thread_id, chat, ...)`.
#'   It receives the underlying ellmer chat after successful non-Shield turns.
#'   Shield-backed turns are not persisted by this adapter.
#' @param stream_fn Advanced/testing streaming function. Defaults to
#'   `codeagent::codeagent_stream_async`.
#' @param gate_fn Advanced/testing permission-gate installer. Defaults to
#'   `codeagent::install_permission_gate`.
#'
#' @return A `coro::async` handler suitable for [assistantUIServer()]. It has
#'   `warmup` and `teardown` attributes for session lifecycle management.
#' @seealso [make_ellmer_handler()] for the lighter bare-ellmer backend.
#' @export
make_codeagent_handler <- function(client_factory,
                                    approval_tools  = character(0),
                                    permission_mode = "default",
                                    store           = NULL,
                                    stream_fn       = NULL,
                                    gate_fn         = NULL) {
  if (!is.function(client_factory)) {
    stop("make_codeagent_handler(): `client_factory` must be a function returning a codeagent client.",
         call. = FALSE)
  }
  .codeagent_validate_permission_mode(permission_mode)

  stream_fn <- stream_fn %||% function(...) {
    if (!requireNamespace("codeagent", quietly = TRUE)) {
      stop("make_codeagent_handler() requires the 'codeagent' package. ",
           "Install it, or pass a custom `stream_fn`.", call. = FALSE)
    }
    codeagent::codeagent_stream_async(...)
  }
  gate_fn <- gate_fn %||% function(chat, permission_mode, ask_fn, rules = list()) {
    if (!requireNamespace("codeagent", quietly = TRUE)) {
      stop("make_codeagent_handler() requires the 'codeagent' package. ",
           "Install it, or pass a custom `gate_fn`.", call. = FALSE)
    }
    codeagent::install_permission_gate(
      chat,
      permission_mode = permission_mode,
      ask_fn = ask_fn,
      rules = rules
    )
  }

  gate_rules <- list()
  if (length(approval_tools)) {
    gate_rules <- lapply(
      as.character(approval_tools),
      function(tool) list(
        tool_name = tool,
        behavior = "ask",
        rule_content = NULL
      )
    )
  }

  clients <- list()

  get_client <- function(thread_id) {
    if (!is.null(clients[[thread_id]])) return(clients[[thread_id]])

    client <- client_factory()
    current <- new.env(parent = emptyenv())
    current$on_tool_call <- NULL
    current$on_tool_result <- NULL
    current$wait_for_approval <- NULL
    current$controller <- NULL
    current$project_tool_id <- NULL
    current$project_tool_name <- NULL
    current$shield_tool_ids <- list()
    current$shield_tool_counter <- 0L
    current$shield_active <- .codeagent_has_shield(client)

    # Installed once per thread. It reads the current run's callbacks from a
    # mutable environment so an approval can be resolved asynchronously.
    ask_fn <- function(name, input, id = NULL) {
      tool_call_id <- id %||% ""
      tool_name <- name
      args <- input
      annotations <- list(requiresApproval = TRUE)
      if (isTRUE(current$shield_active)) {
        args <- list()
        annotations$dataShield <- TRUE
        if (is.function(current$project_tool_id)) {
          tool_call_id <- current$project_tool_id(tool_call_id)
        }
        if (is.function(current$project_tool_name)) {
          tool_name <- current$project_tool_name(tool_name)
        }
      }
      if (is.function(current$on_tool_call)) {
        tryCatch(
          current$on_tool_call(
            tool_call_id = tool_call_id,
            tool_name = tool_name,
            args = args,
            annotations = annotations
          ),
          error = function(e) NULL
        )
      }
      if (is.function(current$wait_for_approval)) {
        return(promises::then(
          current$wait_for_approval(tool_call_id),
          function(decision) {
            approved <- decision
            if (is.list(decision)) approved <- decision$approved
            isTRUE(approved)
          }
        ))
      }
      FALSE
    }

    chat_obj <- tryCatch(client$chat, error = function(e) NULL)
    if (!is.null(chat_obj)) {
      tryCatch(
        gate_fn(
          chat_obj,
          permission_mode = permission_mode,
          ask_fn = ask_fn,
          rules = gate_rules
        ),
        error = function(e) NULL
      )
    }

    obj <- list(client = client, current = current)
    clients[[thread_id]] <<- obj
    obj
  }

  coro_handler <- coro::async(function(
    message, thread_id, attachments,
    on_chunk, on_done, on_error,
    on_tool_call, on_tool_result, on_thinking,
    on_image, on_artifact, on_usage = NULL, on_status = NULL,
    is_cancelled, wait_for_approval, register_cancel
  ) {
    obj <- get_client(thread_id)
    client <- obj$client
    current <- obj$current
    shield <- .codeagent_client_shield(client)
    shield_active <- !is.null(shield)

    current$on_tool_call <- on_tool_call
    current$on_tool_result <- on_tool_result
    current$wait_for_approval <- wait_for_approval
    current$shield_active <- shield_active
    current$shield_tool_ids <- list()

    project_tool_id <- function(value) {
      raw_id <- .codeagent_scalar_text(value)
      if (!shield_active) return(raw_id)
      entries <- current$shield_tool_ids
      if (length(entries)) {
        for (entry in entries) {
          if (identical(entry$raw, raw_id)) return(entry$safe)
        }
      }
      current$shield_tool_counter <- current$shield_tool_counter + 1L
      safe_id <- paste0("shield-tool-", current$shield_tool_counter)
      entries[[length(entries) + 1L]] <- list(raw = raw_id, safe = safe_id)
      current$shield_tool_ids <- entries
      safe_id
    }
    project_tool_name <- function(value) {
      raw_name <- .codeagent_scalar_text(value)
      if (!shield_active) return(raw_name)
      .codeagent_safe_browser_label(shield, raw_name, client)
    }
    current$project_tool_id <- project_tool_id
    current$project_tool_name <- project_tool_name

    detach_current <- function() {
      current$on_tool_call <- NULL
      current$on_tool_result <- NULL
      current$wait_for_approval <- NULL
      current$controller <- NULL
      current$project_tool_id <- NULL
      current$project_tool_name <- NULL
      current$shield_tool_ids <- list()
      invisible(NULL)
    }

    atts <- attachments %||% list()
    image_atts <- Filter(function(att) identical(att$type, "image"), atts)
    text_sections <- .attachment_text_sections(atts)
    full_message <- message %||% ""
    if (nzchar(text_sections)) {
      full_message <- paste0(text_sections, "\n\n", full_message)
    }

    if (shield_active) {
      safe_prompt <- .codeagent_scan_prompt(shield, full_message, client)
      if (!isTRUE(safe_prompt$released)) {
        if (is.function(on_status)) {
          on_status("data_shield", "Prompt blocked by Data Shield")
        }
        if (is.function(on_chunk)) on_chunk(safe_prompt$text)
        if (is.function(on_done)) on_done()
        detach_current()
        return(invisible(list(
          text = safe_prompt$text,
          usage = NULL,
          stop_reason = "shield_blocked"
        )))
      }
      full_message <- safe_prompt$text
    }

    # OCR scanning is optional upstream and currently passes when tesseract is
    # unavailable. Refuse image input under Shield rather than claiming a safety
    # guarantee we cannot enforce.
    if (shield_active && length(image_atts)) {
      if (is.function(on_status)) {
        on_status("data_shield", "Image blocked by Data Shield")
      }
      if (is.function(on_chunk)) {
        on_chunk("[Data Shield] Image attachments are disabled in protected mode.")
      }
      if (is.function(on_done)) on_done()
      detach_current()
      return(invisible(list(
        text = "[Data Shield] Image attachments are disabled in protected mode.",
        usage = NULL,
        stop_reason = "shield_blocked"
      )))
    }

    stream_input <- full_message
    if (length(image_atts)) {
      if (!requireNamespace("ellmer", quietly = TRUE)) {
        if (is.function(on_error)) {
          on_error("Image attachments require the 'ellmer' package.")
        }
        detach_current()
        return(invisible(NULL))
      }
      image_parts <- lapply(image_atts, function(att) {
        ellmer::content_image_url(att$data)
      })
      stream_input <- c(list(full_message), image_parts)
    }

    controller <- tryCatch(ellmer::stream_controller(), error = function(e) NULL)
    current$controller <- controller
    if (!is.null(controller) && is.function(register_cancel)) {
      register_cancel(function() {
        tryCatch(controller$cancel("User interrupted"), error = function(e) NULL)
      })
    }

    streamed_text <- ""
    terminal_error <- FALSE
    error_reported <- FALSE

    handle_delta <- function(text) {
      scalar <- .codeagent_scalar_text(text)
      if (!nzchar(scalar)) return(invisible(NULL))
      if (shield_active) {
        streamed_text <<- paste0(streamed_text, scalar)
      } else if (is.function(on_chunk)) {
        on_chunk(scalar)
      }
      invisible(NULL)
    }

    handle_thinking <- function(text) {
      if (!shield_active && is.function(on_thinking)) on_thinking(text)
      invisible(NULL)
    }

    handle_tool_request <- function(request) {
      if (!is.function(on_tool_call)) return(invisible(NULL))
      tool_id <- request$id %||% ""
      tool_name <- request$name %||% ""
      args <- request$arguments %||% list()
      annotations <- list(intent = request$intent)
      if (shield_active) {
        tool_id <- project_tool_id(tool_id)
        tool_name <- project_tool_name(tool_name)
        args <- list()
        annotations <- list(dataShield = TRUE)
      }
      tryCatch(
        on_tool_call(
          tool_call_id = tool_id,
          tool_name = tool_name,
          args = args,
          annotations = annotations
        ),
        error = function(e) NULL
      )
      invisible(NULL)
    }

    handle_tool_result <- function(result) {
      if (shield_active) {
        if (is.function(on_tool_result)) {
          raw_value <- .codeagent_safe_tool_value(result$value)
          safe_value <- .codeagent_scan_response(shield, raw_value, client)$text
          tryCatch(
            on_tool_result(
              tool_call_id = project_tool_id(result$id %||% ""),
              result = safe_value,
              is_error = isTRUE(result$is_error)
            ),
            error = function(e) NULL
          )
        }
      } else {
        .codeagent_display_to_ui(result, on_image, on_artifact, on_tool_result)
      }
      invisible(NULL)
    }

    handle_usage <- function(usage) {
      if (!is.function(on_usage) || !is.list(usage)) return(invisible(NULL))
      settings <- .codeagent_client_settings(client)
      tryCatch(
        on_usage(
          cost_usd = .codeagent_optional_number(usage$cost_last),
          tokens = NULL,
          context_tokens = .codeagent_optional_integer(usage$n_tokens),
          turns = NULL,
          duration_ms = NULL,
          model = .codeagent_optional_text(settings$model),
          context_window = .codeagent_optional_integer(usage$model_limit)
        ),
        error = function(e) NULL
      )
      invisible(NULL)
    }

    handle_error <- function(message, recovered = FALSE) {
      cancelled_now <- isTRUE(tryCatch(is_cancelled(), error = function(e) FALSE))
      if (cancelled_now) return(invisible(NULL))
      terminal_error <<- TRUE
      if (!error_reported && is.function(on_error)) {
        visible_message <- .codeagent_scalar_text(message)
        if (shield_active) visible_message <- "codeagent turn failed in protected mode."
        if (!nzchar(visible_message)) visible_message <- "codeagent turn failed."
        on_error(visible_message)
        error_reported <<- TRUE
      }
      invisible(NULL)
    }

    if (shield_active && is.function(on_status)) {
      on_status("data_shield", "Scanning protected output\u2026")
    }

    result <- tryCatch(
      coro::await(stream_fn(
        client,
        stream_input,
        on_delta = handle_delta,
        on_thinking = handle_thinking,
        on_tool_request = handle_tool_request,
        on_tool_result = handle_tool_result,
        on_error = handle_error,
        on_usage = handle_usage,
        controller = controller,
        session_id = thread_id
      )),
      error = function(e) {
        cancelled_now <- isTRUE(tryCatch(is_cancelled(), error = function(e2) FALSE))
        if (!cancelled_now) handle_error(conditionMessage(e), FALSE)
        NULL
      }
    )

    cancelled <- isTRUE(tryCatch(is_cancelled(), error = function(e) FALSE))
    stop_reason <- "completed"
    if (is.list(result) && !is.null(result$stop_reason)) {
      stop_reason <- .codeagent_scalar_text(result$stop_reason)
      if (!nzchar(stop_reason)) stop_reason <- "completed"
    }
    if (identical(stop_reason, "error")) terminal_error <- TRUE

    terminal_text <- streamed_text
    if (is.list(result)) {
      result_text <- .codeagent_scalar_text(result$text)
      if (nzchar(result_text)) terminal_text <- result_text
    }

    if (shield_active && !cancelled && !terminal_error) {
      safe_response <- .codeagent_scan_response(shield, terminal_text, client)
      if (is.function(on_chunk) && nzchar(safe_response$text)) {
        on_chunk(safe_response$text)
      }
    }

    if (shield_active && is.function(on_status)) on_status("idle", NULL)

    successful <- !cancelled && !terminal_error &&
      stop_reason %in% c("completed", "shield_blocked")
    if (successful && !is.null(store) && !shield_active) {
      title <- substr(message %||% "", 1, 40)
      first_msg <- substr(message %||% "", 1, 200)
      chat_to_save <- tryCatch(client$chat, error = function(e) NULL)
      if (is.null(chat_to_save)) chat_to_save <- client
      tryCatch(
        store$save(thread_id, chat_to_save, title = title, first_msg = first_msg),
        error = function(e) NULL
      )
    }

    if (successful && is.function(on_done)) on_done()
    if (terminal_error && !error_reported && !cancelled && is.function(on_error)) {
      on_error("codeagent turn failed.")
    }

    detach_current()
    invisible(result)
  })

  attr(coro_handler, "warmup") <- function(thread_id) {
    get_client(thread_id)
    invisible(NULL)
  }

  attr(coro_handler, "teardown") <- function() {
    registry <- clients
    clients <<- list()
    closed_shields <- list()
    for (obj in registry) {
      controller <- tryCatch(obj$current$controller, error = function(e) NULL)
      if (!is.null(controller)) {
        tryCatch(controller$cancel("Session ended"), error = function(e) NULL)
      }
      shield <- .codeagent_client_shield(obj$client)
      if (is.null(shield)) next
      already_closed <- any(vapply(
        closed_shields,
        function(previous) identical(previous, shield),
        logical(1)
      ))
      if (!already_closed) {
        close_fn <- tryCatch(shield$close, error = function(e) NULL)
        if (is.function(close_fn)) tryCatch(close_fn(), error = function(e) NULL)
        closed_shields[[length(closed_shields) + 1L]] <- shield
      }
    }
    invisible(NULL)
  }

  coro_handler
}

.codeagent_permission_modes <- c(
  "default", "plan", "accept_edits", "bypass", "dont_ask", "auto", "bubble"
)

.codeagent_validate_permission_mode <- function(mode) {
  valid <- .codeagent_permission_modes
  if (!is.character(mode) || length(mode) != 1L || is.na(mode) || !mode %in% valid) {
    stop(
      "make_codeagent_handler(): `permission_mode` must be one of: ",
      paste(valid, collapse = ", "),
      ". Use codeagent's current spelling `bypass` (not `bypassPermissions`) ",
      "and `accept_edits` (not `acceptEdits`).",
      call. = FALSE
    )
  }
  invisible(mode)
}

.codeagent_client_settings <- function(client) {
  settings <- tryCatch(client$settings, error = function(e) NULL)
  if (!is.list(settings)) settings <- list()
  settings
}

.codeagent_client_shield <- function(client) {
  shield <- tryCatch(client$data_shield, error = function(e) NULL)
  if (is.null(shield)) {
    settings <- .codeagent_client_settings(client)
    shield <- settings$data_shield_engine
  }
  if (is.null(shield)) return(NULL)
  scan_fn <- tryCatch(shield$scan_response, error = function(e) NULL)
  if (!inherits(shield, "DataShield") || !is.function(scan_fn)) return(NULL)
  shield
}

.codeagent_has_shield <- function(client) !is.null(.codeagent_client_shield(client))

.codeagent_scalar_text <- function(value) {
  if (!is.character(value) || length(value) == 0L || is.na(value[[1L]])) return("")
  value[[1L]]
}

.codeagent_optional_text <- function(value) {
  text <- .codeagent_scalar_text(value)
  if (!nzchar(text)) return(NULL)
  text
}

.codeagent_optional_number <- function(value) {
  numbers <- suppressWarnings(as.numeric(value %||% NA_real_))
  if (length(numbers) == 0L) return(NULL)
  number <- numbers[[1L]]
  if (!is.finite(number)) return(NULL)
  number
}

.codeagent_optional_integer <- function(value) {
  number <- .codeagent_optional_number(value)
  if (is.null(number)) return(NULL)
  as.integer(number)
}

.codeagent_scan_prompt <- function(shield, text, client) {
  blocked <- "[Data Shield] Prompt blocked because it could not be scanned safely."
  settings <- .codeagent_client_settings(client)
  on_fail <- .codeagent_scalar_text(settings$data_shield_prompt_on_fail)
  if (!nzchar(on_fail)) on_fail <- "redact"
  scanners <- settings$data_shield_input_scanners
  if (is.null(scanners)) scanners <- c("value_match", "regex")

  result <- tryCatch(
    shield$scan_prompt(
      text,
      on_fail = on_fail,
      scanners = scanners,
      context = list(source = "shinyAssistantUI")
    ),
    error = function(e) NULL
  )
  if (!is.list(result)) {
    return(list(text = blocked, action = "block", released = FALSE))
  }
  action <- .codeagent_scalar_text(result$action)
  safe_text <- .codeagent_scalar_text(result$text)
  valid <- action %in% c("pass", "redact") && !is.null(result$text) &&
    is.character(result$text) && length(result$text) == 1L && !is.na(result$text)
  if (!valid) return(list(text = blocked, action = "block", released = FALSE))
  list(text = safe_text, action = action, released = TRUE)
}

.codeagent_safe_browser_label <- function(shield, text, client) {
  scanned <- .codeagent_scan_response(shield, text, client)
  if (identical(scanned$action, "block")) return("Protected tool")
  label <- gsub("[\\r\\n\\t]+", " ", scanned$text)
  label <- trimws(label)
  if (!nzchar(label)) return("Protected tool")
  substr(label, 1L, 80L)
}

.codeagent_safe_tool_value <- function(value) {
  text <- .codeagent_scalar_text(value)
  if (nzchar(text) || (is.character(value) && length(value) == 1L)) return(text)
  if (is.null(value)) return("")
  tryCatch(
    as.character(jsonlite::toJSON(value, auto_unbox = TRUE, pretty = FALSE)),
    error = function(e) "[Data Shield] Tool result unavailable."
  )
}

.codeagent_scan_response <- function(shield, text, client) {
  blocked <- "[Data Shield] Response blocked because it could not be released safely."
  settings <- .codeagent_client_settings(client)
  on_fail <- .codeagent_scalar_text(settings$data_shield_response_on_fail)
  if (!nzchar(on_fail)) on_fail <- "redact"
  scanners <- settings$data_shield_output_scanners
  if (is.null(scanners)) scanners <- c("value_match", "regex")

  result <- tryCatch(
    shield$scan_response(
      text,
      on_fail = on_fail,
      scanners = scanners,
      context = list(source = "shinyAssistantUI")
    ),
    error = function(e) NULL
  )
  if (!is.list(result)) return(list(text = blocked, action = "block"))
  action <- .codeagent_scalar_text(result$action)
  safe_text <- .codeagent_scalar_text(result$text)
  if (!action %in% c("pass", "redact") || is.null(result$text) ||
      !is.character(result$text) || length(result$text) != 1L || is.na(result$text)) {
    return(list(text = blocked, action = "block"))
  }
  list(text = safe_text, action = action)
}

# Split codeagent's typed tool display to assistant-ui rich callbacks. This path
# is used only without Data Shield; protected turns deliberately use plain
# shielded `value` results instead of trusting parallel display payloads.
.codeagent_display_to_ui <- function(res, on_image, on_artifact, on_tool_result) {
  id <- res$id %||% ""
  value <- tryCatch(as.character(res$value %||% ""), error = function(e) "")
  is_error <- isTRUE(res$is_error)
  display <- tryCatch(res$display, error = function(e) NULL)
  toolcard <- tryCatch(display$toolcard, error = function(e) NULL)
  kind <- tryCatch(toolcard$kind, error = function(e) NULL) %||% "text"
  payload <- tryCatch(toolcard$payload, error = function(e) list()) %||% list()
  title <- tryCatch(
    as.character(toolcard$title %||% res$name %||% kind),
    error = function(e) kind
  )

  if (identical(kind, "image") && is.function(on_image)) {
    images <- payload$images %||% list()
    if (length(images)) {
      for (image in images) {
        mime <- image$mime %||% image$type %||% "image/png"
        if (!grepl("/", mime)) mime <- paste0("image/", mime)
        uri <- image$src %||% ""
        if (!is.null(image$b64)) uri <- paste0("data:", mime, ";base64,", image$b64)
        if (!nzchar(uri)) uri <- value
        tryCatch(on_image(uri), error = function(e) NULL)
      }
      return(invisible())
    }
  }

  if (kind %in% c("code", "diff") && is.function(on_artifact)) {
    content <- tryCatch(as.character(payload$text %||% value), error = function(e) value)
    lang <- payload$lang %||% "r"
    if (identical(kind, "diff")) lang <- "diff"
    tryCatch(
      on_artifact(
        id = id,
        title = title,
        content = content,
        type = "code",
        lang = lang
      ),
      error = function(e) NULL
    )
    return(invisible())
  }

  if (identical(kind, "table") && is.function(on_artifact)) {
    markdown <- tryCatch(as.character(display$markdown %||% value), error = function(e) value)
    tryCatch(
      on_artifact(
        id = id,
        title = title,
        content = markdown,
        type = "markdown"
      ),
      error = function(e) NULL
    )
    return(invisible())
  }

  if (is.function(on_tool_result)) {
    tryCatch(
      on_tool_result(
        tool_call_id = id,
        result = value,
        is_error = is_error
      ),
      error = function(e) NULL
    )
  }
  invisible()
}

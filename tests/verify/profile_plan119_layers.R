#!/usr/bin/env Rscript
# Plan 119 controlled four-layer partial-message A/B profiling pilot.
# This fixture uses synthetic frames only: it never reads project source or credentials.
# Driver examples (always run through the project bounded runner):
#   AUI_PROFILE_LAYER=transport AUI_PROFILE_PASS=pss Rscript tests/verify/profile_plan119_layers.R
#   AUI_PROFILE_LAYER=browser-full AUI_PROFILE_ARM=true AUI_PROFILE_PASS=alloc Rscript tests/verify/profile_plan119_layers.R

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
PROJECT <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
OUT_DIR <- Sys.getenv("AUI_PROFILE_OUT_DIR", "/tmp/aui-plan119-profile")
SCRIPT <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1L]), mustWork = TRUE)
LAYERS <- c("transport", "handler", "production-handler", "shiny-discard", "browser-full")
ROLE <- Sys.getenv("AUI_PROFILE_ROLE", "driver")
scalar_int <- function(name, default, lower = 1L, upper = .Machine$integer.max) {
  value <- suppressWarnings(as.integer(Sys.getenv(name, as.character(default))))
  if (length(value) != 1L || is.na(value) || value < lower || value > upper) stop("Invalid ", name)
  value
}
scalar_num <- function(name, default, lower = 0) {
  value <- suppressWarnings(as.numeric(Sys.getenv(name, as.character(default))))
  if (length(value) != 1L || is.na(value) || !is.finite(value) || value < lower) stop("Invalid ", name)
  value
}
parse_bool <- function(value, allow_both = FALSE) {
  value <- tolower(value)
  if (allow_both && value %in% c("", "both")) return(NA)
  if (value == "true") return(TRUE)
  if (value == "false") return(FALSE)
  stop("AUI_PROFILE_ARM must be true, false, or unset/both")
}
json_text <- function(value, pretty = FALSE) as.character(jsonlite::toJSON(
  value, auto_unbox = TRUE, null = "null", digits = NA, pretty = pretty
))
write_json_atomic <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- paste0(path, ".", Sys.getpid(), ".tmp")
  writeLines(json_text(value, pretty = TRUE), temporary, useBytes = TRUE)
  if (!file.rename(temporary, path)) stop("Could not atomically write ", path)
}
read_json <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)
canonical_hash <- function(value) {
  path <- tempfile("aui-plan119-hash-")
  on.exit(unlink(path), add = TRUE)
  writeChar(json_text(value), path, eos = NULL, useBytes = TRUE)
  unname(tools::md5sum(path))
}
checksum32 <- function(strings) {
  total <- 0
  for (text in strings) total <- (total + sum(utf8ToInt(enc2utf8(text)))) %% 4294967296
  sprintf("%08x", as.integer(total %% 2147483647))
}

TOOLS <- scalar_int("AUI_PROFILE_TOOLS", 20L, 1L, 500L)
PAYLOAD_BYTES <- scalar_int("AUI_PROFILE_PAYLOAD_BYTES", 4096L, 128L, 1024L * 1024L)
PASS <- tolower(Sys.getenv("AUI_PROFILE_PASS", "pss"))
if (!PASS %in% c("pss", "alloc")) stop("AUI_PROFILE_PASS must be pss or alloc")
LAYER <- Sys.getenv("AUI_PROFILE_LAYER", "")
if (!LAYER %in% LAYERS) stop("AUI_PROFILE_LAYER must be one of: ", paste(LAYERS, collapse = ", "))
ARM <- parse_bool(Sys.getenv("AUI_PROFILE_ARM", if (ROLE == "subject") "false" else "both"), allow_both = ROLE == "driver")
DEADLINE_S <- scalar_num("AUI_PROFILE_DEADLINE_S", 90, 5)
PSS_CEILING_BYTES <- scalar_num("AUI_PROFILE_PSS_CEILING_BYTES", 1536 * 1024^2, 64 * 1024^2)
CGROUP_HEADROOM_BYTES <- scalar_num("AUI_PROFILE_CGROUP_HEADROOM_BYTES", 512 * 1024^2, 0)
SAMPLE_INTERVAL_S <- scalar_num("AUI_PROFILE_SAMPLE_INTERVAL_S", 0.02, 0.01)

make_args <- function(index) list(
  file_path = sprintf("profile-%03d.txt", index),
  content = paste0("PLAN119_SYNTHETIC_", sprintf("%03d", index), "_", strrep(letters[(index %% 26L) + 1L], PAYLOAD_BYTES))
)
make_semantics <- function() list(
  tools = lapply(seq_len(TOOLS), function(index) list(
    id = sprintf("profile-tool-%03d", index), name = "Write",
    args = make_args(index), result = sprintf("synthetic-result-%03d", index), is_error = FALSE
  )),
  text = sprintf("PLAN119_FINAL tools=%d", TOOLS)
)
expected_hash <- function() canonical_hash(make_semantics())
stream_payload <- function(event, uuid) list(
  type = "stream_event", uuid = uuid, session_id = "plan119-synthetic-session", event = event
)
assistant_payload <- function() list(
  type = "assistant", uuid = "plan119-final-assistant", session_id = "plan119-synthetic-session",
  message = list(role = "assistant", content = c(
    lapply(seq_len(TOOLS), function(index) list(
      type = "tool_use", id = sprintf("profile-tool-%03d", index), name = "Write", input = make_args(index)
    )),
    list(list(type = "text", text = sprintf("PLAN119_FINAL tools=%d", TOOLS)))
  ))
)
result_payload <- function(index) list(
  type = "user", uuid = sprintf("plan119-result-%03d", index), session_id = "plan119-synthetic-session",
  message = list(role = "user", content = list(list(
    type = "tool_result", tool_use_id = sprintf("profile-tool-%03d", index),
    content = sprintf("synthetic-result-%03d", index), is_error = FALSE
  ))),
  tool_use_result = sprintf("synthetic-result-%03d", index)
)
raw_frames <- function(partial) {
  frames <- character()
  if (partial) for (index in seq_len(TOOLS)) {
    id <- sprintf("profile-tool-%03d", index)
    arg_text <- json_text(make_args(index))
    frames <- c(frames, json_text(stream_payload(list(
      type = "content_block_start", index = index - 1L,
      content_block = list(type = "tool_use", id = id, name = "Write", input = list())
    ), paste0("start-", index))))
    starts <- seq.int(1L, nchar(arg_text, type = "chars"), by = 256L)
    for (start in starts) frames <- c(frames, json_text(stream_payload(list(
      type = "content_block_delta", index = index - 1L,
      delta = list(type = "input_json_delta", partial_json = substr(arg_text, start, start + 255L))
    ), paste0("delta-", index, "-", start))))
    frames <- c(frames, json_text(stream_payload(list(
      type = "content_block_stop", index = index - 1L
    ), paste0("stop-", index))))
  }
  c(frames, json_text(assistant_payload()), vapply(seq_len(TOOLS), function(index) {
    json_text(result_payload(index))
  }, character(1)))
}

proc_rollup <- function(pid) {
  status_path <- sprintf("/proc/%d/status", pid)
  rollup_path <- sprintf("/proc/%d/smaps_rollup", pid)
  parse_fields <- function(path) {
    lines <- tryCatch(suppressWarnings(readLines(path, warn = FALSE)), error = function(error) character())
    values <- list()
    for (line in lines) {
      match <- regexec("^([A-Za-z_]+):[[:space:]]*([0-9]+)[[:space:]]*kB", line)
      parts <- regmatches(line, match)[[1L]]
      if (length(parts) == 3L) values[[parts[[2L]]]] <- as.numeric(parts[[3L]]) * 1024
    }
    values
  }
  status <- parse_fields(status_path)
  rollup <- parse_fields(rollup_path)
  list(
    available = length(status) > 0L || length(rollup) > 0L,
    pss_bytes = rollup$Pss %||% NA_real_, rss_bytes = status$VmRSS %||% rollup$Rss %||% NA_real_,
    private_dirty_bytes = rollup$Private_Dirty %||% NA_real_, anonymous_bytes = rollup$Anonymous %||% NA_real_,
    vm_size_bytes = status$VmSize %||% NA_real_, threads = status$Threads %||% NA_real_
  )
}
smaps_categories <- function(pid) {
  lines <- tryCatch(suppressWarnings(readLines(sprintf("/proc/%d/smaps", pid), warn = FALSE)), error = function(error) character())
  if (!length(lines)) return(list(available = FALSE))
  totals <- new.env(parent = emptyenv()); category <- "other"
  add <- function(field, value) {
    key <- paste(category, field, sep = ".")
    assign(key, get0(key, totals, ifnotfound = 0) + value, totals)
  }
  for (line in lines) {
    if (grepl("^[0-9a-f]+-[0-9a-f]+ ", line)) {
      path <- sub("^.*[[:space:]]+[0-9]+[[:space:]]+", "", line)
      category <- if (grepl("\\[heap\\]", path)) "heap" else if (grepl("\\[stack", path)) "stack" else if (!grepl("/", path)) "anonymous" else "file"
    } else {
      match <- regexec("^(Pss|Private_Dirty|Anonymous):[[:space:]]*([0-9]+)[[:space:]]*kB", line)
      parts <- regmatches(line, match)[[1L]]
      if (length(parts) == 3L) add(tolower(parts[[2L]]), as.numeric(parts[[3L]]) * 1024)
    }
  }
  values <- as.list(totals, all.names = TRUE); values$available <- TRUE; values
}
read_cgroup <- function() {
  read_num <- function(path) {
    value <- tryCatch(readLines(path, n = 1L, warn = FALSE), error = function(error) NA_character_)
    if (!length(value) || identical(value, "max")) return(NA_real_)
    suppressWarnings(as.numeric(value[[1L]]))
  }
  list(current = read_num("/sys/fs/cgroup/memory.current"), max = read_num("/sys/fs/cgroup/memory.max"))
}

process_tree_pids <- function(root_pid) {
  root <- tryCatch(ps::ps_handle(as.integer(root_pid)), error = function(error) NULL)
  if (is.null(root) || !tryCatch(ps::ps_is_running(root), error = function(error) FALSE)) return(integer())
  children <- tryCatch(ps::ps_children(root, recursive = TRUE), error = function(error) list())
  unique(c(as.integer(root_pid), vapply(children, function(handle) ps::ps_pid(handle), integer(1))))
}
process_tree_pss <- function(root_pid) {
  pids <- process_tree_pids(root_pid)
  values <- vapply(pids, function(pid) proc_rollup(pid)$pss_bytes %||% NA_real_, numeric(1))
  list(pids = pids, pss_bytes = if (any(is.finite(values))) sum(values[is.finite(values)]) else NA_real_)
}
run_sampler <- function() {
  subject_pid <- scalar_int("AUI_PROFILE_SUBJECT_PID", 0L, 1L)
  output_path <- Sys.getenv("AUI_PROFILE_SAMPLER_RESULT_PATH", "")
  sampler_ready <- Sys.getenv("AUI_PROFILE_SAMPLER_READY_PATH", "")
  abort_path <- Sys.getenv("AUI_PROFILE_ABORT_PATH", "")
  chrome_pid_path <- Sys.getenv("AUI_PROFILE_CHROME_PID_PATH", "")
  active_path <- phase_path("AUI_PROFILE_ACTIVE_PATH")
  finished_path <- phase_path("AUI_PROFILE_WORKLOAD_FINISHED_PATH")
  active_capture_path <- phase_path("AUI_PROFILE_ACTIVE_CAPTURE_PATH")
  done_path <- phase_path("AUI_PROFILE_WORKLOAD_DONE_PATH")
  post_gc_path <- phase_path("AUI_PROFILE_POST_GC_PATH")
  if (!nzchar(output_path) || !nzchar(sampler_ready) || !nzchar(abort_path)) stop("sampler paths missing")
  started <- Sys.time(); samples <- list(); aborted <- NULL
  sample_once <- function(phase) {
    r <- proc_rollup(subject_pid)
    chrome <- list(pids = integer(), pss_bytes = NA_real_)
    if (nzchar(chrome_pid_path) && file.exists(chrome_pid_path)) {
      chrome_pid <- suppressWarnings(as.integer(readLines(chrome_pid_path, n = 1L, warn = FALSE)))
      if (length(chrome_pid) == 1L && !is.na(chrome_pid)) chrome <- process_tree_pss(chrome_pid)
    }
    item <- list(
      elapsed_s = as.numeric(difftime(Sys.time(), started, units = "secs")), phase = phase,
      r_subject = r, chrome_tree_pss_bytes = chrome$pss_bytes, chrome_tree_pids = chrome$pids
    )
    samples[[length(samples) + 1L]] <<- item
    cgroup <- read_cgroup()
    if (is.finite(r$pss_bytes) && r$pss_bytes > PSS_CEILING_BYTES) aborted <<- "r_subject_pss_ceiling"
    if (is.finite(cgroup$current) && is.finite(cgroup$max) && cgroup$max - cgroup$current < CGROUP_HEADROOM_BYTES) aborted <<- "cgroup_headroom"
    if (item$elapsed_s > DEADLINE_S) aborted <<- "subject_deadline"
    if (!is.null(aborted) && !file.exists(abort_path)) {
      writeLines(aborted, abort_path)
      handle <- tryCatch(ps::ps_handle(subject_pid), error = function(error) NULL)
      if (!is.null(handle)) try(ps::ps_kill(handle), silent = TRUE)
    }
  }
  sample_once("initialized")
  writeLines(as.character(Sys.getpid()), sampler_ready)
  repeat {
    phase <- if (file.exists(post_gc_path)) "post-gc" else if (file.exists(done_path)) "workload-done" else if (file.exists(active_path)) "active" else "initialized"
    sample_once(phase)
    if (identical(phase, "active") && file.exists(finished_path) && !file.exists(active_capture_path)) {
      writeLines(format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"), active_capture_path)
    }
    subject_alive <- length(process_tree_pids(subject_pid)) > 0L
    if (identical(phase, "post-gc") || !subject_alive || !is.null(aborted)) break
    Sys.sleep(SAMPLE_INTERVAL_S)
  }
  finite_max <- function(values) if (any(is.finite(values))) max(values[is.finite(values)]) else NA_real_
  finite_last <- function(values) if (any(is.finite(values))) tail(values[is.finite(values)], 1L) else NA_real_
  phase_values <- function(phase, field) {
    selected <- Filter(function(item) identical(item$phase, phase), samples)
    if (!length(selected)) return(numeric())
    vapply(selected, field, numeric(1))
  }
  r_pss <- function(item) item$r_subject$pss_bytes %||% NA_real_
  r_rss <- function(item) item$r_subject$rss_bytes %||% NA_real_
  chrome_pss <- function(item) item$chrome_tree_pss_bytes %||% NA_real_
  initialized_pss <- phase_values("initialized", r_pss)
  active_pss <- phase_values("active", r_pss)
  post_pss <- phase_values("post-gc", r_pss)
  all_rss <- vapply(samples, r_rss, numeric(1))
  write_json_atomic(list(
    sampler_pid = Sys.getpid(), subject_pid = subject_pid, interval_s = SAMPLE_INTERVAL_S,
    samples = samples, sample_count = length(samples), active_sample_count = length(active_pss), abort = aborted,
    r_subject_baseline_pss_bytes = finite_last(initialized_pss),
    r_subject_active_peak_pss_bytes = finite_max(active_pss),
    r_subject_post_gc_pss_bytes = finite_last(post_pss),
    r_subject_peak_rss_bytes = finite_max(all_rss),
    chrome_tree_active_peak_pss_bytes = finite_max(phase_values("active", chrome_pss)),
    chrome_tree_post_gc_pss_bytes = finite_last(phase_values("post-gc", chrome_pss))
  ), output_path)
  if (!is.null(aborted)) quit(save = "no", status = 2L)
}
start_alloc <- function() {
  path <- Sys.getenv("AUI_PROFILE_ALLOC_PATH", "")
  if (PASS == "alloc") {
    if (!nzchar(path)) stop("alloc subject has no AUI_PROFILE_ALLOC_PATH")
    utils::Rprofmem(path, threshold = 1L)
  }
  invisible(path)
}
stop_alloc <- function() if (PASS == "alloc") utils::Rprofmem(NULL)
subject_result_path <- function() {
  path <- Sys.getenv("AUI_PROFILE_RESULT_PATH", "")
  if (!nzchar(path)) stop("subject has no result path")
  path
}
phase_path <- function(name) {
  path <- Sys.getenv(name, "")
  if (!nzchar(path)) stop("Missing phase path: ", name)
  path
}
mark_phase <- function(name, value = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")) {
  writeLines(as.character(value), phase_path(name), useBytes = TRUE)
}
subject_handshake <- function() {
  ready <- phase_path("AUI_PROFILE_READY_PATH"); go <- phase_path("AUI_PROFILE_GO_PATH")
  writeLines(as.character(Sys.getpid()), ready)
  deadline <- Sys.time() + 15
  while (!file.exists(go)) {
    if (Sys.time() >= deadline) stop("subject timed out waiting for driver")
    Sys.sleep(0.01)
  }
  mark_phase("AUI_PROFILE_ACTIVE_PATH")
  # Let the independent 10-20ms sampler observe active phase before short workloads.
  Sys.sleep(max(0.03, SAMPLE_INTERVAL_S * 1.5))
}
finish_subject_workload <- function(after_active_capture = NULL) {
  # Keep active objects resident until the independent sampler confirms a post-workload capture.
  mark_phase("AUI_PROFILE_WORKLOAD_FINISHED_PATH")
  capture_path <- phase_path("AUI_PROFILE_ACTIVE_CAPTURE_PATH")
  deadline <- Sys.time() + min(10, DEADLINE_S / 2)
  while (!file.exists(capture_path)) {
    if (Sys.time() >= deadline) stop("sampler did not acknowledge active workload capture")
    Sys.sleep(0.01)
  }
  if (is.function(after_active_capture)) after_active_capture()
  mark_phase("AUI_PROFILE_WORKLOAD_DONE_PATH")
  invisible(gc(full = TRUE))
  mark_phase("AUI_PROFILE_POST_GC_PATH")
  Sys.sleep(max(0.06, SAMPLE_INTERVAL_S * 3))
}
if (ROLE == "sampler") {
  run_sampler()
  quit(save = "no", status = 0L)
}

parse_frames <- function(frames) {
  parse_message <- get("parse_message", asNamespace("ClaudeAgentSDK"))
  lapply(frames, parse_message)
}
reduce_typed <- function(messages) {
  tools <- list(); text <- character(); results <- list()
  extract_results <- get(".claude_user_tool_results", asNamespace("shinyAssistantUI"))
  for (message in messages) {
    if (inherits(message, "AssistantMessage")) for (block in message$content %||% list()) {
      if (inherits(block, "ToolUseBlock")) tools[[block$id]] <- list(
        id = block$id, name = block$name, args = block$input
      )
      if (inherits(block, "TextBlock")) text <- c(text, block$text)
    }
    if (inherits(message, "UserMessage")) for (result in extract_results(message)) {
      results[[result$tool_use_id]] <- list(result = result$result, is_error = isTRUE(result$is_error))
    }
  }
  ids <- sort(names(tools))
  list(tools = lapply(ids, function(id) c(tools[[id]], results[[id]])), text = paste0(text, collapse = ""))
}
run_transport_subject <- function() {
  suppressPackageStartupMessages({library(ClaudeAgentSDK); library(shinyAssistantUI); library(jsonlite)})
  frames <- raw_frames(ARM); subject_handshake(); start_alloc(); started <- proc.time()[["elapsed"]]
  messages <- parse_frames(frames)
  parsed_count <- length(messages)
  semantic <- reduce_typed(messages)
  elapsed <- proc.time()[["elapsed"]] - started
  stop_alloc(); frames_bytes <- sum(nchar(frames, type = "bytes"))
  finish_subject_workload(); messages <- NULL; frames <- NULL
  write_json_atomic(list(
    ok = identical(canonical_hash(semantic), expected_hash()), semantic_hash = canonical_hash(semantic),
    expected_hash = expected_hash(), elapsed_s = elapsed, raw_bytes = frames_bytes,
    parsed_messages = parsed_count,
    partial_events = if (ARM) parsed_count - TOOLS - 1L else 0L,
    tool_count = length(semantic$tools), callback_counts = list(), coordinator = NULL
  ), subject_result_path())
}
run_handler_subject <- function() {
  suppressPackageStartupMessages({library(ClaudeAgentSDK); library(shinyAssistantUI); library(jsonlite)})
  frames <- raw_frames(ARM); subject_handshake(); start_alloc(); started <- proc.time()[["elapsed"]]
  messages <- parse_frames(frames)
  queue <- messages; callbacks <- new.env(parent = emptyenv())
  callbacks$starts <- 0L; callbacks$deltas <- 0L; callbacks$calls <- 0L
  callbacks$results <- 0L; callbacks$text <- 0L; callbacks$stop_parses <- 0L
  blocks <- new.env(parent = emptyenv()); final_messages <- list(); reconstructed <- list(); batch_size <- 16L
  poll <- function() {
    if (!length(queue)) return(list())
    take <- seq_len(min(batch_size, length(queue))); value <- queue[take]; queue <<- queue[-take]; value
  }
  coordinator <- get(".new_claude_consumer_coordinator", asNamespace("shinyAssistantUI"))(
    poll_messages = poll, schedule = function(callback, delay) function() NULL, now = Sys.time,
    on_idle_event = function(...) NULL, on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason, on_complete) on_complete(), deny_idle_permission = function(...) NULL,
    interrupt = function() NULL
  )
  acquired <- FALSE; coordinator$acquire("foreground:profile", function() acquired <<- TRUE)
  if (!acquired) stop("coordinator did not grant fresh foreground owner")
  buffered_max <- 0L; processed <- 0L
  # Equivalent injectable consumer: real SDK message classes + real production coordinator.
  # Both arms execute exactly one identical final no-op callback payload per tool;
  # partial=true adds only start/delta/reconstruction work.
  final_callback <- function(id, name, args) {
    callbacks$calls <- callbacks$calls + 1L
    invisible(list(tool_call_id = id, tool_name = name, args = args))
  }
  repeat {
    message <- coordinator$poll_one("foreground:profile")
    buffered_max <- max(buffered_max, coordinator$metrics()$buffered_messages)
    if (is.null(message)) break
    processed <- processed + 1L
    if (inherits(message, "StreamEvent")) {
      event <- message$event; key <- as.character(event$index %||% -1L)
      if (identical(event$type, "content_block_start") && identical(event$content_block$type, "tool_use")) {
        callbacks$starts <- callbacks$starts + 1L
        assign(key, list(id = event$content_block$id, name = event$content_block$name, chunks = character()), blocks)
      } else if (identical(event$type, "content_block_delta") && identical(event$delta$type, "input_json_delta")) {
        callbacks$deltas <- callbacks$deltas + 1L
        block <- get(key, blocks); block$chunks <- c(block$chunks, event$delta$partial_json); assign(key, block, blocks)
      } else if (identical(event$type, "content_block_stop") && exists(key, blocks, inherits = FALSE)) {
        block <- get(key, blocks)
        reconstructed[[block$id]] <- jsonlite::fromJSON(paste0(block$chunks, collapse = ""), simplifyVector = FALSE)
        callbacks$stop_parses <- callbacks$stop_parses + 1L
        rm(list = key, envir = blocks)
      }
    } else {
      final_messages[[length(final_messages) + 1L]] <- message
      if (inherits(message, "AssistantMessage")) for (block in message$content %||% list()) {
        if (inherits(block, "ToolUseBlock")) {
          if (ARM && !identical(reconstructed[[block$id]], block$input)) stop("partial reconstruction differs from final tool args")
          final_callback(block$id, block$name, block$input)
        }
        if (inherits(block, "TextBlock")) callbacks$text <- callbacks$text + 1L
      }
      if (inherits(message, "UserMessage")) callbacks$results <- callbacks$results + 1L
    }
  }
  coordinator$release("foreground:profile"); metrics <- coordinator$metrics(); coordinator$invalidate()
  semantic <- reduce_typed(final_messages); elapsed <- proc.time()[["elapsed"]] - started
  stop_alloc(); raw_bytes <- sum(nchar(frames, type = "bytes"))
  finish_subject_workload(); messages <- queue <- frames <- final_messages <- NULL
  write_json_atomic(list(
    ok = identical(canonical_hash(semantic), expected_hash()) && processed > 0L && callbacks$calls == TOOLS,
    semantic_hash = canonical_hash(semantic), expected_hash = expected_hash(), elapsed_s = elapsed,
    raw_bytes = raw_bytes, parsed_messages = processed,
    partial_events = callbacks$starts + callbacks$deltas + callbacks$stop_parses,
    tool_count = length(semantic$tools), callback_counts = as.list(callbacks),
    coordinator = c(metrics, list(buffered_max = buffered_max)),
    handler_scope = "real coordinator plus equivalent injectable SDK-message consumer; production make_claude_handler is not invoked"
  ), subject_result_path())
}


run_production_handler_subject <- function() {
  suppressPackageStartupMessages({
    library(ClaudeAgentSDK)
    library(shinyAssistantUI)
    library(jsonlite)
  })
  tree_manifest_hash <- function(path) {
    files <- sort(list.files(path, recursive = TRUE, all.files = TRUE,
                             full.names = TRUE, include.dirs = FALSE, no.. = TRUE))
    info <- file.info(files)
    files <- files[!is.na(info$isdir) & !info$isdir]
    relative <- substring(files, nchar(normalizePath(path, winslash = "/", mustWork = TRUE)) + 2L)
    canonical_hash(list(files = relative, md5 = unname(tools::md5sum(files))))
  }
  package_path <- normalizePath(find.package("shinyAssistantUI"), winslash = "/", mustWork = TRUE)
  factory <- get("make_claude_handler", asNamespace("shinyAssistantUI"))
  handler_body_hash <- canonical_hash(paste(
    deparse(body(factory), width.cutoff = 500L), collapse = "\n"
  ))
  installed_manifest_hash <- tree_manifest_hash(package_path)
  source_path <- Sys.getenv("AUI_PROFILE_SOURCE_PATH", "")
  source_manifest_hash <- if (nzchar(source_path) && dir.exists(source_path)) {
    tree_manifest_hash(source_path)
  } else {
    NA_character_
  }
  verify_identity <- function(name, actual) {
    expected <- Sys.getenv(name, "")
    if (nzchar(expected) && !identical(expected, actual)) {
      stop("Production variant identity mismatch for ", name,
           ": expected=", expected, " actual=", actual)
    }
  }
  verify_identity("AUI_PROFILE_EXPECTED_PACKAGE_PATH", package_path)
  verify_identity("AUI_PROFILE_EXPECTED_HANDLER_BODY_HASH", handler_body_hash)
  verify_identity("AUI_PROFILE_EXPECTED_INSTALLED_MANIFEST_HASH", installed_manifest_hash)
  verify_identity("AUI_PROFILE_EXPECTED_SOURCE_MANIFEST_HASH", source_manifest_hash)
  variant <- Sys.getenv("AUI_PROFILE_VARIANT", "unlabeled")

  session_id <- "plan120-production-session"
  thread_id <- "plan120-production-thread"
  fragment_bytes <- 256L
  batch_size <- scalar_int("AUI_PROFILE_BATCH_SIZE", 16L, 1L, 10000L)
  ids <- sprintf("profile-tool-%03d", seq_len(TOOLS))
  expected_fragments <- setNames(vector("list", TOOLS), ids)
  messages <- list()
  for (index in seq_len(TOOLS)) {
    id <- ids[[index]]
    args <- make_args(index)
    args_text <- json_text(args)
    fragments <- if (isTRUE(ARM)) {
      starts <- seq.int(1L, nchar(args_text, type = "chars"), by = fragment_bytes)
      vapply(starts, function(start) substr(args_text, start, start + fragment_bytes - 1L), character(1))
    } else {
      args_text
    }
    expected_fragments[[id]] <- unname(fragments)
    messages[[length(messages) + 1L]] <- ClaudeAgentSDK::StreamEvent(
      uuid = sprintf("plan120-start-%03d", index), session_id = session_id,
      event = list(
        type = "content_block_start", index = index - 1L,
        content_block = list(type = "tool_use", id = id, name = "Write", input = list())
      )
    )
    for (fragment_index in seq_along(fragments)) {
      messages[[length(messages) + 1L]] <- ClaudeAgentSDK::StreamEvent(
        uuid = sprintf("plan120-delta-%03d-%04d", index, fragment_index),
        session_id = session_id,
        event = list(
          type = "content_block_delta", index = index - 1L,
          delta = list(type = "input_json_delta", partial_json = fragments[[fragment_index]])
        )
      )
    }
    messages[[length(messages) + 1L]] <- ClaudeAgentSDK::StreamEvent(
      uuid = sprintf("plan120-stop-%03d", index), session_id = session_id,
      event = list(type = "content_block_stop", index = index - 1L)
    )
    messages[[length(messages) + 1L]] <- ClaudeAgentSDK::AssistantMessage(
      content = list(ClaudeAgentSDK::ToolUseBlock(id, "Write", args)),
      model = "plan120-mock-model", session_id = session_id,
      uuid = sprintf("plan120-assistant-%03d", index), stop_reason = "tool_use"
    )
    messages[[length(messages) + 1L]] <- ClaudeAgentSDK::UserMessage(
      content = list(ClaudeAgentSDK::ToolResultBlock(
        id, content = sprintf("synthetic-result-%03d", index), is_error = FALSE
      )),
      uuid = sprintf("plan120-result-%03d", index),
      tool_use_result = sprintf("synthetic-result-%03d", index)
    )
  }
  messages[[length(messages) + 1L]] <- ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(sprintf("PLAN119_FINAL tools=%d", TOOLS))),
    model = "plan120-mock-model", session_id = session_id,
    uuid = "plan120-final-assistant", stop_reason = "end_turn"
  )
  messages[[length(messages) + 1L]] <- ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = session_id,
    stop_reason = "end_turn", result = sprintf("PLAN119_FINAL tools=%d", TOOLS),
    usage = list()
  )
  message_count <- length(messages)
  fixture_bytes <- sum(nchar(vapply(messages, json_text, character(1)), type = "bytes"))
  batch_indexes <- split(seq_along(messages), ceiling(seq_along(messages) / batch_size))
  batches <- lapply(batch_indexes, function(index) messages[index])
  batch_cursor <- 1L

  identity <- new.env(parent = emptyenv())
  identity$handler_factory_calls <- 0L
  identity$fake_client_creations <- 0L
  identity$client_connects <- 0L
  identity$client_sends <- 0L
  identity$client_disconnects <- 0L
  identity$polls <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function(...) {
    identity$client_connects <- identity$client_connects + 1L
    invisible(NULL)
  }
  client$disconnect <- function(...) {
    identity$client_disconnects <- identity$client_disconnects + 1L
    invisible(NULL)
  }
  client$send <- function(...) {
    identity$client_sends <- identity$client_sends + 1L
    invisible(NULL)
  }
  client$interrupt <- client$approve_tool <- client$deny_tool <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    identity$polls <- identity$polls + 1L
    if (batch_cursor > length(batches)) return(list())
    value <- batches[[batch_cursor]]
    batch_cursor <<- batch_cursor + 1L
    value
  }

  testthat::local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) {
      identity$fake_client_creations <- identity$fake_client_creations + 1L
      client
    },
    .claude_drain_timeout_seconds = function() 0.01,
    .package = "shinyAssistantUI"
  )
  old_idle_delay <- getOption("shinyAssistantUI.claude_idle_start_delay")
  options(shinyAssistantUI.claude_idle_start_delay = 3600)
  on.exit(options(shinyAssistantUI.claude_idle_start_delay = old_idle_delay), add = TRUE)

  identity$handler_factory_calls <- identity$handler_factory_calls + 1L
  session_map_path <- tempfile("plan120-session-map-", fileext = ".rds")
  on.exit(unlink(session_map_path), add = TRUE)
  handler <- factory(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = session_map_path
  )
  cleanup_handler <- attr(handler, "cleanup")
  snapshot_handler <- attr(handler, "performance_snapshot")

  trace <- new.env(parent = emptyenv())
  trace$serial <- 0L
  trace$starts <- list()
  trace$deltas <- setNames(vector("list", TOOLS), ids)
  trace$calls <- list()
  trace$results <- list()
  trace$chunks <- character()
  terminal <- new.env(parent = emptyenv())
  terminal$done <- 0L
  terminal$errors <- 0L
  terminal$error_messages <- character()
  terminal$promise_settled <- FALSE
  terminal$promise_rejected <- FALSE
  terminal$promise_error <- NULL
  bump <- function() trace$serial <- trace$serial + 1L

  loop <- later::create_loop()
  pump_until <- function(predicate, label) {
    deadline <- Sys.time() + DEADLINE_S
    repeat {
      if (isTRUE(predicate())) return(invisible(TRUE))
      abort_path <- Sys.getenv("AUI_PROFILE_ABORT_PATH", "")
      if (nzchar(abort_path) && file.exists(abort_path)) {
        stop("sampler aborted production subject: ", paste(readLines(abort_path, warn = FALSE), collapse = " "))
      }
      if (Sys.time() >= deadline) stop("production handler timed out during ", label)
      later::run_now(0.01, all = TRUE, loop = loop)
    }
  }

  subject_handshake()
  start_alloc()
  started <- proc.time()[["elapsed"]]
  returned <- later::with_loop(loop, handler(
    message = "run synthetic Plan120 profile", thread_id = thread_id,
    attachments = list(), run_id = "plan120-run",
    on_chunk = function(text) {
      bump(); trace$chunks <- c(trace$chunks, as.character(text))
    },
    on_done = function(...) {
      bump(); terminal$done <- terminal$done + 1L
    },
    on_error = function(message) {
      bump(); terminal$errors <- terminal$errors + 1L
      terminal$error_messages <- c(terminal$error_messages, as.character(message))
    },
    on_tool_call_start = function(tool_call_id, tool_name, ...) {
      bump(); trace$starts[[length(trace$starts) + 1L]] <- list(
        id = as.character(tool_call_id), name = as.character(tool_name)
      )
    },
    on_tool_call_delta = function(tool_call_id, delta, ...) {
      bump(); id <- as.character(tool_call_id)
      trace$deltas[[id]] <- c(trace$deltas[[id]], as.character(delta))
    },
    on_tool_call = function(tool_call_id, tool_name, args, ...) {
      bump(); trace$calls[[length(trace$calls) + 1L]] <- list(
        id = as.character(tool_call_id), name = as.character(tool_name), args = args
      )
    },
    on_tool_result = function(tool_call_id, result, is_error = FALSE, ...) {
      bump(); trace$results[[length(trace$results) + 1L]] <- list(
        id = as.character(tool_call_id), result = result, is_error = isTRUE(is_error)
      )
    },
    on_thinking = function(...) { bump(); invisible(NULL) },
    on_auto_continue = function(...) { bump(); invisible(NULL) },
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  ))
  later::with_loop(loop, promises::then(
    returned,
    onFulfilled = function(value) {
      terminal$promise_settled <- TRUE
      invisible(value)
    },
    onRejected = function(reason) {
      terminal$promise_settled <- TRUE
      terminal$promise_rejected <- TRUE
      terminal$promise_error <- if (inherits(reason, "condition")) conditionMessage(reason) else as.character(reason)
      invisible(NULL)
    }
  ))
  pump_until(function() {
    (terminal$done + terminal$errors) >= 1L && isTRUE(terminal$promise_settled)
  }, "terminal/promise settlement")

  elapsed <- proc.time()[["elapsed"]] - started
  pre_cleanup_snapshot <- snapshot_handler()
  coordinator <- pre_cleanup_snapshot$threads[[thread_id]]$coordinator %||% list()
  stop_alloc()

  result_by_id <- setNames(trace$results, vapply(trace$results, `[[`, character(1), "id"))
  observed <- list(
    tools = lapply(trace$calls, function(call) {
      result <- result_by_id[[call$id]] %||% list(result = NULL, is_error = NA)
      c(call, list(result = result$result, is_error = result$is_error))
    }),
    text = paste0(trace$chunks, collapse = "")
  )
  semantic_hash <- canonical_hash(observed)
  expected_semantic_hash <- expected_hash()
  delta_trace_ok <- identical(names(trace$deltas), ids) && all(vapply(ids, function(id) {
    identical(unname(trace$deltas[[id]]), unname(expected_fragments[[id]]))
  }, logical(1)))
  start_trace_ok <- identical(
    vapply(trace$starts, `[[`, character(1), "id"), ids
  ) && all(vapply(trace$starts, function(value) identical(value$name, "Write"), logical(1)))
  callback_counts <- list(
    starts = length(trace$starts),
    deltas = sum(lengths(trace$deltas)),
    calls = length(trace$calls),
    results = length(trace$results),
    text = length(trace$chunks)
  )
  serial_before_cleanup <- trace$serial
  cleanup_result <- new.env(parent = emptyenv())
  cleanup_result$quiescent <- FALSE
  cleanup_result$no_late_callbacks <- FALSE
  cleanup_result$post_snapshot <- NULL

  messages <- NULL
  batches <- NULL
  batch_indexes <- NULL
  expected_fragments <- NULL
  finish_subject_workload(after_active_capture = function() {
    cleanup_handler()
    pump_until(function() {
      snapshot <- snapshot_handler()
      cleanup_result$post_snapshot <- snapshot
      snapshot$active_turns == 0L && snapshot$connected_clients == 0L &&
        snapshot$coordinators == 0L && identity$client_disconnects == 1L
    }, "cleanup/quiescence")
    cleanup_result$quiescent <- TRUE
    serial_after_cleanup <- trace$serial
    later::run_now(0.01, all = TRUE, loop = loop)
    cleanup_result$no_late_callbacks <- identical(trace$serial, serial_after_cleanup) &&
      serial_after_cleanup >= serial_before_cleanup
  })

  identity_result <- list(
    handler_factory_calls = identity$handler_factory_calls,
    fake_client_creations = identity$fake_client_creations,
    client_connects = identity$client_connects,
    client_sends = identity$client_sends,
    client_disconnects = identity$client_disconnects,
    polls = identity$polls,
    package_path = package_path,
    package_version = as.character(utils::packageVersion("shinyAssistantUI")),
    variant = variant,
    source_path = source_path,
    source_manifest_hash = source_manifest_hash,
    installed_manifest_hash = installed_manifest_hash,
    handler_body_hash = handler_body_hash
  )
  ok <- identical(semantic_hash, expected_semantic_hash) &&
    isTRUE(delta_trace_ok) && isTRUE(start_trace_ok) &&
    callback_counts$calls == TOOLS && callback_counts$results == TOOLS &&
    terminal$done == 1L && terminal$errors == 0L &&
    isTRUE(terminal$promise_settled) && !isTRUE(terminal$promise_rejected) &&
    identity_result$handler_factory_calls == 1L &&
    identity_result$fake_client_creations == 1L &&
    identity_result$client_connects == 1L && identity_result$client_sends == 1L &&
    identity_result$client_disconnects == 1L &&
    (coordinator$messages_seen %||% 0L) > 0L &&
    isTRUE(cleanup_result$quiescent) && isTRUE(cleanup_result$no_late_callbacks)

  write_json_atomic(list(
    ok = ok,
    semantic_hash = semantic_hash,
    expected_hash = expected_semantic_hash,
    elapsed_s = elapsed,
    raw_bytes = fixture_bytes,
    parsed_messages = message_count,
    partial_events = callback_counts$starts + callback_counts$deltas,
    tool_count = callback_counts$calls,
    callback_counts = callback_counts,
    coordinator = coordinator,
    handler_scope = "production make_claude_handler end-to-end",
    arm_semantics = if (isTRUE(ARM)) "fragmented" else "coalesced-control",
    fragment_trace_ok = delta_trace_ok,
    start_trace_ok = start_trace_ok,
    identity = identity_result,
    terminal = list(
      done = terminal$done, errors = terminal$errors,
      error_messages = terminal$error_messages,
      promise_settled = terminal$promise_settled,
      promise_rejected = terminal$promise_rejected,
      promise_error = terminal$promise_error
    ),
    cleanup = list(
      quiescent = cleanup_result$quiescent,
      no_late_callbacks = cleanup_result$no_late_callbacks,
      snapshot = cleanup_result$post_snapshot
    )
  ), subject_result_path())
}

run_shiny_subject <- function() {
  suppressPackageStartupMessages({library(shiny); library(shinyAssistantUI); library(jsonlite)})
  expected_package <- normalizePath(find.package("shinyAssistantUI"), winslash = "/", mustWork = TRUE)
  port <- scalar_int("AUI_PROFILE_PORT", 0L, 1L, 65535L)
  result_path <- subject_result_path(); ready_path <- Sys.getenv("AUI_PROFILE_READY_PATH", "")
  if (!nzchar(ready_path)) stop("Shiny subject ready path missing")
  alloc_started <- FALSE; started <- NULL
  begin_profile <- function() {
    if (!alloc_started) {
      mark_phase("AUI_PROFILE_ACTIVE_PATH")
      Sys.sleep(max(0.03, SAMPLE_INTERVAL_S * 1.5))
      start_alloc(); alloc_started <<- TRUE; started <<- proc.time()[["elapsed"]]
    }
  }
  finish_profile <- function(extra) {
    if (alloc_started) stop_alloc()
    finish_subject_workload()
    write_json_atomic(c(list(
      ok = isTRUE(extra$ok %||% TRUE), semantic_hash = extra$semantic_hash %||% NA_character_, expected_hash = expected_hash(),
      elapsed_s = proc.time()[["elapsed"]] - started, raw_bytes = extra$raw_bytes %||% NA_real_,
      parsed_messages = extra$parsed_messages %||% NA_integer_, partial_events = extra$partial_events %||% 0L,
      tool_count = extra$tool_count %||% TOOLS, callback_counts = extra$callback_counts %||% list(),
      coordinator = NULL, installed_package = expected_package
    ), extra[setdiff(names(extra), c("ok", "semantic_hash", "raw_bytes", "parsed_messages", "partial_events", "tool_count", "callback_counts"))]), result_path)
    later::later(function() shiny::stopApp(), delay = 0.8)
  }
  if (LAYER == "shiny-discard") {
    script <- "(function install(){if(!window.Shiny||!Shiny.addCustomMessageHandler){setTimeout(install,20);return;}if(window.__auiDiscardInstalled)return;window.__auiDiscardInstalled=true;let h=0,finals=0,seen=0;function send(id,value){if(typeof Shiny.setInputValue==='function')Shiny.setInputValue(id,value,{priority:'event'});else if(typeof Shiny.onInputChange==='function')Shiny.onInputChange(id,value);else if(typeof Shiny.shinyapp?.sendInput==='function')Shiny.shinyapp.sendInput({[id]:value});else setTimeout(()=>send(id,value),20);}function add(s){for(let i=0;i<s.length;i++)h=(h+s.charCodeAt(i))%4294967296;}Shiny.addCustomMessageHandler('profile-discard',function(d){seen++;if(d.final===true){add(d.semantic);finals++;}if(d.done===true){window.__auiDiscardDone={hash:(h%2147483647).toString(16).padStart(8,'0'),finals:finals,seen:seen};send('discard_ack',window.__auiDiscardDone);}});function ready(){send('discard_ready',true);}$(document).on('shiny:connected',ready);setTimeout(ready,0);})();"
    ui <- fluidPage(tags$script(HTML(script)), tags$div(id = "discard-probe", "discard-ready"))
    server <- function(input, output, session) {
      observeEvent(input$discard_ready, {
        semantic_strings <- vapply(make_semantics()$tools, json_text, character(1))
        expected_discard_hash <- checksum32(semantic_strings)
        partial_payloads <- list()
        if (ARM) for (index in seq_len(TOOLS)) {
          args_text <- json_text(make_args(index))
          starts <- seq.int(1L, nchar(args_text), by = 256L)
          pieces <- lapply(starts, function(start) substr(args_text, start, start + 255L))
          partial_payloads <- c(
            partial_payloads,
            list(list(kind = "start", id = sprintf("profile-tool-%03d", index))),
            lapply(pieces, function(piece) list(kind = "delta", delta = piece)),
            list(list(kind = "stop"))
          )
        }
        partial_wire_bytes <- if (length(partial_payloads)) sum(nchar(vapply(partial_payloads, json_text, character(1)), type = "bytes")) else 0
        semantic_wire_bytes <- sum(nchar(semantic_strings, type = "bytes"))
        begin_profile()
        for (payload in partial_payloads) session$sendCustomMessage("profile-discard", payload)
        for (semantic in semantic_strings) session$sendCustomMessage("profile-discard", list(final = TRUE, semantic = semantic))
        session$sendCustomMessage("profile-discard", list(done = TRUE))
        session$userData$profile <- list(
          raw_bytes = partial_wire_bytes + semantic_wire_bytes,
          event_count = length(partial_payloads), expected_discard_hash = expected_discard_hash
        )
      }, ignoreInit = TRUE, once = TRUE)
      observeEvent(input$discard_ack, {
        profile <- session$userData$profile
        finish_profile(list(
          semantic_hash = input$discard_ack$hash, raw_bytes = profile$raw_bytes,
          parsed_messages = input$discard_ack$seen, partial_events = profile$event_count,
          tool_count = input$discard_ack$finals,
          ok = identical(input$discard_ack$hash, profile$expected_discard_hash)
        ))
      }, ignoreInit = TRUE, once = TRUE)
    }
  } else {
    browser_profile <- new.env(parent = emptyenv()); browser_profile$partial_events <- 0L
    browser_tools <- lapply(seq_len(TOOLS), function(index) {
      args <- make_args(index); args_text <- json_text(args)
      starts <- seq.int(1L, nchar(args_text), by = 256L)
      list(
        index = index, id = sprintf("profile-tool-%03d", index), args = args,
        deltas = lapply(starts, function(start) substr(args_text, start, start + 255L))
      )
    })
    handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result,
                        on_tool_call_start, on_tool_call_delta, ...) {
      begin_profile(); partial_events <- 0L
      for (tool in browser_tools) {
        if (ARM) {
          on_tool_call_start(tool$id, "Write", annotations = list(defaultOpen = FALSE)); partial_events <- partial_events + 1L
          for (delta in tool$deltas) { on_tool_call_delta(tool$id, delta); partial_events <- partial_events + 1L }
        }
        on_tool_call(tool$id, "Write", tool$args, annotations = list(defaultOpen = FALSE))
        on_tool_result(tool$id, sprintf("synthetic-result-%03d", tool$index), is_error = FALSE)
      }
      browser_profile$partial_events <- partial_events
      on_chunk(sprintf("PLAN119_FINAL tools=%d", TOOLS)); on_done()
    }
    ui <- assistantUIPage(tags$head(tags$link(rel = "icon", href = "data:,")), assistantUIOutput("chat", height = "100vh"))
    server <- function(input, output, session) {
      assistantUIServer("chat", handler = handler, persistence = "none")
      observeEvent(input$profile_ack, {
        profile <- list(partial_events = browser_profile$partial_events %||% 0L)
        finish_profile(list(
          semantic_hash = input$profile_ack$semantic_hash, raw_bytes = input$profile_ack$dom_bytes,
          parsed_messages = input$profile_ack$card_count, partial_events = profile$partial_events,
          tool_count = input$profile_ack$card_count, browser_semantics = input$profile_ack$semantics,
          ok = isTRUE(input$profile_ack$correct)
        ))
      }, ignoreInit = TRUE, once = TRUE)
    }
  }
  writeLines(as.character(Sys.getpid()), ready_path)
  shiny::runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE, quiet = TRUE)
}

parse_alloc_profile <- function(path) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(error) character())
  match <- regexec("^([0-9]+)[[:space:]]*:[[:space:]]*(.*)$", lines)
  parts <- regmatches(lines, match); keep <- lengths(parts) == 3L
  if (!any(keep)) return(list(available = FALSE, allocation_count = 0L, cumulative_bytes = 0, top_stacks = list()))
  bytes <- as.numeric(vapply(parts[keep], `[[`, character(1), 2L)); stacks <- vapply(parts[keep], `[[`, character(1), 3L)
  grouped <- sort(tapply(bytes, stacks, sum), decreasing = TRUE)
  top <- head(grouped, 100L)
  list(available = TRUE, allocation_count = length(bytes), cumulative_bytes = sum(bytes),
       max_allocation_bytes = max(bytes), top_stacks = lapply(seq_along(top), function(index) list(stack = names(top)[index], bytes = unname(top[index]))))
}

if (ROLE == "subject") {
  status <- tryCatch({
    if (LAYER == "transport") run_transport_subject()
    else if (LAYER == "handler") run_handler_subject()
    else if (LAYER == "production-handler") run_production_handler_subject()
    else run_shiny_subject()
    0L
  }, error = function(error) {
    try(stop_alloc(), silent = TRUE)
    try(write_json_atomic(list(ok = FALSE, error = conditionMessage(error)), subject_result_path()), silent = TRUE)
    message(conditionMessage(error)); 1L
  })
  quit(save = "no", status = status)
}

suppressPackageStartupMessages({library(processx); library(jsonlite)})
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
summary_path <- file.path(OUT_DIR, "summary.json")
if (tolower(Sys.getenv("AUI_PROFILE_RESET", "false")) == "true" && ROLE == "driver") unlink(summary_path)
run_root <- tempfile(sprintf("plan119-%s-%s-", LAYER, PASS), tmpdir = OUT_DIR)
dir.create(run_root, recursive = TRUE)
run_cleanup <- new.env(parent = emptyenv()); run_cleanup$path <- run_root
reg.finalizer(run_cleanup, function(environment) unlink(environment$path, recursive = TRUE, force = TRUE), onexit = TRUE)

base_env <- function(extra = character()) {
  inherited <- c(PATH = Sys.getenv("PATH"), HOME = Sys.getenv("HOME"),
                 R_LIBS_USER = Sys.getenv("R_LIBS_USER", unset = NA_character_))
  values <- c(inherited[!is.na(inherited)], extra)
  values[!duplicated(names(values), fromLast = TRUE)]
}
wait_file <- function(path, process, timeout, interval = 0.02) {
  deadline <- Sys.time() + timeout
  repeat {
    if (file.exists(path)) return(TRUE)
    if (!process$is_alive() || Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
wait_exit <- function(process, timeout = 5) {
  deadline <- Sys.time() + timeout
  while (process$is_alive() && Sys.time() < deadline) Sys.sleep(0.05)
  !process$is_alive()
}

run_arm <- function(partial) {
  arm_name <- if (partial) "true" else "false"
  arm_dir <- file.path(run_root, arm_name); dir.create(arm_dir)
  result_path <- file.path(arm_dir, "result.json"); ready_path <- file.path(arm_dir, "ready")
  go_path <- file.path(arm_dir, "go"); active_path <- file.path(arm_dir, "active")
  workload_finished_path <- file.path(arm_dir, "workload-finished"); active_capture_path <- file.path(arm_dir, "active-captured")
  workload_done_path <- file.path(arm_dir, "workload-done"); post_gc_path <- file.path(arm_dir, "post-gc")
  alloc_path <- file.path(arm_dir, "alloc.out"); abort_path <- file.path(arm_dir, "abort")
  sampler_result_path <- file.path(arm_dir, "sampler.json"); sampler_ready_path <- file.path(arm_dir, "sampler-ready")
  chrome_pid_path <- file.path(arm_dir, "chrome-pid")
  port <- if (LAYER %in% c("shiny-discard", "browser-full")) httpuv::randomPort() else 1L
  common_env <- c(
    AUI_PROFILE_LAYER = LAYER, AUI_PROFILE_ARM = arm_name, AUI_PROFILE_PASS = PASS,
    AUI_PROFILE_TOOLS = as.character(TOOLS), AUI_PROFILE_PAYLOAD_BYTES = as.character(PAYLOAD_BYTES),
    AUI_PROFILE_DEADLINE_S = as.character(DEADLINE_S),
    AUI_PROFILE_PSS_CEILING_BYTES = as.character(PSS_CEILING_BYTES),
    AUI_PROFILE_CGROUP_HEADROOM_BYTES = as.character(CGROUP_HEADROOM_BYTES),
    AUI_PROFILE_SAMPLE_INTERVAL_S = as.character(SAMPLE_INTERVAL_S),
    AUI_PROFILE_RESULT_PATH = result_path, AUI_PROFILE_READY_PATH = ready_path,
    AUI_PROFILE_GO_PATH = go_path, AUI_PROFILE_ACTIVE_PATH = active_path,
    AUI_PROFILE_WORKLOAD_FINISHED_PATH = workload_finished_path,
    AUI_PROFILE_ACTIVE_CAPTURE_PATH = active_capture_path,
    AUI_PROFILE_WORKLOAD_DONE_PATH = workload_done_path, AUI_PROFILE_POST_GC_PATH = post_gc_path,
    AUI_PROFILE_ALLOC_PATH = alloc_path, AUI_PROFILE_PORT = as.character(port),
    AUI_PROFILE_ABORT_PATH = abort_path, AUI_PROFILE_CHROME_PID_PATH = chrome_pid_path,
    AUI_PROFILE_VARIANT = Sys.getenv("AUI_PROFILE_VARIANT", ""),
    AUI_PROFILE_SOURCE_PATH = Sys.getenv("AUI_PROFILE_SOURCE_PATH", ""),
    AUI_PROFILE_EXPECTED_SOURCE_MANIFEST_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_SOURCE_MANIFEST_HASH", ""),
    AUI_PROFILE_EXPECTED_PACKAGE_PATH = Sys.getenv("AUI_PROFILE_EXPECTED_PACKAGE_PATH", ""),
    AUI_PROFILE_EXPECTED_INSTALLED_MANIFEST_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_INSTALLED_MANIFEST_HASH", ""),
    AUI_PROFILE_EXPECTED_HANDLER_BODY_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_HANDLER_BODY_HASH", "")
  )
  subject <- processx::process$new(file.path(R.home("bin"), "Rscript"), SCRIPT,
    env = base_env(c(AUI_PROFILE_ROLE = "subject", common_env)), stdout = "|", stderr = "|", cleanup_tree = TRUE)
  launcher_pid <- subject$get_pid(); subject_pid <- NA_integer_; sampler <- NULL; browser <- NULL
  browser_errors <- list(); browser_facts <- list(error_count = 0L, errors = list())
  owned_handles <- list(); cleanup_state <- list(subject_root_exited = FALSE, cleanup_confirmed = FALSE, remaining = list())
  handle_live <- function(handle) {
    running <- tryCatch(ps::ps_is_running(handle), error = function(error) FALSE)
    status <- tryCatch(ps::ps_status(handle), error = function(error) "dead")
    isTRUE(running) && !status %in% c("zombie", "dead")
  }
  remember_owned <- function() {
    roots <- c(launcher_pid,
      if (!is.null(sampler)) sampler$get_pid() else integer(),
      if (!is.null(browser)) tryCatch(browser$parent$get_browser()$get_process()$get_pid(), error = function(error) integer()) else integer())
    for (pid in roots) {
      handle <- tryCatch(ps::ps_handle(pid), error = function(error) NULL)
      if (!is.null(handle)) {
        owned_handles[[paste0(pid, ":root")]] <<- handle
        children <- tryCatch(ps::ps_children(handle, recursive = TRUE), error = function(error) list())
        for (child in children) owned_handles[[paste0(ps::ps_pid(child), ":child")]] <<- child
      }
    }
  }
  cleanup <- function() {
    remember_owned()
    if (!is.null(browser)) {
      chrome_process <- tryCatch(browser$parent$get_browser()$get_process(), error = function(error) NULL)
      try(browser$close(), silent = TRUE); try(browser$parent$close(), silent = TRUE)
      if (!is.null(chrome_process)) {
        try(if (chrome_process$is_alive()) chrome_process$kill_tree(), silent = TRUE)
        try(chrome_process$wait(timeout = 5000), silent = TRUE)
      }
    }
    if (!is.null(sampler) && sampler$is_alive()) { try(sampler$kill_tree(), silent = TRUE); try(sampler$wait(timeout = 5000), silent = TRUE) }
    if (subject$is_alive()) { try(subject$kill_tree(), silent = TRUE); try(subject$wait(timeout = 5000), silent = TRUE) }
    deadline <- Sys.time() + 5
    repeat {
      live <- Filter(handle_live, owned_handles)
      if (!length(live) || Sys.time() >= deadline) break
      for (handle in rev(live)) try(ps::ps_kill(handle), silent = TRUE)
      Sys.sleep(0.05)
    }
    cleanup_state$subject_root_exited <<- !subject$is_alive()
    remaining <- Filter(handle_live, owned_handles)
    cleanup_state$remaining <<- lapply(remaining, function(handle) list(
      pid = tryCatch(ps::ps_pid(handle), error = function(error) NA_integer_),
      status = tryCatch(ps::ps_status(handle), error = function(error) "dead")
    ))
    cleanup_state$cleanup_confirmed <<- cleanup_state$subject_root_exited && !length(remaining)
    invisible(cleanup_state$cleanup_confirmed)
  }
  on.exit(cleanup(), add = TRUE)
  if (!wait_file(ready_path, subject, timeout = 20)) stop("Subject failed before initialized: ", paste(subject$read_error_lines(), collapse = " | "))
  ready_values <- readLines(ready_path, warn = FALSE)
  subject_pid <- suppressWarnings(as.integer(ready_values[[1L]]))
  if (length(subject_pid) != 1L || is.na(subject_pid) || subject_pid != launcher_pid) {
    stop("Subject PID handshake mismatch: launcher=", launcher_pid, " ready=", paste(ready_values, collapse = ","))
  }
  sampler <- processx::process$new(file.path(R.home("bin"), "Rscript"), SCRIPT, env = base_env(c(
    AUI_PROFILE_ROLE = "sampler", common_env,
    AUI_PROFILE_SUBJECT_PID = as.character(subject_pid),
    AUI_PROFILE_SAMPLER_RESULT_PATH = sampler_result_path,
    AUI_PROFILE_SAMPLER_READY_PATH = sampler_ready_path
  )), stdout = "|", stderr = "|", cleanup_tree = TRUE)
  if (!wait_file(sampler_ready_path, sampler, timeout = 10)) stop("Independent sampler did not initialize")
  writeLines("go", go_path)
  value <- NULL
  if (LAYER %in% c("shiny-discard", "browser-full")) {
    suppressPackageStartupMessages(library(chromote))
    chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload")))
    browser <- chromote::ChromoteSession$new(width = 900, height = 700)
    chrome_process <- browser$parent$get_browser()$get_process()
    writeLines(as.character(chrome_process$get_pid()), chrome_pid_path)
    browser$Runtime$enable(timeout_ = 5)
    browser$Runtime$consoleAPICalled(callback_ = function(message) {
      if (identical(message$type, "error")) browser_errors[[length(browser_errors) + 1L]] <<- list(
        kind = "console", type = message$type,
        text = paste(vapply(message$args %||% list(), function(arg) as.character(arg$value %||% arg$description %||% ""), character(1)), collapse = " "),
        stack = message$stackTrace %||% NULL
      )
    })
    browser$Runtime$exceptionThrown(callback_ = function(message) {
      details <- message$exceptionDetails %||% list()
      browser_errors[[length(browser_errors) + 1L]] <<- list(
        kind = "exception", type = "exceptionThrown",
        text = details$exception$description %||% details$text %||% "exception",
        stack = details$stackTrace %||% NULL
      )
    })
    value <- function(script) {
      response <- browser$Runtime$evaluate(script, returnByValue = TRUE, timeout_ = 8)
      if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
      response$result$value
    }
    Sys.sleep(0.5)
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port), timeout_ = 10)
    browser$Page$loadEventFired(timeout_ = 15)
    wait_browser <- function(predicate, timeout) {
      deadline <- Sys.time() + timeout
      repeat {
        if (file.exists(abort_path)) stop("Sampler aborted subject: ", paste(readLines(abort_path, warn = FALSE), collapse = " "))
        if (isTRUE(tryCatch(predicate(), error = function(error) FALSE))) return(TRUE)
        if (!subject$is_alive() || Sys.time() >= deadline) return(FALSE)
        Sys.sleep(0.05)
      }
    }
    if (LAYER == "shiny-discard") {
      if (!wait_browser(function() isTRUE(value("!!window.__auiDiscardDone")), 25)) stop("discard browser did not acknowledge all messages")
      facts <- jsonlite::fromJSON(value("JSON.stringify(window.__auiDiscardDone)"), simplifyVector = FALSE)
      browser_facts <- c(list(error_count = length(browser_errors), errors = browser_errors), facts)
    } else {
      if (!wait_browser(function() isTRUE(value("!!document.querySelector('.aui-root') && !!document.querySelector('[contenteditable=true]')")), 20)) stop("assistant runtime did not mount")
      value("document.querySelector('[contenteditable=true]').focus();true")
      browser$Input$insertText(text = "run synthetic Plan119 profile", timeout_ = 8)
      browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L, timeout_ = 8)
      browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L, timeout_ = 8)
      ready_js <- sprintf("document.querySelectorAll('[data-slot=tool-fallback-trigger-label]').length===%d && document.body.innerText.includes('PLAN119_FINAL tools=%d')", TOOLS, TOOLS)
      if (!wait_browser(function() isTRUE(value(ready_js)), 45)) stop("browser-full final semantics did not settle")
      semantics_text <- value("JSON.stringify({labels:Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger-label]')).map(e=>(e.textContent||'').trim()),text:Array.from(document.querySelectorAll('[data-role=assistant]')).map(e=>e.innerText).join('\\n').match(/PLAN119_FINAL tools=\\d+/)?.[0]||''})")
      semantics <- jsonlite::fromJSON(semantics_text, simplifyVector = FALSE)
      semantic_hash <- canonical_hash(semantics); card_count <- length(semantics$labels)
      correct <- card_count == TOOLS && identical(semantics$text, sprintf("PLAN119_FINAL tools=%d", TOOLS)) && length(browser_errors) == 0L
      ack <- json_text(list(semantic_hash = semantic_hash, dom_bytes = nchar(semantics_text, type = "bytes"), card_count = card_count, semantics = semantics, correct = correct))
      value(sprintf("(typeof Shiny.setInputValue==='function'?Shiny.setInputValue('profile_ack',%s,{priority:'event'}):typeof Shiny.onInputChange==='function'?Shiny.onInputChange('profile_ack',%s):Shiny.shinyapp.sendInput({profile_ack:%s}));true", ack, ack, ack))
      heap <- tryCatch(value("(performance.memory&&performance.memory.usedJSHeapSize)||null"), error = function(error) NULL)
      browser_facts <- list(error_count = length(browser_errors), errors = browser_errors, card_count = card_count,
                            semantics = semantics, correct = correct, js_heap_post_bytes = heap)
    }
  }
  result_wait_s <- max(30, DEADLINE_S - 15)
  if (!wait_file(result_path, subject, timeout = result_wait_s)) stop("Subject produced no result: ", paste(subject$read_error_lines(), collapse = " | "))
  if (!wait_exit(subject, timeout = 8)) stop("Subject did not exit after result")
  if (!wait_file(sampler_result_path, sampler, timeout = 8)) stop("Sampler produced no result: ", paste(sampler$read_error_lines(), collapse = " | "))
  wait_exit(sampler, timeout = 3)
  subject_exit <- subject$get_exit_status(); sampler_exit <- sampler$get_exit_status()
  if (!identical(subject_exit, 0L) || !identical(sampler_exit, 0L)) stop("Subject/sampler failed: ", paste(c(subject$read_all_error_lines(), sampler$read_all_error_lines()), collapse = " | "))
  result <- read_json(result_path); sampling <- read_json(sampler_result_path)
  result$browser <- browser_facts
  result$process <- c(list(
    launcher_pid = launcher_pid, subject_pid = subject_pid, pid_handshake_equal = identical(launcher_pid, subject_pid),
    r_subject_ceiling_bytes = PSS_CEILING_BYTES, subject_deadline_s = DEADLINE_S,
    subject_root_exited = TRUE
  ), sampling)
  result$allocation <- if (PASS == "alloc") parse_alloc_profile(alloc_path) else list(available = FALSE)
  if (PASS == "alloc" && identical(LAYER, "production-handler") && file.exists(alloc_path)) {
    profile_dir <- file.path(OUT_DIR, "raw-profiles")
    dir.create(profile_dir, recursive = TRUE, showWarnings = FALSE)
    persistent_profile <- file.path(
      profile_dir,
      sprintf("production-handler-tools-%d-payload-%d-arm-%s-pid-%d.out",
              TOOLS, PAYLOAD_BYTES, arm_name, subject_pid)
    )
    if (!file.copy(alloc_path, persistent_profile, overwrite = TRUE)) {
      stop("Could not preserve production Rprofmem output")
    }
    result$allocation$profile_path <- normalizePath(persistent_profile, winslash = "/", mustWork = TRUE)
  }
  result$layer <- LAYER; result$pass <- PASS; result$partial <- partial; result$tools <- TOOLS
  result$payload_bytes <- PAYLOAD_BYTES; result$completed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
  cleanup()
  result$process$subject_root_exited <- cleanup_state$subject_root_exited
  result$process$cleanup_confirmed <- cleanup_state$cleanup_confirmed
  if (!isTRUE(result$process$cleanup_confirmed)) stop(
    "Owned subject/Chrome/sampler descendants were not fully cleaned: ", json_text(cleanup_state$remaining)
  )
  if ((result$browser$error_count %||% 0L) != 0L) stop("Browser errors were captured: ", json_text(result$browser$errors))
  result
}

if (ROLE == "arm-driver") {
  if (is.na(ARM)) stop("arm-driver requires one explicit AUI_PROFILE_ARM")
  arm_output <- Sys.getenv("AUI_PROFILE_ARM_RESULT_PATH", "")
  if (!nzchar(arm_output)) stop("arm-driver result path missing")
  result <- run_arm(ARM)
  write_json_atomic(result, arm_output)
  unlink(run_root, recursive = TRUE, force = TRUE)
  quit(save = "no", status = 0L)
}

supervise_arm <- function(partial) {
  arm_name <- if (partial) "true" else "false"
  output <- file.path(run_root, paste0("supervised-", arm_name, ".json"))
  env <- base_env(c(
    AUI_PROFILE_ROLE = "arm-driver", AUI_PROFILE_LAYER = LAYER, AUI_PROFILE_ARM = arm_name,
    AUI_PROFILE_PASS = PASS, AUI_PROFILE_TOOLS = as.character(TOOLS),
    AUI_PROFILE_PAYLOAD_BYTES = as.character(PAYLOAD_BYTES), AUI_PROFILE_DEADLINE_S = as.character(DEADLINE_S),
    AUI_PROFILE_PSS_CEILING_BYTES = as.character(PSS_CEILING_BYTES),
    AUI_PROFILE_CGROUP_HEADROOM_BYTES = as.character(CGROUP_HEADROOM_BYTES),
    AUI_PROFILE_SAMPLE_INTERVAL_S = as.character(SAMPLE_INTERVAL_S),
    AUI_PROFILE_OUT_DIR = OUT_DIR,
    AUI_PROFILE_VARIANT = Sys.getenv("AUI_PROFILE_VARIANT", ""),
    AUI_PROFILE_SOURCE_PATH = Sys.getenv("AUI_PROFILE_SOURCE_PATH", ""),
    AUI_PROFILE_EXPECTED_SOURCE_MANIFEST_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_SOURCE_MANIFEST_HASH", ""),
    AUI_PROFILE_EXPECTED_PACKAGE_PATH = Sys.getenv("AUI_PROFILE_EXPECTED_PACKAGE_PATH", ""),
    AUI_PROFILE_EXPECTED_INSTALLED_MANIFEST_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_INSTALLED_MANIFEST_HASH", ""),
    AUI_PROFILE_EXPECTED_HANDLER_BODY_HASH = Sys.getenv("AUI_PROFILE_EXPECTED_HANDLER_BODY_HASH", ""),
    AUI_PROFILE_ARM_RESULT_PATH = output
  ))
  worker <- processx::process$new(file.path(R.home("bin"), "Rscript"), SCRIPT, env = env,
                                  stdout = "|", stderr = "|", cleanup_tree = TRUE)
  worker_pid <- worker$get_pid(); started <- Sys.time(); timed_out <- FALSE
  repeat {
    if (!worker$is_alive()) break
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) >= DEADLINE_S) {
      timed_out <- TRUE; try(worker$kill_tree(), silent = TRUE); wait_exit(worker, timeout = 5); break
    }
    Sys.sleep(0.05)
  }
  if (worker$is_alive()) { try(worker$kill_tree(), silent = TRUE); wait_exit(worker, timeout = 5) }
  root_exited <- !worker$is_alive()
  if (timed_out) stop("Hard per-arm supervisor deadline exceeded for partial=", arm_name)
  status <- worker$get_exit_status()
  if (!identical(status, 0L) || !file.exists(output)) stop("arm-driver failed: ", paste(c(worker$read_all_output_lines(), worker$read_all_error_lines()), collapse = " | "))
  result <- read_json(output)
  result$arm_supervisor <- list(pid = worker_pid, hard_deadline_s = DEADLINE_S, timed_out = FALSE, root_exited = root_exited)
  result
}

arms <- if (is.na(ARM)) sample(c(FALSE, TRUE), 2L) else ARM
results <- lapply(arms, supervise_arm)
# Every single-arm and dual-arm browser run must fail on any captured console/runtime error.
if (any(vapply(results, function(item) (item$browser$error_count %||% 0L) != 0L, logical(1)))) stop("Browser errors were captured")
if (any(!vapply(results, function(item) isTRUE(item$ok), logical(1)))) stop("At least one subject failed its semantic assertion")
if (length(results) == 2L) {
  by_arm <- setNames(results, vapply(results, function(item) as.character(item$partial), character(1)))
  if (!identical(by_arm[["TRUE"]]$semantic_hash, by_arm[["FALSE"]]$semantic_hash)) stop("Partial A/B final semantic hashes differ")
}
existing <- if (file.exists(summary_path)) read_json(summary_path) else list(schema_version = 2L, runs = list())
existing$schema_version <- 2L; existing$runs <- existing$runs %||% list()
key <- sprintf("%s|%s|tools=%d|payload=%d", LAYER, PASS, TOOLS, PAYLOAD_BYTES)
existing$runs[[key]] <- list(layer = LAYER, pass = PASS, tools = TOOLS, payload_bytes = PAYLOAD_BYTES, arms = results)
comparisons <- list()
for (name in names(existing$runs)) {
  run <- existing$runs[[name]]; if (length(run$arms) != 2L) next
  by_arm <- setNames(run$arms, vapply(run$arms, function(item) as.character(item$partial), character(1)))
  on <- by_arm[["TRUE"]]; off <- by_arm[["FALSE"]]
  ratio <- function(a, b) if (is.numeric(a) && is.numeric(b) && length(a) && length(b) && is.finite(a) && is.finite(b) && b > 0) a / b else NA_real_
  comparisons[[name]] <- list(
    semantic_hash_equal = identical(on$semantic_hash, off$semantic_hash),
    r_subject_active_peak_pss_ratio_on_off = ratio(on$process$r_subject_active_peak_pss_bytes, off$process$r_subject_active_peak_pss_bytes),
    r_subject_post_gc_pss_ratio_on_off = ratio(on$process$r_subject_post_gc_pss_bytes, off$process$r_subject_post_gc_pss_bytes),
    chrome_tree_active_peak_pss_ratio_on_off = ratio(on$process$chrome_tree_active_peak_pss_bytes, off$process$chrome_tree_active_peak_pss_bytes),
    allocation_bytes_ratio_on_off = ratio(on$allocation$cumulative_bytes, off$allocation$cumulative_bytes),
    allocation_count_ratio_on_off = ratio(on$allocation$allocation_count, off$allocation$allocation_count),
    buffered_max_on = on$coordinator$buffered_max %||% NA_integer_, buffered_max_off = off$coordinator$buffered_max %||% NA_integer_,
    callback_calls_on = on$callback_counts$calls %||% NA_integer_, callback_calls_off = off$callback_counts$calls %||% NA_integer_,
    browser_errors = (on$browser$error_count %||% 0L) + (off$browser$error_count %||% 0L)
  )
}
existing$comparisons <- comparisons
comp <- function(layer, pass) {
  matches <- names(comparisons)[vapply(names(comparisons), function(name) startsWith(name, paste0(layer, "|", pass, "|tools=", TOOLS, "|")), logical(1))]
  if (length(matches)) comparisons[[tail(matches, 1L)]] else NULL
}
transport_alloc <- comp("transport", "alloc"); handler_alloc <- comp("handler", "alloc"); browser_alloc <- comp("browser-full", "alloc")
transport_pss <- comp("transport", "pss"); handler_pss <- comp("handler", "pss")
existing$candidate_signals <- list(
  scope_tools = TOOLS,
  C1_bounded_sdk_poll = list(supported = isTRUE((transport_alloc$allocation_bytes_ratio_on_off %||% 0) >= 1.20) || isTRUE((transport_pss$r_subject_active_peak_pss_ratio_on_off %||% 0) >= 1.20), evidence = transport_alloc %||% transport_pss),
  C2_indexed_coordinator_queue = list(supported = isTRUE((handler_alloc$allocation_bytes_ratio_on_off %||% 0) >= 1.20) && isTRUE((handler_alloc$buffered_max_on %||% 0) > 1), evidence = handler_alloc %||% handler_pss,
                                      caveat = "Handler layer uses the real coordinator with an equivalent injectable SDK-message consumer, not make_claude_handler end-to-end."),
  C3_partial_coalescing = list(
    supported = isTRUE((handler_alloc$allocation_bytes_ratio_on_off %||% 0) >= 1.20) || isTRUE((browser_alloc$allocation_bytes_ratio_on_off %||% 0) >= 1.20),
    directional = isTRUE((browser_alloc$allocation_count_ratio_on_off %||% 0) >= 1.50),
    note = "A count-only increase is follow-up signal, not implementation evidence without >=20% cumulative-byte or active PSS effect in matched repeats.",
    evidence = list(handler = handler_alloc, browser_full = browser_alloc)
  ),
  C4_cumulative_budget = list(supported = FALSE, note = "Select only if matched scaling repeats show cumulative pressure after C1-C3 attribution; one pilot is insufficient.")
)
existing$generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
existing$constraints <- list(
  synthetic_only = TRUE, source_or_secrets_transmitted = FALSE, fresh_subject_per_arm = TRUE,
  independent_external_sampler = TRUE, external_sample_interval_s = SAMPLE_INTERVAL_S,
  browser_memory_scope = "R subject and Chrome descendant-tree PSS reported separately; JS heap is a post-workload point, not a peak",
  bounded_runner_required = TRUE
)
write_json_atomic(existing, summary_path)
unlink(run_root, recursive = TRUE, force = TRUE)
cat("PLAN119_PROFILE_SUMMARY=", summary_path, "\n", sep = "")
cat("PLAN119_PROFILE_KEY=", key, "\n", sep = "")
cat("PLAN119_PROFILE_ARMS=", paste(vapply(results, function(item) as.character(item$partial), character(1)), collapse = ","), "\n", sep = "")
cat("PLAN119_PROFILE_HASH_EQUAL=", if (length(results) == 2L) identical(results[[1L]]$semantic_hash, results[[2L]]$semantic_hash) else "single-arm", "\n", sep = "")

.diagnostics_export_canonicalize <- function(bytes) {
  if (!is.raw(bytes) || !length(bytes) || length(bytes) > 8 * 1024^2 ||
      !identical(tail(bytes, 1L), charToRaw("\n")) || any(bytes == as.raw(13))) return(NULL)
  text <- tryCatch(rawToChar(bytes), error = function(error) NULL)
  if (is.null(text) || is.na(iconv(text, from = "UTF-8", to = "UTF-8", sub = NA))) return(NULL)
  lines <- strsplit(substr(text, 1L, nchar(text, type = "chars") - 1L), "\n", fixed = TRUE)[[1L]]
  if (!length(lines) || length(lines) > 200000L || any(!nzchar(lines)) ||
      any(nchar(lines, type = "bytes") > 16384L)) return(NULL)
  rebuilt <- character(length(lines)); events <- character(length(lines)); timestamps <- numeric(length(lines))
  for (index in seq_along(lines)) {
    value <- tryCatch(.strict_json_parse(lines[[index]]), error = function(error) NULL)
    if (!is.list(value) || !identical(names(value), c("schema", "event", "ts", "metrics")) ||
        is.null(.diagnostics_safe_integer(value$schema)) || value$schema != 1) return(NULL)
    row <- .diagnostics_canonical_row(value$event, value$metrics, now = function() value$ts)
    if (is.null(row)) return(NULL)
    canonical <- .diagnostics_canonical_encode(row)
    if (!identical(paste0(lines[[index]], "\n"), canonical)) return(NULL)
    rebuilt[[index]] <- canonical; events[[index]] <- row$event; timestamps[[index]] <- row$ts
  }
  output <- charToRaw(paste0(rebuilt, collapse = ""))
  list(bytes = output, rows = as.integer(length(lines)), events = events,
       minTs = min(timestamps), maxTs = max(timestamps))
}

.zip_u16 <- function(value) as.raw(c(value %% 256, floor(value / 256) %% 256))
.zip_u32 <- function(value) as.raw(c(
  value %% 256, floor(value / 256) %% 256,
  floor(value / 65536) %% 256, floor(value / 16777216) %% 256
))

.diagnostics_store_zip <- function(entries) {
  if (!is.list(entries) || !length(entries) || !identical(names(entries)[[1L]], "manifest.json") ||
      anyDuplicated(names(entries)) || any(!vapply(entries, is.raw, logical(1)))) return(NULL)
  local <- list(); central <- list(); offset <- 0
  for (index in seq_along(entries)) {
    name <- names(entries)[[index]]; name_raw <- charToRaw(name); data <- entries[[index]]
    valid_name <- identical(name, "manifest.json") || grepl("^logs/[0-9]{4}\\.jsonl$", name)
    if (!valid_name || length(name_raw) > 31L) return(NULL)
    crc <- .native_crc32(data); if (is.null(crc)) return(NULL)
    header <- c(
      .zip_u32(0x04034b50), .zip_u16(20), .zip_u16(0), .zip_u16(0),
      .zip_u16(0), .zip_u16(0), .zip_u32(crc), .zip_u32(length(data)),
      .zip_u32(length(data)), .zip_u16(length(name_raw)), .zip_u16(0), name_raw
    )
    local[[index]] <- c(header, data)
    central[[index]] <- c(
      .zip_u32(0x02014b50), .zip_u16(0x0314), .zip_u16(20), .zip_u16(0),
      .zip_u16(0), .zip_u16(0), .zip_u16(0), .zip_u32(crc),
      .zip_u32(length(data)), .zip_u32(length(data)), .zip_u16(length(name_raw)),
      .zip_u16(0), .zip_u16(0), .zip_u16(0), .zip_u16(0),
      .zip_u32(33152 * 65536), .zip_u32(offset), name_raw
    )
    offset <- offset + length(local[[index]])
  }
  local_raw <- do.call(c, local); central_raw <- do.call(c, central)
  eocd <- c(
    .zip_u32(0x06054b50), .zip_u16(0), .zip_u16(0),
    .zip_u16(length(entries)), .zip_u16(length(entries)),
    .zip_u32(length(central_raw)), .zip_u32(length(local_raw)), .zip_u16(0)
  )
  output <- c(local_raw, central_raw, eocd)
  if (length(output) > 64 * 1024^2 || !.native_verify_store_zip(output)) NULL else output
}

.diagnostics_export_capture <- function(root) {
  lock <- .diagnostics_retention_lock_acquire(root)
  if (is.null(lock)) return(list(category = "busy", handles = list()))
  on.exit(.diagnostics_retention_lock_release(lock), add = TRUE)
  .diagnostics_storage_recover_locked(lock)
  candidates <- .diagnostics_classify_candidates(lock)
  candidates <- Filter(function(candidate)
    identical(candidate$kind, "new") && !candidate$active && !candidate$unsafe &&
      candidate$size <= 8 * 1024^2, candidates)
  candidates <- candidates[order(vapply(candidates, `[[`, numeric(1), "created"),
                                   vapply(candidates, `[[`, character(1), "basename"))]
  handles <- list(); total <- 0
  for (candidate in candidates) {
    if (length(handles) >= 128L || total + candidate$size > 48 * 1024^2) break
    handle <- .native_fs_open_read_at(lock$root_handle, candidate$basename)
    if (is.null(handle)) next
    identity <- .native_file_stat(handle)
    fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")
    if (is.null(identity) || !isTRUE(identity$regular) || identity$nlink != 1 ||
        identity$size > 8 * 1024^2 || !identical(
          identity[fields], candidate$identity[fields]
        )) { .native_file_close(handle); next }
    handles[[length(handles) + 1L]] <- list(
      handle = handle, size = identity$size, identity = identity
    )
    total <- total + identity$size
  }
  list(category = "ok", handles = handles, rawBytes = total)
}

.diagnostics_export_build <- function(root) {
  capture <- .diagnostics_export_capture(root)
  if (!identical(capture$category, "ok")) return(list(category = capture$category))
  on.exit(for (entry in capture$handles) try(.native_file_close(entry$handle), silent = TRUE), add = TRUE)
  logs <- list(); event_counts <- list(); total_rows <- 0L; canonical_bytes <- 0
  min_ts <- Inf; max_ts <- -Inf
  for (entry in capture$handles) {
    source <- .native_file_read_all(entry$handle, 8 * 1024^2)
    after <- .native_file_stat(entry$handle)
    fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")
    if (!is.raw(source) || length(source) != entry$size || is.null(after) ||
        !identical(after[fields], entry$identity[fields])) next
    rebuilt <- .diagnostics_export_canonicalize(source)
    if (is.null(rebuilt) || total_rows + rebuilt$rows > 200000L) next
    logs[[length(logs) + 1L]] <- rebuilt$bytes
    total_rows <- total_rows + rebuilt$rows; canonical_bytes <- canonical_bytes + length(rebuilt$bytes)
    min_ts <- min(min_ts, rebuilt$minTs); max_ts <- max(max_ts, rebuilt$maxTs)
    counts <- table(rebuilt$events)
    for (name in names(counts)) event_counts[[name]] <- (event_counts[[name]] %||% 0L) + counts[[name]]
  }
  event_counts <- if (length(event_counts))
    as.list(event_counts[order(names(event_counts))]) else list()
  manifest <- list(
    schema = 1L, fileCount = length(logs), rowCount = total_rows,
    canonicalBytes = canonical_bytes,
    minTs = if (is.finite(min_ts)) min_ts else NULL,
    maxTs = if (is.finite(max_ts)) max_ts else NULL,
    eventCounts = event_counts,
    limits = list(files = 128L, sourceBytes = 8 * 1024^2,
                  rawBytes = 48 * 1024^2, rows = 200000L,
                  outputBytes = 64 * 1024^2)
  )
  entries <- c(
    list("manifest.json" = charToRaw(paste0(as.character(jsonlite::toJSON(
      manifest, auto_unbox = TRUE, null = "null", digits = NA
    )), "\n"))),
    setNames(logs, sprintf("logs/%04d.jsonl", seq_along(logs)))
  )
  zip <- .diagnostics_store_zip(entries)
  if (is.null(zip) || !.diagnostics_verify_store_zip(zip))
    return(list(category = "invalid"))
  list(category = "ok", bytes = zip, files = length(logs), rows = total_rows)
}

.diagnostics_export_worker_main <- function(root, destination, parent_pid,
                                            parent_start_token,
                                            bootstrap = .native_parent_guard_bootstrap) {
  if (!isTRUE(tryCatch(bootstrap(parent_pid, parent_start_token), error = function(error) FALSE)))
    return(list(category = "unsupported", files = 0L, rows = 0L, bytes = 0))
  if (!.diagnostics_scalar_character(root) || !.diagnostics_scalar_character(destination) ||
      !grepl("^/", destination) || file.exists(destination) || !dir.exists(dirname(destination))) {
    return(list(category = if (file.exists(destination)) "existing" else "invalid",
                files = 0L, rows = 0L, bytes = 0))
  }
  built <- .diagnostics_export_build(root)
  if (!identical(built$category, "ok")) return(c(built, list(files = 0L, rows = 0L, bytes = 0)))
  if (!.diagnostics_verify_store_zip(built$bytes))
    return(list(category = "invalid", files = 0L, rows = 0L, bytes = 0))
  parent <- .native_fs_open_root(dirname(destination))
  if (is.null(parent)) return(list(category = "permission", files = 0L, rows = 0L, bytes = 0))
  token <- .diagnostics_hex_token(); temporary <- paste0(".", basename(destination), ".tmp-", token)
  status <- .native_fs_atomic_write_at(parent, temporary, basename(destination), built$bytes)
  if (!identical(status, "ok"))
    return(list(category = status, files = 0L, rows = 0L, bytes = 0))
  published <- .native_fs_read_at(parent, basename(destination), 64 * 1024^2)
  if (!.diagnostics_verify_store_zip(published)) {
    identity <- .native_fs_stat_at(parent, basename(destination))
    if (!is.null(identity)) .native_fs_remove_at(
      parent, basename(destination), paste0(".invalid-", token), identity
    )
    return(list(category = "invalid", files = 0L, rows = 0L, bytes = 0))
  }
  list(category = "ok", files = built$files, rows = built$rows,
       bytes = length(published))
}

.diagnostics_export_capability <- function(
    rstudio_available = function() requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(error) FALSE)) &&
      "selectFile" %in% getNamespaceExports("rstudioapi"),
    supervision = .worker_supervision_capability) {
  schema <- .diagnostics_schema()
  base_available <- !is.null(schema) && requireNamespace("jsonlite", quietly = TRUE) &&
    requireNamespace("callr", quietly = TRUE) && isTRUE(rstudio_available()) &&
    all(unlist(.native_secure_capabilities()[c("secureFs", "parentDeath", "noReplace")]))
  supervised <- if (base_available) tryCatch(
    supervision(), error = function(error) list(category = "unsupported")
  ) else list(category = "unsupported")
  available <- base_available && identical(supervised$category, "ok")
  list(version = 1L, available = available,
       reason = if (available) "ok" else if (is.null(schema)) "schema_unavailable" else "unsupported",
       schema = 1L, canonical = !is.null(schema), network = FALSE)
}

.start_diagnostics_export_worker <- function(root, destination) {
  capability <- .worker_supervision_capability()
  if (!identical(capability$category, "ok")) return(NULL)
  parent_pid <- Sys.getpid(); parent_start <- .native_process_start_token(parent_pid)
  before <- .owned_descendant_pids(parent_pid)
  process <- tryCatch(callr::r_bg(
    function(root, destination, parent_pid, parent_start) {
      suppressPackageStartupMessages(library(shinyAssistantUI))
      shinyAssistantUI:::.diagnostics_export_worker_main(
        root, destination, parent_pid, parent_start
      )
    },
    args = list(root = root, destination = destination,
                parent_pid = parent_pid, parent_start = parent_start),
    supervise = TRUE, stdout = "/dev/null", stderr = "/dev/null"
  ), error = function(error) NULL)
  if (is.null(process)) return(NULL)
  owned <- .capture_owned_processes(before)
  .diagnostics_callr_supervisor$references <- .diagnostics_callr_supervisor$references + 1L
  state <- new.env(parent = emptyenv()); state$finalized <- FALSE; state$result <- NULL
  finalize <- function(cancel = FALSE) {
    if (state$finalized) return(state$result)
    if (cancel && isTRUE(tryCatch(process$is_alive(), error = function(error) FALSE))) {
      tryCatch(process$kill(), error = function(error) NULL)
      tryCatch(process$wait(timeout = 2000), error = function(error) NULL)
    }
    if (isTRUE(tryCatch(process$is_alive(), error = function(error) FALSE))) return(NULL)
    state$result <- tryCatch(process$get_result(), error = function(error)
      list(category = "io_error", files = 0L, rows = 0L, bytes = 0))
    .reap_owned_processes(owned)
    .diagnostics_callr_supervisor$references <- max(
      0L, .diagnostics_callr_supervisor$references - 1L
    )
    .release_package_callr_supervisor(); state$finalized <- TRUE
    state$result
  }
  list(
    status = function() {
      if (isTRUE(tryCatch(process$is_alive(), error = function(error) FALSE))) "running"
      else { finalize(); "complete" }
    },
    result = function(timeout = 10) {
      if (!state$finalized) tryCatch(process$wait(timeout = timeout * 1000), error = function(error) NULL)
      finalize()
    },
    cancel = function() { finalize(cancel = TRUE); invisible(TRUE) },
    pid = function() process$get_pid()
  )
}

.new_support_bundle_controller <- function(
    diagnostics_root,
    picker = function() rstudioapi::selectFile(
      caption = "Export support bundle", label = "Export", existing = FALSE
    ),
    start_worker = .start_diagnostics_export_worker) {
  state <- new.env(parent = emptyenv()); state$workers <- list(); state$closed <- FALSE
  pick <- function() {
    if (state$closed) return("unsupported")
    destination <- tryCatch(picker(), error = function(error) NULL)
    if (is.null(destination) || !length(destination) || is.na(destination[[1L]]) ||
        !nzchar(as.character(destination[[1L]]))) return("cancelled")
    destination <- path.expand(as.character(destination[[1L]]))
    if (!grepl("^/", destination) || file.exists(destination) || !dir.exists(dirname(destination)))
      return(if (file.exists(destination)) "existing" else "invalid")
    worker <- tryCatch(start_worker(diagnostics_root, destination), error = function(error) NULL)
    if (is.null(worker)) return("unsupported")
    state$workers[[length(state$workers) + 1L]] <- worker
    "started"
  }
  close <- function() {
    if (state$closed) return(FALSE)
    state$closed <- TRUE
    for (worker in state$workers) if (is.function(worker$cancel)) try(worker$cancel(), silent = TRUE)
    state$workers <- list(); TRUE
  }
  list(pick = pick, close = close,
       workers = function() state$workers)
}


.diagnostics_verify_store_zip <- function(bytes) {
  if (!.native_verify_store_zip(bytes)) return(FALSE)
  entries <- .native_store_zip_entries(bytes)
  if (is.null(entries) || !length(entries) ||
      !identical(names(entries)[[1L]], "manifest.json")) return(FALSE)
  expected_names <- c("manifest.json", if (length(entries) > 1L)
    sprintf("logs/%04d.jsonl", seq_len(length(entries) - 1L)) else character())
  if (!identical(names(entries), expected_names)) return(FALSE)
  manifest_bytes <- entries[[1L]]
  if (!length(manifest_bytes) || !identical(tail(manifest_bytes, 1L), charToRaw("\n")) ||
      any(manifest_bytes == as.raw(13))) return(FALSE)
  manifest_text <- tryCatch(rawToChar(manifest_bytes), error = function(error) NULL)
  if (is.null(manifest_text) || is.na(iconv(manifest_text, "UTF-8", "UTF-8", sub = NA))) return(FALSE)
  manifest <- tryCatch(.strict_json_parse(substr(
    manifest_text, 1L, nchar(manifest_text, type = "chars") - 1L
  )), error = function(error) NULL)
  required <- c("schema", "fileCount", "rowCount", "canonicalBytes", "minTs",
                "maxTs", "eventCounts", "limits")
  limit_names <- c("files", "sourceBytes", "rawBytes", "rows", "outputBytes")
  if (!is.list(manifest) || !identical(names(manifest), required) ||
      !identical(manifest$schema, 1) || !is.list(manifest$eventCounts) ||
      (length(manifest$eventCounts) && is.null(names(manifest$eventCounts))) || !is.list(manifest$limits) ||
      !identical(names(manifest$limits), limit_names) ||
      !identical(unname(unlist(manifest$limits, use.names = FALSE)),
                 c(128, 8 * 1024^2, 48 * 1024^2, 200000, 64 * 1024^2))) return(FALSE)
  logs <- entries[-1L]
  if (sum(vapply(logs, length, integer(1))) > 48 * 1024^2) return(FALSE)
  total_rows <- 0; canonical_bytes <- 0
  min_ts <- Inf; max_ts <- -Inf; counts <- list()
  for (raw in logs) {
    rebuilt <- .diagnostics_export_canonicalize(raw)
    if (is.null(rebuilt)) return(FALSE)
    total_rows <- total_rows + rebuilt$rows
    if (total_rows > 200000L) return(FALSE)
    canonical_bytes <- canonical_bytes + length(rebuilt$bytes)
    min_ts <- min(min_ts, rebuilt$minTs); max_ts <- max(max_ts, rebuilt$maxTs)
    tabled <- table(rebuilt$events)
    for (name in names(tabled)) counts[[name]] <- (counts[[name]] %||% 0) + as.numeric(tabled[[name]])
  }
  counts <- if (length(counts)) counts[order(names(counts))] else list()
  numeric_equal <- function(a, b) {
    parsed <- .settings_safe_integer(a)
    !is.null(parsed) && identical(as.numeric(parsed), as.numeric(b))
  }
  if (!numeric_equal(manifest$fileCount, length(logs)) ||
      !numeric_equal(manifest$rowCount, total_rows) ||
      !numeric_equal(manifest$canonicalBytes, canonical_bytes) ||
      !identical(names(manifest$eventCounts), names(counts)) ||
      length(counts) != length(manifest$eventCounts) ||
      any(!vapply(seq_along(counts), function(index)
        numeric_equal(manifest$eventCounts[[index]], counts[[index]]), logical(1)))) return(FALSE)
  if (!length(logs)) {
    if (!is.null(manifest$minTs) || !is.null(manifest$maxTs)) return(FALSE)
  } else if (!numeric_equal(manifest$minTs, min_ts) ||
             !numeric_equal(manifest$maxTs, max_ts)) return(FALSE)
  TRUE
}

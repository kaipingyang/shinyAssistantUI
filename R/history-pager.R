# Bounded, revision-aware history paging ---------------------------------------

.history_base36 <- function(value) {
  value <- floor(abs(as.numeric(value)))
  if (!is.finite(value) || value == 0) return("0")
  alphabet <- c(as.character(0:9), letters)
  output <- character()
  while (value > 0) {
    digit <- value %% 36
    output <- c(alphabet[[digit + 1L]], output)
    value <- floor(value / 36)
  }
  paste(output, collapse = "")
}

.history_hash_text <- function(text) {
  bytes <- as.integer(charToRaw(enc2utf8(paste(text, collapse = "\u001f"))))
  first <- 2166136261
  second <- 1315423911
  for (byte in bytes) {
    first <- (first * 16777619 + byte) %% 4294967296
    second <- (second * 33 + byte + 1) %% 4294967296
  }
  paste0(.history_base36(first), .history_base36(second))
}

.new_history_page_cache <- function(
    max_entries = getOption("shinyAssistantUI.history_cache_entries", 8L),
    max_bytes = getOption("shinyAssistantUI.history_cache_bytes", 32 * 1024^2)) {
  max_entries <- suppressWarnings(as.integer(max_entries)[[1L]])
  max_bytes <- suppressWarnings(as.numeric(max_bytes)[[1L]])
  if (is.na(max_entries) || max_entries < 1L) max_entries <- 1L
  if (!is.finite(max_bytes) || max_bytes < 1) max_bytes <- 1024^2
  max_entries <- min(max_entries, 64L)
  max_bytes <- min(max_bytes, 256 * 1024^2)
  data <- new.env(parent = emptyenv())
  sizes <- new.env(parent = emptyenv())
  order <- character()
  total_bytes <- 0

  release <- function(key) {
    key <- as.character(key)[[1L]]
    if (!exists(key, envir = data, inherits = FALSE)) return(FALSE)
    total_bytes <<- max(0, total_bytes - get(key, envir = sizes, inherits = FALSE))
    rm(list = key, envir = data)
    rm(list = key, envir = sizes)
    order <<- setdiff(order, key)
    TRUE
  }
  touch <- function(key) order <<- c(setdiff(order, key), key)
  set <- function(key, value) {
    key <- as.character(key)[[1L]]
    bytes <- as.numeric(utils::object.size(value))
    if (!is.finite(bytes) || bytes > max_bytes) return(FALSE)
    release(key)
    while (length(order) >= max_entries || total_bytes + bytes > max_bytes) {
      if (!length(order)) return(FALSE)
      release(order[[1L]])
    }
    assign(key, value, envir = data)
    assign(key, bytes, envir = sizes)
    total_bytes <<- total_bytes + bytes
    touch(key)
    TRUE
  }
  list(
    has = function(key) exists(as.character(key)[[1L]], envir = data, inherits = FALSE),
    get = function(key) {
      key <- as.character(key)[[1L]]
      if (!exists(key, envir = data, inherits = FALSE)) return(NULL)
      touch(key)
      get(key, envir = data, inherits = FALSE)
    },
    set = set,
    release = release,
    keys = function() order,
    stats = function() list(
      entries = length(order), bytes = total_bytes,
      max_entries = max_entries, max_bytes = max_bytes
    )
  )
}

.history_complete_end <- function(path, size = file.info(path)$size) {
  size <- as.numeric(size)
  if (!is.finite(size) || size <= 0) return(0)
  tail_bytes <- min(size, 64 * 1024)
  connection <- file(path, open = "rb")
  on.exit(close(connection), add = TRUE)
  seek(connection, where = size - tail_bytes, origin = "start")
  bytes <- readBin(connection, what = "raw", n = tail_bytes)
  boundaries <- which(bytes == as.raw(10L))
  if (!length(boundaries)) return(0)
  as.numeric(size - tail_bytes + max(boundaries))
}

.history_hash_raw <- function(bytes) {
  values <- as.integer(bytes)
  first <- 2166136261
  second <- 1315423911
  for (byte in values) {
    first <- (first * 16777619 + byte) %% 4294967296
    second <- (second * 33 + byte + 1) %% 4294967296
  }
  paste0(.history_base36(first), .history_base36(second))
}

.history_source_sample_hash <- function(path, complete_end) {
  complete_end <- as.numeric(complete_end)
  if (!is.finite(complete_end) || complete_end <= 0) return(.history_hash_raw(raw()))
  width <- min(64 * 1024, complete_end)
  connection <- file(path, open = "rb")
  on.exit(close(connection), add = TRUE)
  prefix <- readBin(connection, what = "raw", n = width)
  suffix <- raw()
  if (complete_end > width) {
    seek(connection, where = max(0, complete_end - width), origin = "start")
    suffix <- readBin(connection, what = "raw", n = width)
  }
  .history_hash_raw(c(prefix, as.raw(0L), suffix))
}

.claude_history_source <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  info <- file.info(path)
  if (is.na(info$size) || info$size < 0) stop("Claude transcript is unavailable")
  complete_end <- .history_complete_end(path, info$size)
  list(
    path = path,
    size = as.numeric(info$size),
    mtime = as.numeric(info$mtime),
    complete_end = complete_end,
    sample_hash = .history_source_sample_hash(path, complete_end)
  )
}

.claude_history_revision <- function(source, sdk_version) {
  .history_hash_text(c(
    "history-index-v2", sdk_version, source$path,
    format(source$size, scientific = FALSE),
    format(source$mtime, digits = 17, scientific = FALSE),
    format(source$complete_end, scientific = FALSE),
    source$sample_hash
  ))
}

.history_content_metadata <- function(entry) {
  content <- entry[["message"]][["content"]]
  compact <- isTRUE(entry[["isCompactSummary"]])
  renderable <- FALSE
  tool_uses <- character()
  tool_results <- character()
  if (identical(entry[["type"]], "user")) {
    text <- character()
    if (is.character(content)) {
      text <- content
    } else if (is.list(content)) {
      for (block in content) {
        if (identical(block[["type"]], "text")) {
          text <- c(text, as.character(block[["text"]] %||% ""))
        } else if (identical(block[["type"]], "tool_result")) {
          id <- block[["tool_use_id"]]
          if (is.character(id) && length(id) == 1L && !is.na(id) && nzchar(id)) {
            tool_results <- c(tool_results, id)
          }
        }
      }
    }
    joined <- paste(text, collapse = "")
    renderable <- nzchar(trimws(joined)) &&
      (compact || !.is_synthetic_system_user_text(joined))
  } else if (identical(entry[["type"]], "assistant")) {
    if (is.character(content)) renderable <- any(nzchar(content))
    if (is.list(content)) {
      for (block in content) {
        if (identical(block[["type"]], "text") && nzchar(block[["text"]] %||% "")) {
          renderable <- TRUE
        } else if (identical(block[["type"]], "tool_use")) {
          renderable <- TRUE
          id <- block[["id"]]
          if (is.character(id) && length(id) == 1L && !is.na(id) && nzchar(id)) {
            tool_uses <- c(tool_uses, id)
          }
        }
      }
    }
  }
  list(
    renderable = renderable,
    tool_uses = unique(tool_uses),
    tool_results = unique(tool_results),
    compact = compact
  )
}

.build_claude_history_index <- function(path, sdk_version = NULL) {
  sdk_version <- as.character(sdk_version %||% tryCatch(
    utils::packageVersion("ClaudeAgentSDK"), error = function(error) "unknown"
  ))
  source <- .claude_history_source(path)
  entries <- list()
  if (source$complete_end > 0) {
    connection <- file(source$path, open = "rb", encoding = "UTF-8")
    on.exit(close(connection), add = TRUE)
    repeat {
      start <- as.numeric(seek(connection, where = NA, origin = "start"))
      if (start >= source$complete_end) break
      line <- readLines(connection, n = 1L, warn = FALSE, encoding = "UTF-8")
      if (!length(line)) break
      end <- as.numeric(seek(connection, where = NA, origin = "start"))
      if (end > source$complete_end) break
      entry <- tryCatch(
        jsonlite::fromJSON(line, simplifyVector = FALSE),
        error = function(error) NULL
      )
      if (is.null(entry) || !is.list(entry) ||
          !(entry[["type"]] %in% c("user", "assistant", "progress", "system", "attachment")) ||
          !is.character(entry[["uuid"]]) || length(entry[["uuid"]]) != 1L ||
          is.na(entry[["uuid"]]) || !nzchar(entry[["uuid"]])) next
      content <- .history_content_metadata(entry)
      entries[[length(entries) + 1L]] <- list(
        uuid = entry[["uuid"]],
        parent = entry[["parentUuid"]] %||% NULL,
        type = entry[["type"]],
        is_sidechain = isTRUE(entry[["isSidechain"]]),
        is_meta = isTRUE(entry[["isMeta"]]),
        has_team = !is.null(entry[["teamName"]]),
        compact = content$compact,
        renderable = content$renderable,
        tool_uses = content$tool_uses,
        tool_results = content$tool_results,
        start = start,
        end = end
      )
    }
  }
  list(
    schema = 2L,
    sdk_version = sdk_version,
    source = source,
    revision = .claude_history_revision(source, sdk_version),
    entries = entries
  )
}

.claude_history_cache_root <- function() {
  getOption(
    "shinyAssistantUI.history_index_dir",
    file.path(tools::R_user_dir("shinyAssistantUI", which = "cache"), "history-index")
  )
}

.claude_history_sidecar_path <- function(path, cache_root) {
  file.path(cache_root, paste0("history-", .history_hash_text(
    normalizePath(path, winslash = "/", mustWork = FALSE)
  ), ".rds"))
}

.history_sidecar_limits <- function() {
  entries <- suppressWarnings(as.integer(getOption(
    "shinyAssistantUI.history_index_entries", 256L
  ))[[1L]])
  bytes <- suppressWarnings(as.numeric(getOption(
    "shinyAssistantUI.history_index_bytes", 256 * 1024^2
  ))[[1L]])
  if (is.na(entries) || entries < 1L) entries <- 256L
  if (!is.finite(bytes) || bytes < 1) bytes <- 256 * 1024^2
  list(entries = min(entries, 4096L), bytes = min(bytes, 4 * 1024^3))
}

.prune_history_sidecars <- function(cache_root, keep = NULL,
                                    max_entries = NULL, max_bytes = NULL) {
  if (!dir.exists(cache_root)) {
    return(invisible(list(entries = 0L, bytes = 0)))
  }
  limits <- .history_sidecar_limits()
  max_entries <- suppressWarnings(as.integer(max_entries %||% limits$entries)[[1L]])
  max_bytes <- suppressWarnings(as.numeric(max_bytes %||% limits$bytes)[[1L]])
  if (is.na(max_entries) || max_entries < 1L) max_entries <- limits$entries
  if (!is.finite(max_bytes) || max_bytes < 1) max_bytes <- limits$bytes
  keep <- if (is.null(keep)) character() else normalizePath(
    keep, winslash = "/", mustWork = FALSE
  )
  files <- list.files(
    cache_root, pattern = "^history-.*[.]rds$", full.names = TRUE
  )
  repeat {
    files <- files[file.exists(files)]
    if (!length(files)) break
    info <- file.info(files)
    sizes <- as.numeric(info$size)
    sizes[is.na(sizes)] <- 0
    if (length(files) <= max_entries && sum(sizes) <= max_bytes) break
    normalized <- normalizePath(files, winslash = "/", mustWork = FALSE)
    candidates <- which(!(normalized %in% keep))
    # `keep` protects the sidecar currently being read while older candidates
    # exist, but cannot override the directory hard budget. An oversized current
    # index remains usable in memory for this traversal and is not persisted.
    if (!length(candidates)) candidates <- seq_along(files)
    mtimes <- as.numeric(info$mtime)
    mtimes[is.na(mtimes)] <- -Inf
    victim <- candidates[order(mtimes[candidates], basename(files[candidates]))[[1L]]]
    unlink(files[[victim]], force = TRUE)
    files <- files[-victim]
  }
  files <- files[file.exists(files)]
  sizes <- if (length(files)) as.numeric(file.info(files)$size) else numeric()
  sizes[is.na(sizes)] <- 0
  invisible(list(entries = length(files), bytes = sum(sizes)))
}

.history_index_valid <- function(index, source, sdk_version) {
  is.list(index) && identical(index$schema, 2L) &&
    identical(index$sdk_version, as.character(sdk_version)) &&
    is.list(index$entries) && is.list(index$source) &&
    identical(index$source$path, source$path) &&
    identical(index$source$size, source$size) &&
    identical(index$source$mtime, source$mtime) &&
    identical(index$source$complete_end, source$complete_end) &&
    identical(index$source$sample_hash, source$sample_hash) &&
    identical(index$revision, .claude_history_revision(source, sdk_version))
}

.write_history_sidecar <- function(index, path) {
  directory <- dirname(path)
  if (!dir.exists(directory)) dir.create(directory, recursive = TRUE, mode = "0700")
  Sys.chmod(directory, mode = "0700", use_umask = FALSE)
  temporary <- tempfile("history-index-", tmpdir = directory)
  on.exit(if (file.exists(temporary)) unlink(temporary, force = TRUE), add = TRUE)
  saveRDS(index, temporary, version = 3)
  Sys.chmod(temporary, mode = "0600", use_umask = FALSE)
  if (!file.rename(temporary, path)) stop("Could not atomically replace history index")
  Sys.chmod(path, mode = "0600", use_umask = FALSE)
  invisible(path)
}

.load_claude_history_index <- function(
    path, cache_root = .claude_history_cache_root(), sdk_version = NULL) {
  sdk_version <- as.character(sdk_version %||% utils::packageVersion("ClaudeAgentSDK"))
  source <- .claude_history_source(path)
  sidecar <- .claude_history_sidecar_path(source$path, cache_root)
  cached <- if (file.exists(sidecar)) tryCatch(readRDS(sidecar), error = function(error) NULL) else NULL
  if (.history_index_valid(cached, source, sdk_version)) {
    try(Sys.setFileTime(sidecar, Sys.time()), silent = TRUE)
    .prune_history_sidecars(cache_root, keep = sidecar)
    cached$sidecar_path <- sidecar
    return(cached)
  }
  rebuilt <- .build_claude_history_index(source$path, sdk_version = sdk_version)
  .write_history_sidecar(rebuilt, sidecar)
  .prune_history_sidecars(cache_root, keep = sidecar)
  rebuilt$sidecar_path <- sidecar
  rebuilt
}

.claude_index_chain <- function(entries) {
  if (!length(entries)) return(list())
  uuids <- vapply(entries, `[[`, character(1), "uuid")
  by_uuid <- stats::setNames(entries, uuids)
  positions <- stats::setNames(seq_along(entries), uuids)
  parents <- vapply(entries, function(entry) entry$parent %||% NA_character_, character(1))
  parent_uuids <- stats::na.omit(parents)
  terminals <- Filter(function(entry) !(entry$uuid %in% parent_uuids), entries)
  leaves <- list()
  for (terminal in terminals) {
    current <- terminal
    seen <- character()
    while (!is.null(current)) {
      if (current$uuid %in% seen) break
      seen <- c(seen, current$uuid)
      if (current$type %in% c("user", "assistant")) {
        leaves[[length(leaves) + 1L]] <- current
        break
      }
      current <- if (!is.null(current$parent)) by_uuid[[current$parent]] else NULL
    }
  }
  if (!length(leaves)) return(list())
  main <- Filter(function(entry) {
    !entry$is_sidechain && !entry$is_meta && !entry$has_team
  }, leaves)
  pool <- if (length(main)) main else leaves
  leaf_positions <- vapply(pool, function(entry) positions[[entry$uuid]] %||% -1L, integer(1))
  current <- pool[[which.max(leaf_positions)]]
  chain <- list()
  seen <- character()
  while (!is.null(current)) {
    if (current$uuid %in% seen) break
    seen <- c(seen, current$uuid)
    chain[[length(chain) + 1L]] <- current
    current <- if (!is.null(current$parent)) by_uuid[[current$parent]] else NULL
  }
  rev(chain)
}

.claude_index_units <- function(index) {
  chain <- .claude_index_chain(index$entries)
  visible <- Filter(function(entry) {
    entry$type %in% c("user", "assistant") && !entry$is_meta &&
      !entry$is_sidechain && !entry$has_team && isTRUE(entry$renderable)
  }, chain)
  units <- list()
  for (entry in visible) {
    role <- if (identical(entry$type, "user") && !isTRUE(entry$compact)) "user" else "assistant"
    if (identical(role, "user") || !length(units)) {
      units[[length(units) + 1L]] <- list(entry)
    } else {
      units[[length(units)]][[length(units[[length(units)]]) + 1L]] <- entry
    }
  }
  list(chain = chain, units = units)
}

.encode_history_cursor <- function(traversal_id, revision, upper) {
  payload <- as.character(jsonlite::toJSON(list(
    v = 1L, t = traversal_id, r = revision, u = as.integer(upper)
  ), auto_unbox = TRUE))
  base64enc::base64encode(charToRaw(payload))
}

.decode_history_cursor <- function(cursor) {
  if (!is.character(cursor) || length(cursor) != 1L || is.na(cursor) || !nzchar(cursor)) return(NULL)
  tryCatch({
    value <- jsonlite::fromJSON(
      rawToChar(base64enc::base64decode(cursor)), simplifyVector = FALSE
    )
    if (!is.list(value) || !identical(as.integer(value$v), 1L) ||
        !is.character(value$t) || !is.character(value$r) ||
        is.null(value$u)) return(NULL)
    value$u <- as.integer(value$u)
    if (is.na(value$u) || value$u < 0L) return(NULL)
    value
  }, error = function(error) NULL)
}

.read_claude_index_entries <- function(index, selected_ids, dependencies) {
  required <- unique(c(as.character(selected_ids), as.character(dependencies)))
  metadata <- Filter(function(entry) entry$uuid %in% required, .claude_index_chain(index$entries))
  if (!length(metadata)) return(list())
  connection <- file(index$source$path, open = "rb")
  on.exit(close(connection), add = TRUE)
  lapply(metadata, function(item) {
    seek(connection, where = item$start, origin = "start")
    bytes <- readBin(connection, what = "raw", n = item$end - item$start)
    while (length(bytes) && tail(bytes, 1L) %in% as.raw(c(10L, 13L))) bytes <- head(bytes, -1L)
    entry <- jsonlite::fromJSON(rawToChar(bytes), simplifyVector = FALSE)
    list(
      type = entry[["type"]], uuid = entry[["uuid"]] %||% "",
      session_id = entry[["sessionId"]] %||% "",
      message = entry[["message"]],
      is_compact_summary = entry[["isCompactSummary"]],
      is_visible_in_transcript_only = entry[["isVisibleInTranscriptOnly"]]
    )
  })
}

.history_stale_page <- function(revision = NULL) {
  structure(list(
    messages = list(), cursor = NULL, has_more = FALSE,
    revision = revision, stale = TRUE
  ), class = c("shinyAssistantUI_history_page", "list"))
}

.history_unit_bounds <- function(units, upper, limit) {
  upper <- min(length(units), as.integer(upper))
  if (upper <= 0L) return(list(lower = 0L, upper = 0L, next_upper = 0L))
  candidate <- upper
  selected_lower <- upper
  count <- 0L
  repeat {
    unit_size <- length(units[[candidate]])
    if (count > 0L && count + unit_size > limit) break
    selected_lower <- candidate
    count <- count + unit_size
    if (candidate == 1L || count >= limit) break
    candidate <- candidate - 1L
  }
  list(lower = selected_lower, upper = upper, next_upper = selected_lower - 1L)
}

.history_thread_units <- function(messages) {
  units <- list()
  for (message in messages) {
    if (identical(message$role, "user") || !length(units)) {
      units[[length(units) + 1L]] <- list(message)
    } else {
      units[[length(units)]][[length(units[[length(units)]]) + 1L]] <- message
    }
  }
  units
}

.claude_index_page <- function(index, cursor = NULL, limit = 50L,
                               traversal_id, decisions = list(), metadata = list()) {
  limit <- suppressWarnings(as.integer(limit)[[1L]])
  if (is.na(limit) || limit < 1L) limit <- 50L
  limit <- min(limit, 200L)
  indexed <- .claude_index_units(index)
  units <- indexed$units
  decoded <- if (is.null(cursor)) NULL else .decode_history_cursor(cursor)
  if (!is.null(cursor) && (is.null(decoded) ||
      !identical(decoded$t, traversal_id) || !identical(decoded$r, index$revision))) {
    return(.history_stale_page(index$revision))
  }
  upper <- if (is.null(decoded)) length(units) else min(length(units), decoded$u)
  if (upper <= 0L) {
    return(structure(list(
      messages = list(), cursor = NULL, has_more = FALSE,
      revision = index$revision, stale = FALSE
    ), class = c("shinyAssistantUI_history_page", "list")))
  }
  bounds <- .history_unit_bounds(units, upper, limit)
  lower <- bounds$lower
  selected <- unlist(units[seq.int(lower, upper)], recursive = FALSE)
  selected_ids <- vapply(selected, `[[`, character(1), "uuid")
  tool_ids <- unique(unlist(lapply(selected, `[[`, "tool_uses"), use.names = FALSE))
  dependency_ids <- if (length(tool_ids)) vapply(Filter(function(entry) {
    length(intersect(entry$tool_results, tool_ids)) > 0L
  }, indexed$chain), `[[`, character(1), "uuid") else character()
  raw_messages <- .read_claude_index_entries(index, selected_ids, dependency_ids)
  converted <- .claude_msgs_to_thread(raw_messages, decisions = decisions, metadata = metadata)
  converted <- Filter(function(message) sub("^h-", "", message$id) %in% selected_ids, converted)
  next_upper <- bounds$next_upper
  structure(list(
    messages = converted,
    cursor = if (next_upper > 0L) .encode_history_cursor(
      traversal_id, index$revision, next_upper
    ) else NULL,
    has_more = next_upper > 0L,
    revision = index$revision,
    stale = FALSE
  ), class = c("shinyAssistantUI_history_page", "list"))
}

.claude_history_index_capability <- function() {
  version <- tryCatch(utils::packageVersion("ClaudeAgentSDK"), error = function(error) NULL)
  if (is.null(version) || version < "0.2.5" || version >= "0.3.0") {
    return(list(ok = FALSE, reason = "unsupported-sdk-version"))
  }
  finder <- tryCatch(
    utils::getFromNamespace(".find_session_file", "ClaudeAgentSDK"),
    error = function(error) NULL
  )
  parameters <- if (is.function(finder)) names(formals(finder)) else character()
  if (!is.function(finder) || !identical(parameters, c("session_id", "directory"))) {
    return(list(ok = FALSE, reason = "unsupported-private-path-api"))
  }
  list(ok = TRUE, version = as.character(version), finder = finder)
}

.fallback_history_page <- function(messages, cursor = NULL, limit = 50L,
                                   traversal_id, revision) {
  decoded <- if (is.null(cursor)) NULL else .decode_history_cursor(cursor)
  if (!is.null(cursor) && (is.null(decoded) || !identical(decoded$t, traversal_id) ||
      !identical(decoded$r, revision))) return(.history_stale_page(revision))
  limit <- suppressWarnings(as.integer(limit)[[1L]])
  if (is.na(limit) || limit < 1L) limit <- 50L
  limit <- min(limit, 200L)
  units <- .history_thread_units(messages)
  upper <- if (is.null(decoded)) length(units) else min(length(units), decoded$u)
  bounds <- .history_unit_bounds(units, upper, limit)
  selected <- if (bounds$lower > 0L) {
    unlist(units[seq.int(bounds$lower, bounds$upper)], recursive = FALSE)
  } else {
    list()
  }
  next_upper <- bounds$next_upper
  structure(list(
    messages = selected,
    cursor = if (next_upper > 0L) .encode_history_cursor(
      traversal_id, revision, next_upper
    ) else NULL,
    has_more = next_upper > 0L,
    revision = revision,
    stale = FALSE
  ), class = c("shinyAssistantUI_history_page", "list"))
}

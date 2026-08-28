# Large character tool results are indexed by opaque metadata. The browser receives
# only the descriptor; bounded preview bytes live in a private temporary file until
# the Shiny session ends. Structured values deliberately remain on the existing
# bounded-preview path because indexing them must not serialize a large object.
.new_lazy_tool_result_store <- function(
    root = tempfile("shinyAssistantUI-tool-results-"),
    threshold_bytes = getOption("shinyAssistantUI.lazy_tool_result_threshold_bytes", 64 * 1024),
    chunk_bytes = getOption("shinyAssistantUI.lazy_tool_result_chunk_bytes", 64 * 1024),
    max_entries = getOption("shinyAssistantUI.lazy_tool_result_max_entries", 128L),
    max_total_bytes = getOption("shinyAssistantUI.lazy_tool_result_max_total_bytes", 128 * 1024^2)) {
  threshold_bytes <- suppressWarnings(as.numeric(threshold_bytes)[[1L]])
  chunk_bytes <- suppressWarnings(as.integer(chunk_bytes)[[1L]])
  max_entries <- suppressWarnings(as.integer(max_entries)[[1L]])
  max_total_bytes <- suppressWarnings(as.numeric(max_total_bytes)[[1L]])
  if (!is.finite(threshold_bytes) || threshold_bytes < 1) threshold_bytes <- 64 * 1024
  if (is.na(chunk_bytes) || chunk_bytes < 4L) chunk_bytes <- 64L * 1024L
  if (is.na(max_entries) || max_entries < 1L) max_entries <- 128L
  if (!is.finite(max_total_bytes) || max_total_bytes < 1) max_total_bytes <- 128 * 1024^2
  max_entries <- min(max_entries, 128L)
  max_total_bytes <- min(max_total_bytes, 128 * 1024^2)
  chunk_bytes <- min(chunk_bytes, 256L * 1024L)

  entries <- new.env(parent = emptyenv())
  owners <- new.env(parent = emptyenv())
  generation <- 0L
  access_sequence <- 0
  active <- TRUE

  ensure_root <- function() {
    if (!active) return(FALSE)
    if (!dir.exists(root)) {
      dir.create(root, recursive = TRUE, mode = "0700", showWarnings = FALSE)
    }
    if (!dir.exists(root)) return(FALSE)
    Sys.chmod(root, mode = "0700", use_umask = FALSE)
    TRUE
  }

  scalar_string <- function(value) {
    is.character(value) && length(value) == 1L && !is.na(value)
  }

  owner_key_for <- function(thread_id, tool_call_id) {
    paste0(thread_id, "\u001f", tool_call_id)
  }

  remove_handle <- function(handle) {
    if (!exists(handle, envir = entries, inherits = FALSE)) return(invisible(FALSE))
    entry <- get(handle, envir = entries, inherits = FALSE)
    unlink(entry$path, force = TRUE)
    rm(list = handle, envir = entries)
    owner_key <- owner_key_for(entry$thread_id, entry$tool_call_id)
    if (identical(get0(owner_key, envir = owners, inherits = FALSE), handle)) {
      rm(list = owner_key, envir = owners)
    }
    invisible(TRUE)
  }

  touch <- function(handle) {
    if (!exists(handle, envir = entries, inherits = FALSE)) return(NULL)
    access_sequence <<- access_sequence + 1
    entry <- get(handle, envir = entries, inherits = FALSE)
    entry$accessed <- access_sequence
    assign(handle, entry, envir = entries)
    entry
  }

  descriptor_for <- function(handle, entry) {
    source_bytes <- max(entry$bytes, entry$source_bytes)
    truncated <- source_bytes > entry$bytes
    list(
      kind = "lazy-tool-result",
      version = 1L,
      handle = handle,
      generation = entry$generation,
      threadId = entry$thread_id,
      toolCallId = entry$tool_call_id,
      originalBytes = entry$bytes,
      sourceBytes = source_bytes,
      truncated = truncated,
      chunkBytes = chunk_bytes,
      summary = if (truncated) paste0(
        "Bounded ", format(entry$bytes, scientific = FALSE, trim = TRUE),
        "-byte preview of ", format(source_bytes, scientific = FALSE, trim = TRUE),
        "-byte tool result. Expand to load progressively."
      ) else paste0(
        "Large tool result (", format(entry$bytes, scientific = FALSE, trim = TRUE),
        " bytes). Expand to load progressively."
      )
    )
  }

  evict_until_fits <- function(incoming_bytes, incoming_entries = 1L) {
    repeat {
      handles <- ls(entries, all.names = TRUE)
      total <- if (length(handles)) sum(vapply(
        handles, function(handle) get(handle, envir = entries, inherits = FALSE)$bytes,
        numeric(1)
      )) else 0
      if (length(handles) + incoming_entries <= max_entries &&
          total + incoming_bytes <= max_total_bytes) return(TRUE)
      if (!length(handles)) return(FALSE)
      accessed <- vapply(
        handles, function(handle) get(handle, envir = entries, inherits = FALSE)$accessed,
        numeric(1)
      )
      remove_handle(handles[[which.min(accessed)]])
    }
  }

  put <- function(result, thread_id, tool_call_id, source_bytes = NULL) {
    if (!active || !scalar_string(result) || !scalar_string(thread_id) ||
        !scalar_string(tool_call_id)) return(NULL)
    text <- enc2utf8(result)
    size <- nchar(text, type = "bytes")
    if (!is.finite(size) || size <= threshold_bytes || size > max_total_bytes || !ensure_root()) {
      return(NULL)
    }
    source_bytes <- suppressWarnings(as.numeric(source_bytes %||% size)[[1L]])
    if (!is.finite(source_bytes) || source_bytes < size) source_bytes <- size

    candidate_path <- tempfile("result-", tmpdir = root)
    con <- file(candidate_path, open = "wb")
    wrote <- FALSE
    tryCatch({
      writeChar(text, con, eos = NULL, useBytes = TRUE)
      wrote <- TRUE
    }, finally = close(con))
    if (!wrote || !file.exists(candidate_path)) {
      unlink(candidate_path, force = TRUE)
      return(NULL)
    }
    Sys.chmod(candidate_path, mode = "0600", use_umask = FALSE)
    candidate_md5 <- unname(tools::md5sum(candidate_path)[[1L]])

    owner_key <- owner_key_for(thread_id, tool_call_id)
    previous_handle <- get0(owner_key, envir = owners, inherits = FALSE)
    if (!is.null(previous_handle) && exists(previous_handle, envir = entries, inherits = FALSE)) {
      previous <- get(previous_handle, envir = entries, inherits = FALSE)
      if (identical(previous$bytes, as.numeric(size)) &&
          identical(previous$source_bytes, source_bytes) &&
          identical(previous$md5, candidate_md5)) {
        unlink(candidate_path, force = TRUE)
        previous <- touch(previous_handle)
        return(descriptor_for(previous_handle, previous))
      }
      remove_handle(previous_handle)
    }

    if (!evict_until_fits(size)) {
      unlink(candidate_path, force = TRUE)
      return(NULL)
    }
    generation <<- generation + 1L
    access_sequence <<- access_sequence + 1
    handle <- basename(candidate_path)
    entry <- list(
      path = candidate_path,
      bytes = as.numeric(size),
      source_bytes = source_bytes,
      md5 = candidate_md5,
      thread_id = thread_id,
      tool_call_id = tool_call_id,
      generation = generation,
      accessed = access_sequence
    )
    assign(handle, entry, envir = entries)
    assign(owner_key, handle, envir = owners)
    descriptor_for(handle, entry)
  }

  valid_utf8_prefix <- function(bytes, limit) {
    if (!length(bytes) || limit <= 0L) return(list(text = "", bytes = 0L))
    end <- min(as.integer(limit), length(bytes))
    lower <- max(1L, end - 3L)
    for (candidate_end in seq.int(end, lower, by = -1L)) {
      candidate <- rawToChar(bytes[seq_len(candidate_end)])
      valid <- iconv(candidate, from = "UTF-8", to = "UTF-8", sub = NA_character_)
      if (length(valid) == 1L && !is.na(valid)) {
        Encoding(candidate) <- "UTF-8"
        return(list(text = candidate, bytes = candidate_end))
      }
    }
    list(text = "", bytes = 0L)
  }

  read_chunk <- function(handle, generation, thread_id, tool_call_id, offset, max_bytes) {
    if (!active || !scalar_string(handle) || !scalar_string(thread_id) ||
        !scalar_string(tool_call_id) || !exists(handle, envir = entries, inherits = FALSE)) {
      return(NULL)
    }
    entry <- get(handle, envir = entries, inherits = FALSE)
    generation <- suppressWarnings(as.integer(generation)[[1L]])
    offset <- suppressWarnings(as.numeric(offset)[[1L]])
    max_bytes <- suppressWarnings(as.integer(max_bytes)[[1L]])
    if (is.na(generation) || generation != entry$generation ||
        !identical(thread_id, entry$thread_id) ||
        !identical(tool_call_id, entry$tool_call_id) ||
        !is.finite(offset) || offset < 0 || offset != floor(offset) || offset > entry$bytes ||
        is.na(max_bytes) || max_bytes < 4L) return(NULL)

    entry <- touch(handle)
    limit <- min(max_bytes, chunk_bytes, 256L * 1024L)
    if (offset == entry$bytes) {
      return(list(text = "", nextOffset = offset, done = TRUE))
    }
    con <- file(entry$path, open = "rb")
    on.exit(close(con), add = TRUE)
    seek(con, where = offset, origin = "start")
    bytes <- readBin(con, what = "raw", n = min(limit, entry$bytes - offset))
    prefix <- valid_utf8_prefix(bytes, limit)
    if (prefix$bytes == 0L) return(NULL)
    next_offset <- offset + prefix$bytes
    list(
      text = prefix$text,
      nextOffset = next_offset,
      done = next_offset >= entry$bytes
    )
  }

  cleanup <- function() {
    active <<- FALSE
    keys <- ls(entries, all.names = TRUE)
    if (length(keys)) rm(list = keys, envir = entries)
    owner_keys <- ls(owners, all.names = TRUE)
    if (length(owner_keys)) rm(list = owner_keys, envir = owners)
    if (dir.exists(root)) unlink(root, recursive = TRUE, force = TRUE)
    invisible(NULL)
  }

  snapshot <- function() {
    keys <- ls(entries, all.names = TRUE)
    stats::setNames(lapply(keys, get, envir = entries, inherits = FALSE), keys)
  }

  limits <- function() {
    list(max_entries = max_entries, max_total_bytes = max_total_bytes)
  }

  list(
    put = put, read_chunk = read_chunk, cleanup = cleanup,
    snapshot = snapshot, limits = limits
  )
}

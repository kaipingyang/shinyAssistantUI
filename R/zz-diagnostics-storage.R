.diagnostics_new_log_re <- "^diag-v1-([0-9]{13})-([0-9a-f]{32})\\.jsonl$"
.diagnostics_legacy_log_re <- paste0(
  "^diagnostics-g_[A-Za-z0-9][A-Za-z0-9_-]{0,63}",
  "-s_[A-Za-z0-9][A-Za-z0-9_-]{0,63}-p([1-9][0-9]{0,9})",
  "-u_[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.jsonl(?:\\.[1-9][0-9]{0,5})?$"
)

.diagnostics_retention_lock_owner <- function(path) {
  parsed <- .read_strict_json_file(file.path(path, "owner.json"), max_bytes = 4096L)
  value <- parsed$value
  if (parsed$classification != "valid" || !is.list(value) ||
      !identical(sort(names(value)), sort(c("pid", "startToken", "createdUtc", "token"))) ||
      is.null(.settings_safe_integer(value$pid, TRUE)) ||
      is.null(.settings_safe_integer(value$createdUtc)) ||
      !.diagnostics_scalar_character(value$startToken) ||
      !.diagnostics_scalar_character(value$token)) return(NULL)
  value
}

.diagnostics_retention_lock_acquire <- function(root, now = Sys.time) {
  root <- normalizePath(path.expand(root), winslash = "/", mustWork = FALSE)
  if (!dir.exists(root) &&
      !dir.create(root, recursive = TRUE, mode = "0700", showWarnings = FALSE)) return(NULL)
  Sys.chmod(root, "0700", use_umask = FALSE)
  root_handle <- .native_fs_open_root(root)
  if (is.null(root_handle)) return(NULL)
  lock_path <- file.path(root, ".retention.lock")
  token <- .diagnostics_hex_token()
  if (is.null(token)) return(NULL)
  acquired <- dir.create(lock_path, mode = "0700", showWarnings = FALSE)
  if (!acquired && dir.exists(lock_path)) {
    owner <- .diagnostics_retention_lock_owner(lock_path)
    info <- tryCatch(file.info(lock_path), error = function(error) NULL)
    created <- if (is.list(owner)) owner$createdUtc else if (!is.null(info) &&
      !is.na(info$mtime[[1L]])) floor(as.numeric(info$mtime[[1L]])) else Inf
    age <- floor(as.numeric(now())) - created
    dead <- if (is.null(owner)) TRUE else {
      current <- .native_process_start_token(owner$pid)
      is.null(current) || !identical(current, owner$startToken)
    }
    if (is.finite(age) && age > 120 && isTRUE(dead)) {
      quarantine <- file.path(root, paste0(".retention.lock.stale-", token))
      if (!file.exists(quarantine) && isTRUE(file.rename(lock_path, quarantine))) {
        unlink(quarantine, recursive = TRUE, force = TRUE)
        acquired <- dir.create(lock_path, mode = "0700", showWarnings = FALSE)
      }
    }
  }
  if (!acquired) return(NULL)
  lock_handle <- .native_fs_open_root(lock_path)
  start <- .native_process_start_token(Sys.getpid())
  owner <- list(pid = Sys.getpid(), startToken = start %||% "unsupported",
                createdUtc = floor(as.numeric(now())), token = token)
  bytes <- charToRaw(paste0(as.character(jsonlite::toJSON(owner, auto_unbox = TRUE)), "\n"))
  status <- if (is.null(lock_handle)) "unsupported" else .native_fs_atomic_write_at(
    lock_handle, paste0(".owner-tmp-", token), "owner.json", bytes
  )
  if (!identical(status, "ok")) {
    unlink(lock_path, recursive = TRUE, force = TRUE); return(NULL)
  }
  list(path = lock_path, root = root, root_handle = root_handle, token = token)
}

.diagnostics_retention_lock_release <- function(lock) {
  if (!is.list(lock) || !dir.exists(lock$path)) return(invisible(FALSE))
  owner <- .diagnostics_retention_lock_owner(lock$path)
  if (!is.list(owner) || !identical(owner$token, lock$token)) return(invisible(FALSE))
  unlink(lock$path, recursive = TRUE, force = TRUE)
  invisible(!dir.exists(lock$path))
}

.diagnostics_metadata_remove <- function(root_handle, basename) {
  identity <- .native_fs_stat_at(root_handle, basename)
  if (is.null(identity)) return(FALSE)
  quarantine <- paste0(".quarantine-", .diagnostics_hex_token())
  identical(.native_fs_remove_at(root_handle, basename, quarantine, identity), "ok")
}

.diagnostics_lease_value <- function(path) {
  parsed <- .read_strict_json_file(path, max_bytes = 4096L)
  value <- parsed$value
  required <- c("version", "basename", "token", "pid", "startToken", "createdUtc")
  if (parsed$classification != "valid" || !is.list(value) ||
      !identical(names(value), required) || !identical(value$version, 1L) ||
      !.diagnostics_scalar_character(value$basename) ||
      !grepl(.diagnostics_new_log_re, value$basename) ||
      !.diagnostics_scalar_character(value$token) ||
      !grepl("^[0-9a-f]{32}$", value$token) ||
      is.null(.settings_safe_integer(value$pid, TRUE)) ||
      !.diagnostics_scalar_character(value$startToken) ||
      is.null(.settings_safe_integer(value$createdUtc))) return(NULL)
  value
}

.diagnostics_closed_value <- function(path) {
  parsed <- .read_strict_json_file(path, max_bytes = 4096L)
  value <- parsed$value
  if (parsed$classification != "valid" || !is.list(value) ||
      !identical(names(value), c("version", "basename", "token", "closedUtc")) ||
      !identical(value$version, 1L) ||
      !.diagnostics_scalar_character(value$basename) ||
      !grepl(.diagnostics_new_log_re, value$basename) ||
      !.diagnostics_scalar_character(value$token) ||
      !grepl("^[0-9a-f]{32}$", value$token) ||
      is.null(.settings_safe_integer(value$closedUtc))) return(NULL)
  value
}

.diagnostics_publish_metadata <- function(root_handle, final, object, token) {
  bytes <- charToRaw(paste0(as.character(jsonlite::toJSON(
    object, auto_unbox = TRUE, null = "null", digits = NA
  )), "\n"))
  .native_fs_atomic_write_at(
    root_handle, paste0(".", final, ".tmp-", token), final, bytes
  )
}

.diagnostics_log_complete <- function(root_handle, basename, size) {
  if (!is.finite(size) || size < 1 || size > 10 * 1024^2) return(FALSE)
  bytes <- .native_fs_read_at(root_handle, basename, size)
  is.raw(bytes) && length(bytes) == size && identical(tail(bytes, 1L), charToRaw("\n"))
}

.diagnostics_storage_recover_locked <- function(lock) {
  root <- lock$root; handle <- lock$root_handle
  names <- list.files(root, all.files = TRUE, no.. = TRUE)
  recovered <- 0L; quarantined <- 0L
  leases <- names[endsWith(names, ".jsonl.lease")]
  for (lease_name in leases) {
    log_name <- sub("\\.lease$", "", lease_name)
    lease <- .diagnostics_lease_value(file.path(root, lease_name))
    if (!file.exists(file.path(root, log_name))) {
      if (.diagnostics_metadata_remove(handle, lease_name)) recovered <- recovered + 1L
      next
    }
    if (is.null(lease) || !identical(lease$basename, log_name)) next
    closed_name <- paste0(log_name, ".closed")
    closed <- if (file.exists(file.path(root, closed_name)))
      .diagnostics_closed_value(file.path(root, closed_name)) else NULL
    if (is.list(closed) && identical(closed$basename, log_name) &&
        identical(closed$token, lease$token)) {
      if (.diagnostics_metadata_remove(handle, lease_name)) recovered <- recovered + 1L
      if (.diagnostics_metadata_remove(handle, closed_name)) recovered <- recovered + 1L
      next
    }
    current <- .native_process_start_token(lease$pid)
    if (is.null(current) || !identical(current, lease$startToken)) {
      if (.diagnostics_metadata_remove(handle, lease_name)) recovered <- recovered + 1L
    }
  }
  names <- list.files(root, all.files = TRUE, no.. = TRUE)
  logs <- names[grepl(.diagnostics_new_log_re, names)]
  for (log_name in logs) {
    if (file.exists(file.path(root, paste0(log_name, ".lease")))) next
    identity <- .native_fs_stat_at(handle, log_name)
    if (is.null(identity) || .diagnostics_log_complete(handle, log_name, identity$size)) next
    quarantine <- paste0(".incomplete-", .diagnostics_hex_token())
    if (identical(.native_fs_remove_at(handle, log_name, quarantine, identity), "ok"))
      quarantined <- quarantined + 1L
  }
  list(category = "ok", recovered = recovered, quarantined = quarantined)
}

.diagnostics_storage_recover <- function(root) {
  lock <- .diagnostics_retention_lock_acquire(root)
  if (is.null(lock)) return(list(category = "busy", recovered = 0L, quarantined = 0L))
  on.exit(.diagnostics_retention_lock_release(lock), add = TRUE)
  .diagnostics_storage_recover_locked(lock)
}

.diagnostics_classify_candidates <- function(lock) {
  root <- lock$root; handle <- lock$root_handle
  names <- list.files(root, all.files = TRUE, no.. = TRUE)
  out <- list()
  for (name in names) {
    kind <- if (grepl(.diagnostics_new_log_re, name)) "new" else if (
      grepl(.diagnostics_legacy_log_re, name)) "legacy" else NULL
    if (is.null(kind)) next
    first <- .native_fs_stat_at(handle, name)
    if (is.null(first) || !isTRUE(first$regular) || first$nlink != 1) next
    active <- FALSE; unsafe <- FALSE
    created <- first$mtime
    pid <- NULL
    if (identical(kind, "new")) {
      created <- as.numeric(sub(.diagnostics_new_log_re, "\\1", name)) / 1000
      lease_name <- paste0(name, ".lease")
      if (file.exists(file.path(root, lease_name))) {
        lease <- .diagnostics_lease_value(file.path(root, lease_name))
        if (is.null(lease) || !identical(lease$basename, name)) unsafe <- TRUE else {
          current <- .native_process_start_token(lease$pid)
          active <- !is.null(current) && identical(current, lease$startToken)
        }
      }
    } else {
      pid <- suppressWarnings(as.integer(sub(.diagnostics_legacy_log_re, "\\1", name)))
      probe1 <- .native_process_probe(pid)
      second <- .native_fs_stat_at(handle, name)
      probe2 <- .native_process_probe(pid)
      fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")
      stable <- !is.null(second) && identical(first[fields], second[fields])
      dead <- identical(probe1$category, "dead") && identical(probe2$category, "dead")
      active <- !dead
      unsafe <- !stable || !dead && (
        identical(probe1$category, "unknown") ||
        identical(probe2$category, "unknown") ||
        !identical(probe1$category, probe2$category) ||
        (identical(probe1$category, "live") && identical(probe2$category, "live") &&
         !identical(probe1$startToken, probe2$startToken))
      )
    }
    out[[length(out) + 1L]] <- list(
      basename = name, size = first$size, created = created,
      identity = first, active = active, unsafe = unsafe, kind = kind,
      pid = pid
    )
  }
  out
}

.diagnostics_retention_pass <- function(root, now = Sys.time(), max_bytes = 50 * 1024^2,
                                        max_age = 7 * 24 * 60 * 60, lock = NULL) {
  result <- list(category = "ok", deleted_count = 0, deleted_bytes = 0,
                 retained_bytes = 0, protected_count = 0)
  own_lock <- is.null(lock)
  if (own_lock) lock <- .diagnostics_retention_lock_acquire(root)
  if (is.null(lock)) { result$category <- "busy"; return(result) }
  if (own_lock) on.exit(.diagnostics_retention_lock_release(lock), add = TRUE)
  .diagnostics_storage_recover_locked(lock)
  candidates <- .diagnostics_classify_candidates(lock)
  now_seconds <- as.numeric(if (is.function(now)) now() else now)
  remove_one <- function(candidate) {
    if (candidate$active || candidate$unsafe) return(FALSE)
    if (identical(candidate$kind, "legacy")) {
      ok <- .diagnostics_revalidate_legacy_delete(lock$root_handle, candidate)
    } else {
      current <- .native_fs_stat_at(lock$root_handle, candidate$basename)
      fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")
      if (is.null(current) || !identical(current[fields], candidate$identity[fields])) return(FALSE)
      quarantine <- paste0(".retention-", .diagnostics_hex_token())
      ok <- identical(.native_fs_remove_at(
        lock$root_handle, candidate$basename, quarantine, candidate$identity
      ), "ok")
    }
    if (ok) {
      result$deleted_count <<- result$deleted_count + 1L
      result$deleted_bytes <<- result$deleted_bytes + candidate$size
    }
    ok
  }
  for (candidate in candidates) {
    if (!candidate$active && !candidate$unsafe && is.finite(candidate$created) &&
        now_seconds - candidate$created > max_age) remove_one(candidate)
  }
  candidates <- .diagnostics_classify_candidates(lock)
  total <- sum(vapply(candidates, `[[`, numeric(1), "size"))
  inactive <- Filter(function(candidate) !candidate$active && !candidate$unsafe, candidates)
  inactive <- inactive[order(vapply(inactive, `[[`, numeric(1), "created"),
                             vapply(inactive, `[[`, character(1), "basename"))]
  for (candidate in inactive) {
    if (total <= max_bytes) break
    if (remove_one(candidate)) total <- total - candidate$size
  }
  remaining <- .diagnostics_classify_candidates(lock)
  result$retained_bytes <- sum(vapply(remaining, `[[`, numeric(1), "size"))
  result$protected_count <- sum(vapply(remaining, function(candidate)
    candidate$active || candidate$unsafe, logical(1)))
  if (result$retained_bytes > max_bytes) result$category <- "partial"
  result
}

.new_diagnostics_storage <- function(config, now = Sys.time) {
  normalized <- config
  root <- normalizePath(path.expand(normalized$directory), winslash = "/", mustWork = FALSE)
  state <- new.env(parent = emptyenv())
  state$active <- FALSE; state$closed <- FALSE; state$category <- "io_error"
  state$file <- NULL; state$basename <- NULL; state$lease <- NULL
  state$closed_name <- NULL; state$token <- NULL; state$bytes <- 0
  state$retention <- NULL
  publish_pair <- function(lock) {
    for (attempt in seq_len(8L)) {
      token <- .diagnostics_hex_token(); if (is.null(token)) return(FALSE)
      epoch <- floor(as.numeric(now()) * 1000)
      basename <- sprintf("diag-v1-%013.0f-%s.jsonl", epoch, token)
      temporary <- paste0(".", basename, ".tmp-", token)
      file <- .native_fs_create_at(lock$root_handle, temporary, basename)
      if (is.null(file)) next
      lease_name <- paste0(basename, ".lease")
      lease <- list(
        version = 1L, basename = basename, token = token,
        pid = Sys.getpid(), startToken = .native_process_start_token(Sys.getpid()) %||% "unsupported",
        createdUtc = floor(as.numeric(now()))
      )
      status <- .diagnostics_publish_metadata(lock$root_handle, lease_name, lease, token)
      if (!identical(status, "ok")) { .native_file_close(file); next }
      identity <- .native_fs_stat_at(lock$root_handle, basename)
      lease_identity <- .native_fs_stat_at(lock$root_handle, lease_name)
      if (is.null(identity) || is.null(lease_identity)) { .native_file_close(file); next }
      state$file <- file; state$basename <- basename; state$lease <- lease_name
      state$closed_name <- paste0(basename, ".closed"); state$token <- token
      state$bytes <- 0; state$active <- TRUE; state$category <- "ok"
      return(TRUE)
    }
    FALSE
  }
  lock <- .diagnostics_retention_lock_acquire(root)
  if (!is.null(lock)) {
    .diagnostics_storage_recover_locked(lock)
    state$retention <- .diagnostics_retention_pass(
      root, now = now, max_bytes = normalized$retention_max_bytes,
      max_age = normalized$retention_seconds, lock = lock
    )
    publish_pair(lock)
    .diagnostics_retention_lock_release(lock)
  } else state$category <- "busy"
  write_bytes <- function(bytes) {
    if (!state$active || state$closed || !is.raw(bytes)) return(FALSE)
    ok <- .native_file_write(state$file, bytes, sync = FALSE)
    if (ok) state$bytes <- state$bytes + length(bytes) else state$category <- "io_error"
    ok
  }
  publish_closed <- function(lock = NULL) {
    handle <- if (is.null(lock)) .native_fs_open_root(root) else lock$root_handle
    if (is.null(handle)) return(FALSE)
    marker <- list(version = 1L, basename = state$basename, token = state$token,
                   closedUtc = floor(as.numeric(now())))
    identical(.diagnostics_publish_metadata(
      handle, state$closed_name, marker, state$token
    ), "ok") || file.exists(file.path(root, state$closed_name))
  }
  rotate <- function() {
    if (!state$active || state$closed) return(FALSE)
    lock <- .diagnostics_retention_lock_acquire(root)
    if (is.null(lock)) return(FALSE)
    on.exit(.diagnostics_retention_lock_release(lock), add = TRUE)
    .diagnostics_storage_recover_locked(lock)
    state$retention <- .diagnostics_retention_pass(
      root, now = now, max_bytes = normalized$retention_max_bytes,
      max_age = normalized$retention_seconds, lock = lock
    )
    old <- list(file = state$file, basename = state$basename, lease = state$lease,
                closed = state$closed_name, token = state$token)
    state$active <- FALSE
    if (!publish_pair(lock)) {
      state$file <- old$file; state$basename <- old$basename; state$lease <- old$lease
      state$closed_name <- old$closed; state$token <- old$token; state$active <- TRUE
      return(FALSE)
    }
    if (!.native_file_sync(old$file)) state$category <- "io_error"
    .native_file_close(old$file)
    old_marker <- list(version = 1L, basename = old$basename, token = old$token,
                       closedUtc = floor(as.numeric(now())))
    .diagnostics_publish_metadata(lock$root_handle, old$closed, old_marker, old$token)
    .diagnostics_metadata_remove(lock$root_handle, old$lease)
    TRUE
  }
  close_storage <- function() {
    if (state$closed) return(FALSE)
    if (!is.null(state$file)) {
      if (!.native_file_sync(state$file)) state$category <- "io_error"
      .native_file_close(state$file)
    }
    state$file <- NULL; state$active <- FALSE
    lock <- .diagnostics_retention_lock_acquire(root)
    if (is.null(lock)) {
      publish_closed(NULL)
    } else {
      publish_closed(lock)
      .diagnostics_metadata_remove(lock$root_handle, state$lease)
      state$retention <- .diagnostics_retention_pass(
        root, now = now, max_bytes = normalized$retention_max_bytes,
        max_age = normalized$retention_seconds, lock = lock
      )
      .diagnostics_retention_lock_release(lock)
    }
    state$closed <- TRUE
    TRUE
  }
  snapshot <- function() list(
    category = state$category, active = state$active, closed = state$closed,
    basename = state$basename, lease_basename = state$lease,
    closed_basename = state$closed_name, bytes = state$bytes,
    retention = state$retention
  )
  list(write = write_bytes, rotate = rotate, close = close_storage, snapshot = snapshot)
}


.diagnostics_revalidate_legacy_delete <- function(
    root_handle, candidate, stat = .native_fs_stat_at,
    probe = .native_process_probe, remove = .native_fs_remove_at,
    token = .diagnostics_hex_token) {
  if (!is.list(candidate) || !identical(candidate$kind, "legacy") ||
      is.null(.settings_safe_integer(candidate$pid, TRUE))) return(FALSE)
  fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")
  first <- tryCatch(stat(root_handle, candidate$basename), error = function(error) NULL)
  probe1 <- tryCatch(probe(candidate$pid), error = function(error)
    list(category = "unknown", startToken = NULL))
  second <- tryCatch(stat(root_handle, candidate$basename), error = function(error) NULL)
  probe2 <- tryCatch(probe(candidate$pid), error = function(error)
    list(category = "unknown", startToken = NULL))
  stable <- !is.null(first) && !is.null(second) &&
    identical(first[fields], candidate$identity[fields]) &&
    identical(second[fields], candidate$identity[fields]) &&
    identical(first[fields], second[fields])
  explicitly_dead <- is.list(probe1) && is.list(probe2) &&
    identical(probe1$category, "dead") && identical(probe2$category, "dead")
  if (!stable || !explicitly_dead) return(FALSE)
  quarantine_token <- tryCatch(token(), error = function(error) NULL)
  if (!.diagnostics_scalar_character(quarantine_token)) return(FALSE)
  identical(tryCatch(remove(
    root_handle, candidate$basename,
    paste0(".retention-", quarantine_token), second
  ), error = function(error) "io_error"), "ok")
}

.native_call <- function(name, ...) {
  tryCatch(.Call(name, ..., PACKAGE = "shinyAssistantUI"), error = function(error) NULL)
}

.native_secure_capabilities <- function() {
  value <- .native_call("saui_native_capabilities")
  if (!is.list(value) || !identical(names(value), c(
    "version", "platform", "secureFs", "unixDatagram", "parentDeath", "noReplace"
  ))) {
    return(list(version = 1L, platform = "unsupported", secureFs = FALSE,
                unixDatagram = FALSE, parentDeath = FALSE, noReplace = FALSE))
  }
  value
}

.native_fs_open_root <- function(path) .native_call("saui_fs_open_root", as.character(path)[[1L]])
.native_fs_stat_at <- function(root, basename) .native_call(
  "saui_fs_stat_at", root, as.character(basename)[[1L]]
)
.native_fs_atomic_write_at <- function(root, temporary, final, bytes) {
  if (!is.raw(bytes)) bytes <- charToRaw(as.character(bytes)[[1L]])
  .native_call("saui_fs_atomic_write_at", root, temporary, final, bytes) %||% "unsupported"
}
.native_fs_remove_at <- function(root, basename, quarantine, identity) {
  if (!is.list(identity) || is.null(identity$dev) || is.null(identity$ino)) return("invalid")
  .native_call("saui_fs_remove_at", root, basename, quarantine,
               as.numeric(identity$dev), as.numeric(identity$ino)) %||% "unsupported"
}
.native_fs_fsync_root <- function(root) isTRUE(.native_call("saui_fs_fsync_root", root))
.native_dgram_open <- function(path) .native_call("saui_dgram_open", as.character(path)[[1L]])
.native_dgram_send <- function(path, bytes) {
  if (!is.raw(bytes)) return(list(ok = FALSE, category = "invalid", bytes = 0L))
  .native_call("saui_dgram_send", as.character(path)[[1L]], bytes) %||%
    list(ok = FALSE, category = "unsupported", bytes = 0L)
}
.native_dgram_recv <- function(handle, max_bytes = 32768L) {
  .native_call("saui_dgram_recv", handle, as.integer(max_bytes))
}
.native_parent_guard_bootstrap <- function(parent_pid, parent_start_token) {
  isTRUE(.native_call("saui_parent_guard_bootstrap", as.integer(parent_pid),
                      as.character(parent_start_token)[[1L]]))
}
.native_process_start_token <- function(pid = Sys.getpid()) {
  .native_call("saui_process_start_token", as.integer(pid))
}
.native_terminate_process <- function(pid, start_token, timeout_ms = 500L) {
  .native_call("saui_terminate_process", as.integer(pid),
               as.character(start_token)[[1L]], as.integer(timeout_ms)) %||%
    "unsupported"
}
.native_monotonic_ns <- function() {
  value <- .native_call("saui_monotonic_ns")
  if (!is.numeric(value) || length(value) != 1L || !is.finite(value)) NA_real_
  else as.numeric(value)
}
.native_dgram_client <- function(path) {
  .native_call("saui_dgram_client", as.character(path)[[1L]])
}
.native_dgram_send_handle <- function(handle, bytes) {
  if (!is.raw(bytes)) return(list(ok = FALSE, category = "invalid", bytes = 0L))
  .native_call("saui_dgram_send_handle", handle, bytes) %||%
    list(ok = FALSE, category = "unsupported", bytes = 0L)
}
.native_encode_validated_rows <- function(rows) {
  value <- .native_call("saui_encode_validated_rows", rows)
  if (!is.character(value) || length(value) != length(rows) || anyNA(value)) NULL
  else value
}
.native_fs_create_at <- function(root, temporary, final) {
  .native_call("saui_fs_create_at", root, temporary, final)
}
.native_fs_open_append_at <- function(root, basename) {
  .native_call("saui_fs_open_append_at", root, basename)
}
.native_file_write <- function(handle, bytes, sync = TRUE) {
  is.raw(bytes) && isTRUE(.native_call("saui_file_write", handle, bytes, isTRUE(sync)))
}
.native_file_close <- function(handle) isTRUE(.native_call("saui_file_close", handle))
.native_fs_read_at <- function(root, basename, max_bytes) {
  .native_call("saui_fs_read_at", root, basename, as.numeric(max_bytes))
}
.native_fs_atomic_replace_at <- function(root, temporary, final, bytes) {
  if (!is.raw(bytes)) bytes <- charToRaw(as.character(bytes)[[1L]])
  .native_call("saui_fs_atomic_replace_at", root, temporary, final, bytes) %||%
    "unsupported"
}
.native_fs_open_read_at <- function(root, basename) {
  .native_call("saui_fs_open_read_at", root, basename)
}
.native_file_read_all <- function(handle, max_bytes) {
  .native_call("saui_file_read_all", handle, as.numeric(max_bytes))
}
.native_crc32 <- function(bytes) {
  value <- if (is.raw(bytes)) .native_call("saui_crc32", bytes) else NULL
  if (!is.numeric(value) || length(value) != 1L || !is.finite(value)) NULL
  else as.numeric(value)
}
.native_verify_store_zip <- function(bytes) {
  is.raw(bytes) && isTRUE(.native_call("saui_verify_store_zip", bytes))
}
.native_set_subreaper <- function() isTRUE(.native_call("saui_set_subreaper"))
.native_reap_children <- function(timeout_ms = 1000L) {
  value <- .native_call("saui_reap_children", as.integer(timeout_ms))
  if (is.null(value)) -1L else as.integer(value)
}
.native_file_sync <- function(handle) isTRUE(.native_call("saui_file_sync", handle))

.native_file_stat <- function(handle) .native_call("saui_file_stat", handle)
.native_process_probe <- function(pid) {
  value <- .native_call("saui_process_probe", as.integer(pid))
  if (!is.list(value) || !identical(names(value), c("category", "startToken")) ||
      !value$category %in% c("live", "dead", "unknown") ||
      (identical(value$category, "live") && !.diagnostics_scalar_character(value$startToken))) {
    return(list(category = "unknown", startToken = NULL))
  }
  value
}
.native_fs_quarantine_at <- function(root, basename, quarantine, identity) {
  if (!is.list(identity) || is.null(identity$dev) || is.null(identity$ino)) return("invalid")
  .native_call("saui_fs_quarantine_at", root, basename, quarantine,
               as.numeric(identity$dev), as.numeric(identity$ino)) %||% "unsupported"
}
.native_sha256 <- function(bytes) {
  value <- if (is.raw(bytes)) .native_call("saui_sha256", bytes) else NULL
  if (!.diagnostics_scalar_character(value) || !grepl("^[0-9a-f]{64}$", value)) NULL else value
}
.native_store_zip_entries <- function(bytes) {
  value <- if (is.raw(bytes)) .native_call("saui_store_zip_entries", bytes) else NULL
  if (!is.list(value) || is.null(names(value)) || anyDuplicated(names(value)) ||
      any(!vapply(value, is.raw, logical(1)))) NULL else value
}

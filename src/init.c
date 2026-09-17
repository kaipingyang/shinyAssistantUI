#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

extern SEXP saui_native_capabilities(void);
extern SEXP saui_fs_open_root(SEXP);
extern SEXP saui_fs_stat_at(SEXP,SEXP);
extern SEXP saui_fs_atomic_write_at(SEXP,SEXP,SEXP,SEXP);
extern SEXP saui_fs_remove_at(SEXP,SEXP,SEXP,SEXP,SEXP);
extern SEXP saui_fs_fsync_root(SEXP);
extern SEXP saui_dgram_open(SEXP);
extern SEXP saui_dgram_send(SEXP,SEXP);
extern SEXP saui_dgram_client(SEXP);
extern SEXP saui_dgram_send_handle(SEXP,SEXP);
extern SEXP saui_dgram_recv(SEXP,SEXP);
extern SEXP saui_parent_guard_bootstrap(SEXP,SEXP);
extern SEXP saui_process_start_token(SEXP);
extern SEXP saui_terminate_process(SEXP,SEXP,SEXP);
extern SEXP saui_monotonic_ns(void);
extern SEXP saui_encode_validated_rows(SEXP);
extern SEXP saui_fs_create_at(SEXP,SEXP,SEXP);
extern SEXP saui_fs_open_append_at(SEXP,SEXP);
extern SEXP saui_file_write(SEXP,SEXP,SEXP);
extern SEXP saui_file_close(SEXP);
extern SEXP saui_fs_read_at(SEXP,SEXP,SEXP);
extern SEXP saui_fs_atomic_replace_at(SEXP,SEXP,SEXP,SEXP);
extern SEXP saui_fs_open_read_at(SEXP,SEXP);
extern SEXP saui_file_read_all(SEXP,SEXP);
extern SEXP saui_crc32(SEXP);
extern SEXP saui_verify_store_zip(SEXP);
extern SEXP saui_set_subreaper(void);
extern SEXP saui_reap_children(SEXP);
extern SEXP saui_file_sync(SEXP);
extern SEXP saui_file_stat(SEXP);
extern SEXP saui_process_probe(SEXP);
extern SEXP saui_fs_quarantine_at(SEXP,SEXP,SEXP,SEXP,SEXP);
extern SEXP saui_sha256(SEXP);
extern SEXP saui_store_zip_entries(SEXP);

static const R_CallMethodDef CallEntries[] = {
  {"saui_native_capabilities", (DL_FUNC)&saui_native_capabilities, 0},
  {"saui_fs_open_root", (DL_FUNC)&saui_fs_open_root, 1},
  {"saui_fs_stat_at", (DL_FUNC)&saui_fs_stat_at, 2},
  {"saui_fs_atomic_write_at", (DL_FUNC)&saui_fs_atomic_write_at, 4},
  {"saui_fs_remove_at", (DL_FUNC)&saui_fs_remove_at, 5},
  {"saui_fs_fsync_root", (DL_FUNC)&saui_fs_fsync_root, 1},
  {"saui_dgram_open", (DL_FUNC)&saui_dgram_open, 1},
  {"saui_dgram_send", (DL_FUNC)&saui_dgram_send, 2},
  {"saui_dgram_client", (DL_FUNC)&saui_dgram_client, 1},
  {"saui_dgram_send_handle", (DL_FUNC)&saui_dgram_send_handle, 2},
  {"saui_dgram_recv", (DL_FUNC)&saui_dgram_recv, 2},
  {"saui_parent_guard_bootstrap", (DL_FUNC)&saui_parent_guard_bootstrap, 2},
  {"saui_process_start_token", (DL_FUNC)&saui_process_start_token, 1},
  {"saui_terminate_process", (DL_FUNC)&saui_terminate_process, 3},
  {"saui_monotonic_ns", (DL_FUNC)&saui_monotonic_ns, 0},
  {"saui_encode_validated_rows", (DL_FUNC)&saui_encode_validated_rows, 1},
  {"saui_fs_create_at", (DL_FUNC)&saui_fs_create_at, 3},
  {"saui_fs_open_append_at", (DL_FUNC)&saui_fs_open_append_at, 2},
  {"saui_file_write", (DL_FUNC)&saui_file_write, 3},
  {"saui_file_close", (DL_FUNC)&saui_file_close, 1},
  {"saui_fs_read_at", (DL_FUNC)&saui_fs_read_at, 3},
  {"saui_fs_atomic_replace_at", (DL_FUNC)&saui_fs_atomic_replace_at, 4},
  {"saui_fs_open_read_at", (DL_FUNC)&saui_fs_open_read_at, 2},
  {"saui_file_read_all", (DL_FUNC)&saui_file_read_all, 2},
  {"saui_crc32", (DL_FUNC)&saui_crc32, 1},
  {"saui_verify_store_zip", (DL_FUNC)&saui_verify_store_zip, 1},
  {"saui_set_subreaper", (DL_FUNC)&saui_set_subreaper, 0},
  {"saui_reap_children", (DL_FUNC)&saui_reap_children, 1},
  {"saui_file_sync", (DL_FUNC)&saui_file_sync, 1},
  {"saui_file_stat", (DL_FUNC)&saui_file_stat, 1},
  {"saui_process_probe", (DL_FUNC)&saui_process_probe, 1},
  {"saui_fs_quarantine_at", (DL_FUNC)&saui_fs_quarantine_at, 5},
  {"saui_sha256", (DL_FUNC)&saui_sha256, 1},
  {"saui_store_zip_entries", (DL_FUNC)&saui_store_zip_entries, 1},
  {NULL, NULL, 0}
};

void R_init_shinyAssistantUI(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  R_forceSymbols(dll, FALSE);
}

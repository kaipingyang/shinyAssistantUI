# Isolated full-GC pause benchmark.
# Usage: Rscript benchmark_gc_pause.R <total_mib> <repetitions> <csv_path> [large|dense]
args <- commandArgs(trailingOnly = TRUE)
if (!length(args) %in% c(3L, 4L)) {
  stop("Expected: <total_mib> <repetitions> <csv_path> [large|dense]")
}
total_mib <- as.integer(args[[1L]])
repetitions <- as.integer(args[[2L]])
out_path <- args[[3L]]
shape <- if (length(args) == 4L) args[[4L]] else "large"
stopifnot(total_mib >= 16L, repetitions >= 1L, shape %in% c("large", "dense"))

rss_kb <- function() {
  line <- grep("^VmRSS:", readLines("/proc/self/status", warn = FALSE), value = TRUE)
  as.numeric(gsub("[^0-9]", "", line))
}

allocate_bytes <- function(bytes, salt) {
  if (identical(shape, "dense")) {
    values_per_object <- 256L
    payload_per_object <- values_per_object * 4L
    count <- as.integer(ceiling(bytes / payload_per_object))
    objects <- vector("list", count)
    remaining <- bytes
    for (index in seq_len(count)) {
      size <- as.integer(min(values_per_object, ceiling(remaining / 4)))
      objects[[index]] <- rep.int(as.integer(index + salt), size)
      remaining <- max(0, remaining - size * 4)
    }
    return(objects)
  }

  chunk_bytes <- 8L * 1024L * 1024L
  count <- as.integer(ceiling(bytes / chunk_bytes))
  chunks <- vector("list", count)
  remaining <- bytes
  for (index in seq_len(count)) {
    size <- as.integer(min(chunk_bytes, remaining))
    value <- as.raw(((index + salt) %% 251L) + 1L)
    chunks[[index]] <- rep.int(value, size)
    remaining <- remaining - size
  }
  chunks
}

bytes_total <- as.numeric(total_mib) * 1024^2
bytes_live <- floor(bytes_total / 2)
bytes_garbage <- bytes_total - bytes_live
invisible(gc(full = TRUE))
baseline_rss_kb <- rss_kb()
live <- allocate_bytes(bytes_live, 0L)
live_rss_kb <- rss_kb()

rows <- vector("list", repetitions)
for (iteration in seq_len(repetitions)) {
  garbage <- allocate_bytes(bytes_garbage, iteration * 17L)
  before_gc_rss_kb <- rss_kb()
  garbage <- NULL
  timing <- system.time(invisible(gc(full = TRUE)))
  after_gc_rss_kb <- rss_kb()
  Sys.sleep(0.25)
  settled_rss_kb <- rss_kb()
  rows[[iteration]] <- data.frame(
    total_mib = total_mib,
    live_mib = bytes_live / 1024^2,
    garbage_mib = bytes_garbage / 1024^2,
    iteration = iteration,
    baseline_rss_kb = baseline_rss_kb,
    live_rss_kb = live_rss_kb,
    before_gc_rss_kb = before_gc_rss_kb,
    after_gc_rss_kb = after_gc_rss_kb,
    settled_rss_kb = settled_rss_kb,
    gc_user_s = unname(timing[["user.self"]]),
    gc_system_s = unname(timing[["sys.self"]]),
    gc_elapsed_s = unname(timing[["elapsed"]])
  )
  cat(sprintf(
    "heap=%dMiB iteration=%d pause=%.4fs rss_before=%.1fMiB rss_after=%.1fMiB\n",
    total_mib, iteration, timing[["elapsed"]],
    before_gc_rss_kb / 1024, after_gc_rss_kb / 1024
  ))
}

result <- do.call(rbind, rows)
write.table(
  result,
  file = out_path,
  sep = ",",
  row.names = FALSE,
  col.names = !file.exists(out_path),
  append = file.exists(out_path),
  quote = FALSE
)

live <- NULL
invisible(gc(full = TRUE))

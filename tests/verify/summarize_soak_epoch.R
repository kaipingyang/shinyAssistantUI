# Summarize one 10-minute epoch from soak metrics.
# Usage: Rscript summarize_soak_epoch.R <metrics.csv> <epoch>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Expected: <metrics.csv> <epoch>")
path <- args[[1L]]
epoch <- as.integer(args[[2L]])
x <- read.csv(path, stringsAsFactors = FALSE)
x <- x[x$epoch == epoch, , drop = FALSE]
if (nrow(x) < 2L) stop("Epoch has fewer than two samples: ", epoch)

slope_per_hour <- function(value) {
  good <- is.finite(value) & is.finite(x$elapsed_s)
  if (sum(good) < 2L) return(NA_real_)
  unname(stats::coef(stats::lm(value[good] ~ x$elapsed_s[good]))[[2L]]) * 3600
}
first <- x[1L, , drop = FALSE]
last <- x[nrow(x), , drop = FALSE]
gc_delta <- last$gc_count - first$gc_count
tool_delta <- last$tool_events - first$tool_events
original_delta <- last$original_bytes_total - first$original_bytes_total
preview_delta <- last$preview_bytes_total - first$preview_bytes_total
cat(sprintf(
  paste0(
    "epoch=%d samples=%d elapsed=%.1f-%.1fs ",
    "rss=%.1f->%.1fMiB min=%.1f max=%.1f slope=%+.2fMiB/h ",
    "pss=%.1f->%.1fMiB slope=%+.2fMiB/h ",
    "claude_count=%d->%d claude_rss=%.1f->%.1fMiB max_child=%.1fMiB ",
    "tools=%d original=%.1fMiB preview=%.1fMiB gc=%d gc_max=%.4fs ",
    "cgroup=%.1f->%.1fMiB\n"
  ),
  epoch, nrow(x), min(x$elapsed_s), max(x$elapsed_s),
  first$rss_kb / 1024, last$rss_kb / 1024,
  min(x$rss_kb) / 1024, max(x$rss_kb) / 1024,
  slope_per_hour(x$rss_kb) / 1024,
  first$pss_kb / 1024, last$pss_kb / 1024,
  slope_per_hour(x$pss_kb) / 1024,
  first$claude_count, last$claude_count,
  first$claude_rss_kb / 1024, last$claude_rss_kb / 1024,
  max(x$claude_max_rss_kb) / 1024,
  tool_delta, original_delta / 1024^2, preview_delta / 1024^2,
  gc_delta, max(x$gc_max_s),
  first$cgroup_current / 1024^2, last$cgroup_current / 1024^2
))

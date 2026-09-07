#!/usr/bin/env Rscript

# Build the public pkgdown site without installing the package. pkgdown renders
# every top-level Markdown file by default, so remove repository-maintenance
# pages from the generated public site and its indexes after each build.

config <- yaml::read_yaml("_pkgdown.yml")
site <- config$destination
if (!identical(site, "docs")) {
  stop("Refusing to clean an unexpected pkgdown destination: ", site)
}

if (dir.exists(site)) {
  unlink(site, recursive = TRUE)
}

pkgdown::build_site(
  ".",
  devel = FALSE,
  new_process = FALSE,
  install = FALSE,
  preview = FALSE,
  quiet = FALSE
)

private_sources <- c(
  "AGENTS.md",
  "CLAUDE.md",
  list.files(pattern = "^CODE_REVIEW.*\\.md$")
)
private_sources <- private_sources[file.exists(private_sources)]
private_pages <- paste0(tools::file_path_sans_ext(basename(private_sources)), ".html")
private_outputs <- c(private_pages, basename(private_sources))

unlink(file.path(site, private_outputs))

search_path <- file.path(site, "search.json")
search <- jsonlite::read_json(search_path, simplifyVector = FALSE)
is_private_record <- function(record) {
  path <- record$path
  is.character(path) && length(path) == 1L &&
    any(endsWith(path, paste0("/", private_pages)))
}
search <- search[!vapply(search, is_private_record, logical(1))]
jsonlite::write_json(search, search_path, auto_unbox = TRUE)

sitemap_path <- file.path(site, "sitemap.xml")
sitemap <- readLines(sitemap_path, warn = FALSE)
for (page in private_pages) {
  sitemap <- sitemap[!grepl(paste0("/", page, "</loc>"), sitemap, fixed = TRUE)]
}
writeLines(sitemap, sitemap_path, useBytes = TRUE)

stopifnot(
  !dir.exists(file.path(site, "dev")),
  !any(file.exists(file.path(site, private_outputs))),
  !any(vapply(search, is_private_record, logical(1))),
  !any(vapply(private_pages, function(page) {
    any(grepl(paste0("/", page, "</loc>"), sitemap, fixed = TRUE))
  }, logical(1)))
)

cat(
  "Built public pkgdown site in docs/; excluded maintenance outputs: ",
  paste(private_outputs, collapse = ", "),
  "\n",
  sep = ""
)

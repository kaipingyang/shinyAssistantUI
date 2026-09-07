#!/usr/bin/env Rscript

# Build the public pkgdown site from an allowlisted source mirror. pkgdown renders
# every top-level Markdown file by default, so building directly from the working
# tree would read repository-maintenance or diagnostic files before their generated
# pages could be deleted. The mirror prevents those files from entering pkgdown at all.

config <- yaml::read_yaml("_pkgdown.yml")
site <- config$destination
if (!identical(site, "docs")) {
  stop("Refusing to replace an unexpected pkgdown destination: ", site)
}

public_inputs <- c(
  "DESCRIPTION",
  "NAMESPACE",
  "LICENSE",
  "LICENSE.md",
  "README.md",
  "NEWS.md",
  "_pkgdown.yml",
  "R",
  "inst",
  "man",
  "vignettes"
)
missing_inputs <- public_inputs[!file.exists(public_inputs) & !dir.exists(public_inputs)]
if (length(missing_inputs)) {
  stop("Missing pkgdown public input(s): ", paste(missing_inputs, collapse = ", "))
}

build_root <- tempfile("shinyAssistantUI-pkgdown-source-")
dir.create(build_root)
on.exit(unlink(build_root, recursive = TRUE, force = TRUE), add = TRUE)

copied <- file.copy(
  public_inputs,
  build_root,
  recursive = TRUE,
  copy.mode = TRUE,
  copy.date = TRUE
)
if (!all(copied)) {
  stop("Failed to create the allowlisted pkgdown source mirror: ",
       paste(public_inputs[!copied], collapse = ", "))
}

pkgdown::build_site(
  build_root,
  devel = FALSE,
  new_process = FALSE,
  install = FALSE,
  preview = FALSE,
  quiet = FALSE
)

built_site <- file.path(build_root, site)
search_path <- file.path(built_site, "search.json")
sitemap_path <- file.path(built_site, "sitemap.xml")
if (!dir.exists(built_site) || !file.exists(search_path) || !file.exists(sitemap_path)) {
  stop("pkgdown did not produce a complete temporary site")
}

private_pages <- c("AGENTS.html", "CLAUDE.html")
private_path_pattern <- "/(AGENTS|CLAUDE|CODE_REVIEW[^/]*)\\.html$"
search <- jsonlite::read_json(search_path, simplifyVector = FALSE)
is_private_record <- function(record) {
  path <- record$path
  is.character(path) && length(path) == 1L && grepl(private_path_pattern, path)
}
sitemap <- readLines(sitemap_path, warn = FALSE)
stopifnot(
  !dir.exists(file.path(built_site, "dev")),
  !any(file.exists(file.path(built_site, private_pages))),
  !any(grepl("^CODE_REVIEW.*\\.html$", list.files(built_site))),
  !any(vapply(search, is_private_record, logical(1))),
  !any(grepl("/(AGENTS|CLAUDE|CODE_REVIEW[^/]*)\\.html</loc>", sitemap))
)

if (dir.exists(site)) unlink(site, recursive = TRUE)
if (!file.copy(built_site, ".", recursive = TRUE, copy.mode = TRUE, copy.date = TRUE)) {
  stop("Failed to publish the temporary pkgdown site to docs/")
}

cat(
  "Built public pkgdown site in docs/ from allowlisted source inputs; ",
  "repository-maintenance and diagnostic files were never passed to pkgdown.\n",
  sep = ""
)

# output$chat is the OutputBinding render value list(inputId, config). In some
# environments htmlwidgets' output serialization turns it into a JSON string of
# shape {x: {config}}. Normalize to the config list regardless of shape so the
# config-shape tests pass under both R CMD check (no htmlwidgets) and load_all.
widget_config <- function(chat) {
  w <- if (is.character(chat)) jsonlite::fromJSON(chat, simplifyVector = FALSE) else chat
  if (!is.null(w$config)) w$config else w$x$config
}

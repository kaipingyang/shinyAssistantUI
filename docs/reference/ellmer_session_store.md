# SQLite-backed session store for ellmer chats

Creates a session store backed by a SQLite database. Supports saving,
listing, loading, and deleting per-thread chat state. Designed to be
shared across Shiny sessions (app-level singleton).

## Usage

``` r
ellmer_session_store(db_path)
```

## Arguments

  - db\_path:
    
    Path to the SQLite database file. Parent directory is created
    automatically.

## Value

A list with `save`, `list_sessions`, `load`, and `delete` functions.

## Examples

``` r
if (FALSE) { # \dontrun{
store <- ellmer_session_store(".sessions/chat.db")

handler <- make_ellmer_handler(
  chat  = function() chat_openai_compatible(...),
  store = store
)
} # }
```

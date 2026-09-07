# Declare how a tool call's arguments are rendered in the chat card

Builds the `argsView` tool-call annotation that tells the widget how to
render a tool call's **arguments** (the region an approver reads),
instead of the raw JSON fallback. This is the server-side (R) extension
point for tools whose semantics only the author knows — primarily
`ellmer::tool()` tools (whose `annotations` are forwarded automatically
by `make_ellmer_handler()`) and any custom `handler` that emits
`on_tool_call(annotations = ...)`.

## Usage

``` r
assistant_tool_view(
  kind = c("code", "diff"),
  field = NULL,
  lang = NULL,
  old_field = NULL,
  new_field = NULL,
  file_field = NULL
)
```

## Arguments

  - kind:
    
    The view kind: `"code"` (syntax-highlighted code block) or `"diff"`
    (old/new unified diff).

  - field:
    
    For `kind = "code"`: the argument name holding the code string.
    Defaults to `"code"` on the client when omitted.

  - lang:
    
    For `kind = "code"`: the syntax-highlighting language (e.g. `"r"`,
    `"sql"`, `"bash"`, `"python"`). Falls back to a neutral language
    when omitted.

  - old\_field, new\_field, file\_field:
    
    For `kind = "diff"`: the argument names holding the old text, new
    text, and file name. Default to `"old_string"`, `"new_string"`, and
    `"file_path"` on the client when omitted.

## Value

A named list `list(argsView = <spec>)` suitable for a tool call's
`annotations`.

## Details

Claude Code's fixed built-in tools (`Bash`, `Edit`, `Write`, `run_r`,
...) are rendered by built-in rules on the client and do **not** need
this.

The return value is a plain list; merge it into a tool call's
annotations, e.g. `on_tool_call(id, name, args, annotations =
assistant_tool_view("code", field = "code", lang = "r"))`, or
`c(other_annotations, assistant_tool_view(...))`.

## Examples

``` r
# Render a tool's `code` argument as an R code block:
assistant_tool_view("code", field = "code", lang = "r")
#> $argsView
#> $argsView$kind
#> [1] "code"
#> 
#> $argsView$field
#> [1] "code"
#> 
#> $argsView$lang
#> [1] "r"
#> 
#> 

# A SQL tool whose query lives in the `sql` argument:
assistant_tool_view("code", field = "sql", lang = "sql")
#> $argsView
#> $argsView$kind
#> [1] "code"
#> 
#> $argsView$field
#> [1] "sql"
#> 
#> $argsView$lang
#> [1] "sql"
#> 
#> 

# A custom edit-style tool rendered as a diff:
assistant_tool_view("diff", old_field = "before", new_field = "after")
#> $argsView
#> $argsView$kind
#> [1] "diff"
#> 
#> $argsView$oldField
#> [1] "before"
#> 
#> $argsView$newField
#> [1] "after"
#> 
#> 

if (FALSE) { # \dontrun{
# With ellmer: declare the view in the tool's annotations (forwarded to the card).
ellmer::tool(
  run_sql,
  description = "Run a SQL query",
  arguments   = list(sql = ellmer::type_string("SQL to run")),
  annotations = assistant_tool_view("code", field = "sql", lang = "sql")
)
} # }
```

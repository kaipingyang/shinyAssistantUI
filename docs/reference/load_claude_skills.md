# Load Claude Code skills as slash commands

Discovers user-invocable Claude Code skills and legacy custom commands
for the slash menu. The loader intentionally scans only direct entries
in the personal and project configuration roots:

## Usage

``` r
load_claude_skills(project_dir = getwd(), include_plugins = TRUE)
```

## Arguments

  - project\_dir:
    
    Path to the project root. Defaults to `getwd()`.

  - include\_plugins:
    
    Retained for API compatibility. Plugin marketplace caches are never
    scanned directly; active plugin commands come from the connected
    Claude Code process.

## Value

A list of command definitions with `name`, `description`, `prompt`,
`category`, `source`, and `kind` fields.

## Details

  - `~/.claude/skills/<skill-name>/SKILL.md`

  - `~/.claude/commands/<command-name>.md`

  - `<project_dir>/.claude/skills/<skill-name>/SKILL.md`

  - `<project_dir>/.claude/commands/<command-name>.md`

This mirrors Claude Code's base-session discovery without recursively
flattening repositories or plugin copies embedded inside a skill
directory. Claude Code discovers nested project `.claude/skills/`
directories on demand and advertises those (with directory-qualified
names) through Agent SDK server info.

Official precedence is applied: within one scope, a skill overrides a
legacy command of the same name; personal entries override project
entries. Plugin skills are not read from the marketplace cache because
that cache includes disabled and duplicate plugins and requires
namespacing. Active plugin and bundled skills are supplied by Claude
Code through Agent SDK server info.

`user-invocable: false` and `skillOverrides: {name: "off"}` entries are
omitted. Returned prompts preserve the literal `/name` invocation so
Claude Code, rather than this package, performs argument substitution,
dynamic context injection, permission grants, and forked-skill
execution.

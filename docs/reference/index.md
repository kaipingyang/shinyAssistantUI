# Package index

## UI and server

Create the chat surface and connect it to Shiny server logic.

<!-- end list -->

  - `assistantUIPage()` : Create a standalone assistant UI page
  - `assistantUIOutput()` : AI Assistant Chat UI Output
  - `renderAssistantUI()` : Render an Assistant UI Widget
  - `assistantUIServer()` : Assistant UI Server Module

## Backend handlers

Handler contracts and ready-to-use backend integrations.

<!-- end list -->

  - `assistant-handler-contract` : The assistantUIServer handler
    contract
  - `make_claude_handler()` : Create a ClaudeAgentSDK handler for
    assistantUIServer
  - `make_ellmer_handler()` : Create an ellmer streaming handler for
    assistantUIServer
  - `make_codeagent_handler()` : Use codeagent as the backend engine
  - `make_codeagent_remote_handler()` : Use codeagent as an
    out-of-process backend engine

## Sessions and persistence

Load, list, and persist backend conversations.

<!-- end list -->

  - `make_claude_session_loader()` : Create an on\_session\_load
    callback for ClaudeAgentSDK sessions
  - `list_claude_sessions()` : List Claude sessions for sidebar
    injection
  - `make_ellmer_session_loader()` : Create an on\_session\_load
    callback for ellmer session store
  - `ellmer_session_store()` : SQLite-backed session store for ellmer
    chats

## RStudio addins

Run Claude chat and workspace surfaces inside RStudio.

<!-- end list -->

  - `claude_addin()` : Open a Claude Code chat inside RStudio
  - `claude_workspace_addin()` : Open a multi-project Claude Workspace
    inside RStudio
  - `load_claude_skills()` : Load Claude Code skills as slash commands

## Themes and rich output

Customize appearance and render tool or plot output.

<!-- end list -->

  - `assistant_theme()` : Construct a theme for the assistant UI

  - `assistant_tool_view()` : Declare how a tool call's arguments are
    rendered in the chat card

  - `plot_data_uri()` :
    
    Capture a plot as a PNG data URI (for `on_image()`)

## Package overview

<!-- end list -->

  - `shinyAssistantUI` `shinyAssistantUI-package` : shinyAssistantUI: AI
    Assistant Chat UI for Shiny

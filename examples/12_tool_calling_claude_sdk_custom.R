library(shiny)
library(ClaudeAgentSDK)
devtools::load_all(here::here())

# ── 自定义 Claude Code 路径（Z盘独立安装）────────────────────────────────────
# Z盘路径示例：Z:\bgcrh\support\sp_app\claude_code\bin\claude
# Linux 映射：/mnt/usrfiles/bgcrh/support/sp_app/claude_code/bin/claude
CUSTOM_CLAUDE_PATH   <- "/mnt/usrfiles/bgcrh/support/sp_app/claude_code/bin/claude"
CUSTOM_CLAUDE_CONFIG <- "/mnt/usrfiles/bgcrh/support/sp_app/claude_code/.claude"

# ── settings.json 内容（对应 ~/.claude/settings.json 的 R list）─────────────
# 所有参数显式列出，对应 settings.json 的完整结构
claude_settings <- list(
  # 环境变量注入（覆盖模型 endpoint）
  env = list(
    ANTHROPIC_BASE_URL           = "http://localhost:4141/",
    ANTHROPIC_AUTH_TOKEN         = "sk-dummy",
    ANTHROPIC_MODEL              = "claude-sonnet-4.6",
    ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4.6",
    ANTHROPIC_SMALL_FAST_MODEL   = "claude-haiku-4.5",
    ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4.5",
    DISABLE_NON_ESSENTIAL_MODEL_CALLS = "1"
  ),
  # 工具权限：allow / deny 规则
  permissions = list(
    allow = list(
      "Bash(git status)",
      "Bash(git log:*)",
      "Read(**)"
    ),
    deny = list(),
    additionalDirectories = list(
      here::here()  # 允许访问当前项目目录
    )
  ),
  # 运行时行为
  skipDangerousModePermissionPrompt = FALSE,
  effortLevel                       = "high"
)

# ── ClaudeAgentOptions 全参数显式传入 ─────────────────────────────────────────
# 所有参数来自 ClaudeAgentOptions() 的完整签名
# 仅修改与默认值不同的参数；其余保持 NULL 表示使用 claude 自身默认值
make_opts <- function(resume_sid = NULL) {
  ClaudeAgentOptions(
    # ── 工具控制 ──────────────────────────────────────────────────────────
    tools             = NULL,         # NULL = 使用 claude 默认工具集
    allowed_tools     = character(),  # 额外允许的工具（补充 settings 里的 allow）
    disallowed_tools  = character(),  # 额外禁止的工具

    # ── 系统提示 ──────────────────────────────────────────────────────────
    system_prompt     = NULL,         # NULL = 使用默认；或传字符串/list(type="file", path=...)

    # ── MCP servers ───────────────────────────────────────────────────────
    mcp_servers       = list(),       # 额外 MCP server 配置

    # ── 权限模式 ──────────────────────────────────────────────────────────
    # "default"           = 按 settings 规则审批
    # "acceptEdits"       = 自动接受文件编辑，其他审批
    # "bypassPermissions" = 跳过所有审批（危险）
    permission_mode             = "default",
    permission_prompt_tool_name = "stdio",  # 审批请求路由到 stdio 消息流

    # ── 会话控制 ──────────────────────────────────────────────────────────
    continue_conversation = FALSE,    # 是否续接上一次对话
    resume                = resume_sid, # 续接指定 session_id（NULL = 新建）
    session_id            = NULL,     # 强制指定 session_id
    fork_session          = FALSE,    # 是否 fork 当前 session（不修改原始）

    # ── 限制 ──────────────────────────────────────────────────────────────
    max_turns          = NULL,        # 最大对话轮数（NULL = 无限制）
    max_budget_usd     = NULL,        # 最大费用限制（NULL = 无限制）
    task_budget        = NULL,        # 任务预算（total/per_task）

    # ── 模型 ──────────────────────────────────────────────────────────────
    model              = NULL,        # NULL = 使用 settings 里的 ANTHROPIC_MODEL
    fallback_model     = NULL,        # 主模型失败时的备用模型
    betas              = character(), # 开启的 beta 功能标志

    # ── Thinking（扩展推理）───────────────────────────────────────────────
    thinking           = list(type = "adaptive"),  # adaptive/enabled/disabled
    max_thinking_tokens = NULL,       # 最大 thinking token 数

    # ── 输出格式 ──────────────────────────────────────────────────────────
    output_format      = NULL,        # NULL = 文本；list(type="json_schema",...) = 结构化

    # ── 工作目录与路径 ────────────────────────────────────────────────────
    cwd                = here::here(), # claude 进程工作目录
    cli_path           = CUSTOM_CLAUDE_PATH, # 自定义 claude binary 路径（Z盘）

    # ── Settings 文件配置 ─────────────────────────────────────────────────
    settings           = jsonlite::toJSON(claude_settings, auto_unbox = TRUE),
    setting_sources    = NULL,

    # ── 附加目录 ──────────────────────────────────────────────────────────
    add_dirs           = list(),

    # ── 环境变量 ──────────────────────────────────────────────────────────
    # CLAUDE_CONFIG_DIR 指定 claude 读取 settings.json / CLAUDE.md 的目录
    # 用于隔离多个 app 各自的 claude 配置（不共用 ~/.claude）
    env                = list(
      CLAUDE_CONFIG_DIR = CUSTOM_CLAUDE_CONFIG
    ),

    # ── 流式控制 ──────────────────────────────────────────────────────────
    include_partial_messages = TRUE,  # 返回流式 StreamEvent
    max_buffer_size          = NULL,  # 最大 stdout buffer（NULL = 默认）

    # ── 其他 ──────────────────────────────────────────────────────────────
    stderr               = NULL,      # stderr 处理（NULL = 忽略）
    can_use_tool         = NULL,      # 自定义权限检查函数
    hooks                = NULL,      # hook 配置
    user                 = NULL,      # 用户标识
    agents               = NULL,      # 多 agent 配置
    plugins              = list(),    # 插件配置
    effort               = "high",    # 推理努力等级：low / medium / high / max
    extra_args           = list(),    # 传给 claude CLI 的额外参数
    enable_file_checkpointing = FALSE, # 文件检查点（实验性）
    sandbox              = NULL       # 沙箱配置
  )
}

# ── Handler ───────────────────────────────────────────────────────────────────
handler <- make_claude_handler(
  options          = make_opts(),
  session_map_path = file.path(here::here(), ".claude_session_map_custom.rds")
)

# ── 动态加载 Claude Code skills ──────────────────────────────────────────────
skills <- load_claude_skills(project_dir = here::here())

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML(
    "html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }"
  ))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE,
    on_session_load  = make_claude_session_loader(
      file.path(here::here(), ".claude_session_map_custom.rds")
    ),
    commands         = skills,
    suggestions = list(
      list(prompt = "List the files in the current directory using bash", text = "List files"),
      list(prompt = "Show the current git status",                        text = "Git status"),
      list(prompt = "What tools and capabilities do you have?",            text = "What can you do?")
    ),
    tools = list(
      list(name = "Bash",     description = "Execute shell commands"),
      list(name = "Read",     description = "Read file contents"),
      list(name = "Write",    description = "Write files"),
      list(name = "Edit",     description = "Edit existing files"),
      list(name = "Glob",     description = "Find files by pattern"),
      list(name = "Grep",     description = "Search in files"),
      list(name = "WebFetch", description = "Fetch content from a URL"),
      list(name = "LS",       description = "List directory contents")
    )
  )

  shiny::observe({
    ctrl$send_sessions(list(sessions = list_claude_sessions()))
  })
}

shinyApp(ui, server)

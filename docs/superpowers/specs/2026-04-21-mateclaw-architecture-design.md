# MateClaw 架构设计文档

> Version: 1.1.137-SNAPSHOT | 目标读者：学习者、需要二次开发的开发者

---

## 1. 系统概述

MateClaw 是一个**多供应商 AI Agent 平台**，核心能力：

1. **多供应商自动故障转移**：DashScope / OpenAI / Anthropic / Gemini / DeepSeek / Ollama 等 14+ 供应商，Provider Health Tracker 实现自动切换
2. **LLM Wiki 知识库**：PDF/Markdown 等原始材料消化成带引用的结构化页面
3. **工作区记忆**：AGENTS.md / SOUL.md / PROFILE.md / MEMORY.md + 每日笔记
4. **多渠道接入**：Web 控制台 + IM 渠道（DingTalk/飞书/企业微信/Telegram/Discord/QQ）+ 桌面端 + 嵌入式聊天组件

### 1.1 技术栈

| 层次 | 技术 |
|---|---|
| 后端 | Spring Boot 3.5 · Spring AI Alibaba 1.1 · MyBatis Plus · Flyway |
| 智能体 | StateGraph 运行时（Spring AI Alibaba Graph）· ReAct + Plan-Execute |
| 数据库 | H2（开发）/ MySQL 8.0+（生产）|
| 认证 | Spring Security + JWT（滑动窗口续期）|
| 前端 | Vue 3 · TypeScript · Vite · Element Plus · TailwindCSS 4 |
| 桌面端 | Electron + 内嵌 JRE 21 |
| 插件 | Java SPI 机制（Plugin SDK）|

---

## 2. 模块结构

```
mateclaw/
├── mateclaw-server/           # Spring Boot 后端（端口 18088）
│   └── src/main/java/vip/mate/
│       ├── agent/             # Agent 运行时（StateGraph 构建器、ReAct/Plan-Execute）
│       ├── channel/           # IM 渠道适配器（钉钉/飞书/企微/Telegram/Discord/QQ等）
│       ├── llm/                # LLM 提供商管理、多供应商故障转移
│       ├── tool/              # 内置工具 + MCP + ToolGuard 安全治理
│       ├── skill/             # SKILL.md 技能系统
│       ├── wiki/              # LLM Wiki 知识库
│       ├── memory/            # 工作区记忆
│       ├── workspace/         # 工作区文件管理
│       ├── auth/              # JWT 认证
│       ├── audit/             # 审计日志
│       ├── approval/          # 工具审批工作流
│       ├── plugin/            # 插件生命周期管理
│       └── config/            # Spring 配置类
├── mateclaw-ui/              # Vue 3 管理后台（端口 5173，构建产物打入后端 JAR）
├── mateclaw-webchat/         # 嵌入式聊天组件（UMD/ES bundle）
├── mateclaw-plugin-api/      # 插件 SDK（Java 接口定义）
├── mateclaw-plugin-sample/   # 插件参考实现
├── docker-compose.yml         # 全栈部署（MySQL + SearXNG + Server）
└── .env.example              # 环境变量模板
```

---

## 3. 核心模块详解

### 3.1 Agent 运行时（agent/）

#### 3.1.1 StateGraph 架构

MateClaw 使用 **Spring AI Alibaba Graph** 的 `StateGraph` 作为 Agent 运行时核心。

**两个 Agent 类型：**

| 类型 | 适用场景 | 图结构 |
|---|---|---|
| **ReAct** | 通用对话、问答 | Reasoning → Action → Observation → (循环或结束) |
| **Plan-Execute** | 复杂多步任务 | PlanGeneration → StepExecution → PlanSummary |

**ReAct 图结构（`AgentGraphBuilder.buildReActGraph()`）：**

```
START → REASONING_NODE
          ├→ ACTION_NODE → OBSERVATION_NODE
          │                   ├→ REASONING_NODE (继续循环)
          │                   ├→ SUMMARIZING_NODE (上下文压缩)
          │                   ├→ LIMIT_EXCEEDED_NODE → FINAL_ANSWER_NODE → END
          │                   └→ FINAL_ANSWER_NODE → END
          ├→ SUMMARIZING_NODE → REASONING_NODE
          ├→ LIMIT_EXCEEDED_NODE → FINAL_ANSWER_NODE → END
          └→ FINAL_ANSWER_NODE → END
```

**Plan-Execute 图结构：**

```
START → PLAN_GENERATION_NODE
          ├→ DIRECT_ANSWER_NODE → END (简单任务直接回答)
          └→ STEP_EXECUTION_NODE
                   ├→ STEP_EXECUTION_NODE (循环执行步骤)
                   └→ PLAN_SUMMARY_NODE → END
```

**StateGraph 状态键（`MateClawStateKeys`）：**
- `MESSAGES`：会话消息列表（APPEND 策略）
- `TOOL_CALLS` / `TOOL_RESULTS`：工具调用及结果
- `CURRENT_ITERATION` / `MAX_ITERATIONS`：迭代控制
- `PENDING_EVENTS`：待处理事件（APPEND 策略）
- `FINAL_ANSWER`：最终答案
- `STREAMED_CONTENT` / `STREAMED_THINKING`：流式内容暂存
- `AWAITING_APPROVAL`：审批状态

**Plan 特有状态键（`PlanStateKeys`）：**
- `GOAL` / `PLAN_STEPS` / `CURRENT_STEP_INDEX`：计划相关
- `WORKING_CONTEXT`：工作上下文

#### 3.1.2 关键类

| 类 | 职责 |
|---|---|
| `AgentGraphBuilder` | 纯构建器，负责构建完整 Agent 实例（模型、图、工具绑定、Prompt） |
| `BaseAgent` | Agent 抽象基类，定义 chat/chatStream/execute 接口和对话历史管理 |
| `StateGraphReActAgent` | ReAct Agent 实现，封装 StateGraph 执行逻辑 |
| `StateGraphPlanExecuteAgent` | Plan-Execute Agent 实现 |
| `AgentService` | Agent 服务层，对外暴露 chat/chatStream 接口 |
| `ConversationWindowManager` | 上下文窗口管理，支持动态裁剪和压缩摘要 |

#### 3.1.3 Prompt 构建（`buildEnhancedPrompt`）

Agent 系统提示词由多个块拼接而成：

```
basePrompt (从 MemoryManager 组装的工作区记忆块)
+ skillEnhancement (Skill Runtime 技能增强块)
+ toolGuidance (工具使用指南块，含 Memory/Session/Wiki 说明)
+ searchGuidance (内置搜索优先级说明)
+ wikiContext (Wiki 知识库上下文注入)
```

**内置工具优先级设定：**
- 内置搜索（DashScope/Kimi）优先
- `search` 工具作为补充/兜底

#### 3.1.4 模型构建工厂（`ProviderChatModelFactory`）

协议支持判断（`supportsStateGraph`）：
- `DASHSCOPE_NATIVE`
- `OPENAI_COMPATIBLE`
- `ANTHROPIC_MESSAGES`
- `OPENAI_CHATGPT`

各协议有专门的 Builder（`AgentDashScopeChatModelBuilder` / `AgentOpenAiCompatibleChatModelBuilder` / `AgentAnthropicChatModelBuilder`），处理模型选项、请求补丁（如 Kimi 内置搜索注入、GPT-5 reasoning_effort 兼容性、视频 MediaContent 补丁等）。

---

### 3.2 多供应商故障转移（llm/failover/）

#### 3.2.1 ProviderHealthTracker

**用途：**追踪每个 Provider 的连续失败次数，超过阈值后进入冷却窗口。

**配置（application.yml）：**
```yaml
mateclaw.failover.health:
  enabled: true
  failure-threshold: 3      # 连续失败 3 次
  cooldown-ms: 300000       # 冷却 5 分钟
```

**状态：**内存存储，进程重启后重置（v1 设计选择）。

**核心方法：**
- `isInCooldown(providerId)`：检查是否在冷却中
- `recordFailure(providerId)`：记录失败，触发冷却
- `recordSuccess(providerId)`：成功时重置计数器

#### 3.2.2 Fallback Chain 构建（`buildFallbackChain`）

**排序规则：**
1. `fallback_priority > 0` 的 Provider 按 priority 升序排（数字越小优先级越高）
2. `fallback_priority == 0` 的 Provider 按字母序排
3. Agent 可设置 `mate_agent_provider_preference` 偏好，覆盖全局排序

**跳过条件：**
- 主 Provider 自身（避免重复）
- 不在 `AvailableProviderPool` 中的 Provider（健康检查不通过）
- 没有可用 ChatModel 的 Provider
- 同名模型（不同 Provider 的同名模型只保留一个）

#### 3.2.3 流式故障转移（`NodeStreamingChatHelper`）

流式调用通过 `FallbackEntry` 列表顺序尝试：
- 主 Provider 失败后，遍历 Fallback Chain
- 每次失败记录到 `ProviderHealthTracker`
- 成功后立即返回，不再尝试后续

---

### 3.3 工具系统（tool/）

#### 3.3.1 工具注册机制（ToolRegistry）

- 启动时扫描所有 `@Component` 且继承 `org.springframework.ai.tool.method.MethodToolCallback` 的 Bean
- 支持内置工具（`builtin/`）和 MCP 工具（`mcp/runtime/McpToolCallbackProvider`）
- 工具可标记为 `ConcurrencyUnsafe`（如 shell 执行）

#### 3.3.2 内置工具（builtin/）

| 工具 | 功能 | 安全说明 |
|---|---|---|
| `ShellExecuteTool` | 本地命令执行 | ToolGuard 默认 NEEDS_APPROVAL；超时 60s（上限 300s）；输出截断；环境变量敏感信息过滤 |
| `ReadFileTool` | 读文件 | WorkspacePathGuard 限制访问范围 |
| `WriteFileTool` | 写文件 | WorkspacePathGuard 限制 |
| `EditFileTool` | 编辑文件 | WorkspacePathGuard 限制 |
| `WebSearchTool` | 网页搜索 | SearXNG / Serper / DuckDuckGo |
| `BrowserUseTool` | 浏览器自动化 | Playwright 驱动，需审批 |
| `SkillManageTool` | 技能管理 | - |
| `SqlQueryTool` | 数据库查询 | 需配置数据源 |
| `DatasourceTool` | 数据源管理 | - |
| `CronJobTool` | 定时任务 | - |
| `DelegateAgentTool` | Agent 委托 | - |
| `DocumentExtractTool` | 文档文本提取 | - |
| `ImageGenerateTool` | 图片生成 | - |
| `VideoGenerateTool` | 视频生成 | - |
| `MusicGenerateTool` | 音乐生成 | - |
| `WorkspaceMemoryTool` | 工作区记忆文件读写 | - |

#### 3.3.3 ShellExecuteTool 安全设计

```java
// 1. 敏感环境变量过滤
pb.environment().keySet().removeIf(key ->
    key.contains("KEY") || key.contains("SECRET") || key.contains("TOKEN")
            || key.contains("PASSWORD") || key.contains("CREDENTIAL"));

// 2. 超时硬上限
timeout = Math.min(timeout, 300); // 最多 300 秒

// 3. 输出重定向到临时文件（避免管道阻塞导致超时失效）
stdoutFile = Files.createTempFile("mc_out_", ".tmp");
stderrFile = Files.createTempFile("mc_err_", ".tmp");
pb.redirectOutput(stdoutFile.toFile());
pb.redirectError(stderrFile.toFile());

// 4. 超时强制杀进程树
if (!completed) {
    killProcessTree(process); // Windows: taskkill /F /T; Unix: SIGKILL
}
```

#### 3.3.4 MCP 工具支持

- 通过 `spring-ai-starter-mcp-client` 连接外部 MCP Server
- 支持 stdio / SSE / Streamable HTTP 三种传输
- 自动扫描 `@McpTool` 注解方法
- `McpClientManager` 手动管理生命周期（禁用了 Spring AI 自动配置）

---

### 3.4 ToolGuard 安全治理（tool/guard/）

#### 3.4.1 架构

```
ToolGuardEngine
    └→ 多个 Guardian（按 priority 降序执行）
         ├→ FilePathGuardian      (路径穿越防护)
         ├→ FileWriteGuardian      (写文件防护)
         ├→ ShellCommandGuardian   (Shell 命令防护)
         └→ CredentialExposureGuardian (凭证泄露防护)
    └→ ToolPolicyResolver (裁决)
```

#### 3.4.2 裁决流程

1. **Guardian 产出 Findings（事实）**
2. **PolicyResolver 根据 Findings 映射为裁决**
3. **裁决结果：** `ALLOW` / `NEEDS_APPROVAL` / `DENY`

#### 3.4.3 审批工作流

```
工具调用 → ToolGuardEngine.evaluate()
          ├→ ALLOW → 直接执行
          ├→ DENY → 返回拒绝
          └→ NEEDS_APPROVAL → 写入 mate_tool_approval 表 → 暂停 → 用户审批
                   ↑                                                      │
                   └───────────── 审批通过后 replay ──────────────────────┘
```

**强制重放（forced replay）：**审批通过后，Agent 重新执行该工具调用，但跳过 ToolGuard 检查。

#### 3.4.4 文件访问控制（WorkspacePathGuard）

- 工作区目录：Agent 绑定的工作区 `base_path`
- 读取文件：只允许在工作区目录内
- 写文件：只允许在工作区目录内
- 路径穿越检测：`..` 穿透检查

---

### 3.5 IM 渠道系统（channel/）

#### 3.5.1 适配器架构

```
ChannelAdapter (接口)
    ↑
AbstractChannelAdapter (基类)
    ├→ 统一生命周期管理（start/stop）
    ├→ Bot 前缀过滤
    ├→ 配置解析（configJson）
    ├→ 访问控制（allow_from 白名单）
    └→ 消息路由到 Agent
        ↑
具体适配器
    ├→ DingTalkChannelAdapter
    ├→ FeishuChannelAdapter
    ├→ WeComChannelAdapter
    ├→ TelegramChannelAdapter
    ├→ DiscordChannelAdapter
    └→ QQChannelAdapter
```

#### 3.5.2 连接管理与重连

- `ConnectionState`：CONNECTED / RECONNECTING / DISCONNECTED / ERROR
- `ExponentialBackoff`：指数退避重连
- `ChannelHealthMonitor`：监控连接健康状态

**消息处理流程：**
```
onMessage(message)
    → Bot 前缀过滤 (shouldProcess)
    → 清理前缀 (cleanBotPrefix)
    → 访问控制检查 (checkAccess)
    → 路由到 Agent (messageRouter.enqueue)
```

#### 3.5.3 消息渲染（ChannelMessageRenderer）

- `filter_thinking`：过滤思考内容
- `filter_tool_messages`：过滤工具调用消息
- `message_format`：平台格式化（markdown / text / html）
- `PLATFORM_LIMITS`：各平台消息长度限制

---

### 3.6 LLM Wiki 知识库（wiki/）

**消化流程：**
1. 上传原始材料（PDF/Markdown/网页）
2. 提取文本 → 分块（chunk）
3. 为每个 chunk 生成 Embedding
4. 生成 Wiki Page（结构化页面，自动建立 `[[链接]]`）
5. 页面存储到 `mate_wiki_page` 表，引用存储到 `mate_wiki_chunk` 表

**上下文注入：**Agent 调用时，通过 `WikiContextService.buildWikiContext()` 将相关 Wiki 内容注入 Prompt。

---

### 3.7 工作区记忆（memory/workspace/）

**Memory 文件类型：**
- `PROFILE.md`：稳定用户画像、偏好、协作风格
- `SOUL.md`：Agent 灵魂/角色设定
- `MEMORY.md`：提炼的长期记忆、持久事实、经验教训
- `AGENTS.md`：Agent 配置
- `memory/YYYY-MM-DD.md`：每日笔记

**结构化记忆工具：**
- `remember_structured(agentId, type, key, content)`
- `recall_structured(agentId, type, keyword)`
- `forget_structured(agentId, type, key)`

---

### 3.8 技能系统（skill/）

**SKILL.md 结构：**
```yaml
---
name: skill-name
description: ...
---
# 技能内容（Markdown）
```

**SkillRuntimeService：**解析 SKILL.md frontmatter，构建技能增强 Prompt 块，按需加载/缓存技能内容。

**ClawHub 市场：**`https://clawhub.ai` 提供技能搜索和安装。

---

### 3.9 认证与安全（auth/ + config/）

#### 3.9.1 JWT 认证

**Token 结构：**
```java
Jwts.builder()
    .subject(username)
    .claim("userId", userId)
    .claim("role", userRole)
    .issuedAt(new Date())
    .expiration(new Date(now + jwtExpiration))
    .signWith(getSignKey())  // HMAC-SHA256
```

**滑动窗口续期：**Token 接近过期时（剩余 < `renewalThreshold`），自动签发新 Token，通过 `X-New-Token` 响应头返回。

**Token 提取：**支持两种方式：
1. `Authorization: Bearer <token>`（标准）
2. `?token=<token>`（SSE/EventSource 专用）

#### 3.9.2 密码管理

- BCrypt 哈希存储
- 默认用户 `admin` / `admin123`（**生产必须修改**）
- 支持管理员重置密码

#### 3.9.3 Spring Security 配置

**公开接口（permitAll）：**
```java
"/api/v1/auth/login"
"/api/v1/settings/language"
"/api/v1/agents/*/chat/stream"
"/api/v1/chat/stream"
"/api/v1/chat/*/stop"
"/api/v1/setup/**"
"/api/v1/channels/webhook/**"
"/api/v1/channels/webchat/**"
"/api/v1/talk/ws"
```

**其他接口：**需认证（`authenticated()`）

#### 3.9.4 RBAC

用户角色：`admin` / `user`，通过 `SimpleGrantedAuthority("ROLE_" + role)` 注入。

---

### 3.10 插件系统（plugin/）

#### 3.10.1 插件接口（mateclaw-plugin-api）

```java
public interface MateClawPlugin {
    void onLoad(PluginContext context);   // 加载时调用，注入平台上下文
    void onEnable();                      // 启用时调用
    void onDisable();                     // 禁用时调用
}
```

#### 3.10.2 插件类型（PluginType）

- `CHANNEL`：渠道适配器
- `MEMORY`：记忆提供者
- `TOOL`：工具扩展
- `PROVIDER`：LLM 提供商

#### 3.10.3 生命周期管理（PluginManager）

- 扫描 `~/.mateclaw/plugins/` 目录
- 加载 `META-INF/spring/plugins/` 配置或 `@Component` 扫描
- 管理 onEnable / onDisable 调用

---

## 4. 数据库架构

### 4.1 核心表

| 表名 | 用途 |
|---|---|
| `mate_user` | 用户（username, password BCrypt, role, enabled）|
| `mate_agent` | Agent 配置（name, agent_type, system_prompt, model_name, max_iterations）|
| `mate_model_config` | 模型配置（provider, model_name, temperature, max_tokens, is_default）|
| `mate_model_provider` | Provider 配置（api_key, base_url, generate_kwargs, fallback_priority）|
| `mate_channel` | IM 渠道配置（channel_type, config_json, bot_prefix）|
| `mate_conversation` | 会话（conversation_id, agent_id, username, message_count）|
| `mate_message` | 消息（conversation_id, role, content, token_usage, metadata JSON）|
| `mate_tool` | 工具注册（name, bean_name, enabled, builtin）|
| `mate_skill` | 技能（name, skill_content, enabled, builtin）|
| `mate_mcp_server` | MCP Server 配置（transport, url, command, enabled）|
| `mate_tool_approval` | 工具审批（pending_id, tool_name, tool_arguments, status）|
| `mate_tool_guard_rule` | 安全规则（rule_id, tool_name, category, severity, pattern, decision）|
| `mate_tool_guard_audit_log` | 安全审计日志 |
| `mate_workspace_file` | 工作区文件（agent_id, filename, content CLOB）|
| `mate_wiki_knowledge_base` | Wiki 知识库 |
| `mate_wiki_page` | Wiki 页面（slug, title, content, outgoing_links）|
| `mate_wiki_chunk` | Wiki Chunk（embedding, source_raw_ids）|
| `mate_audit_event` | 操作审计事件 |
| `mate_cron_job` | 定时任务 |
| `mate_async_task` | 异步任务（图片/视频生成）|
| `mate_memory_recall` | 记忆召回追踪（Dreaming 评分）|

### 4.2 Flyway 迁移

- 开发环境：H2，迁移脚本在 `resources/db/migration/h2/`
- 生产环境：MySQL，迁移脚本在 `resources/db/migration/mysql/`
- 迁移文件命名：`V{version}__{description}.sql`
- 当前最新：`V27__memory_recall_review_fields.sql`

---

## 5. 前端架构（mateclaw-ui/）

```
src/
├── views/          # 路由页面（Agent/Channel/Skill/Wiki/System 等管理页面）
├── components/     # 可复用组件
├── composables/   # Vue Composition API Hooks
├── stores/        # Pinia 状态管理
│   ├── agentStore.ts
│   ├── channelStore.ts
│   ├── wikiStore.ts
│   └── ...
├── types/         # TypeScript 类型定义
├── utils/         # 工具函数（API 客户端等）
├── i18n/          # 国际化（zh-CN + en）
└── router/        # Vue Router 配置
```

**API 客户端：**基于 Axios，统一拦截器处理 JWT Token 注入和错误处理。

**构建目标：**构建产物通过 Spring Boot 静态资源服务（`classpath:/static/`），无需独立部署。

---

## 6. Docker 部署架构

```
┌─────────────────────────────────────────────────┐
│ docker-compose                                  │
│                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │  MySQL   │  │  SearXNG  │  │ mateclaw-    │  │
│  │  8.0     │  │ (搜索)    │  │ server       │  │
│  │          │  │           │  │ (JAR)        │  │
│  └────┬─────┘  └─────┬─────┘  └──────┬───────┘  │
│       │              │               │          │
│       └──────────────┴───────────────┘          │
│                  内部网络                        │
└─────────────────────────────────────────────────┘
         │                              │
         │ :3306                        │ :18080
         ↓                              ↓
   宿主机 MySQL                   宿主机浏览器
```

**环境变量必填项：**
- `DASHSCOPE_API_KEY`：阿里云 DashScope API Key
- `DB_PASSWORD`：数据库密码
- `DB_ROOT_PASSWORD`：MySQL root 密码

**建议生产覆盖：**
- `JWT_SECRET`：JWT 签名密钥（至少 32 字符）
- `MATECLAW_CORS_ALLOWED_ORIGINS`：CORS 白名单

---

## 7. 关键设计模式

### 7.1 工厂/构建器模式

- `AgentGraphBuilder`：复杂 Agent 实例的构建（模型、图、工具绑定、Prompt）
- `AgentDashScopeChatModelBuilder` / `AgentOpenAiCompatibleChatModelBuilder`：按协议构建 ChatModel
- `ToolExecutionExecutor`：工具执行工厂

### 7.2 模板方法模式

- `AbstractChannelAdapter`：IM 渠道基类，定义 `doStart()` / `doStop()` 模板方法
- `BaseAgent`：定义 `chat()` / `chatStream()` / `execute()` 抽象方法

### 7.3 策略模式

- `ToolGuardEngine` + 多个 `Guardian`：`Guardian` 策略产出 Findings，`PolicyResolver` 策略决定裁决
- `SearchProviderRegistry`：搜索提供者策略
- `ImageGenerationProvider`：图片生成策略

### 7.4 观察者模式

- `GraphEventPublisher` → `ReActLifecycleListener`：图执行生命周期事件通知
- `ChannelHealthMonitor`：渠道健康状态变更通知

### 7.5 SPI 机制

- 插件系统：`MateClawPlugin` 接口 + `PluginContext` 注入

---

## 8. 配置参考

### 8.1 application.yml 关键配置

```yaml
server:
  port: 18088

spring:
  profiles:
    active: dev  # dev=H2, mysql=MySQL
  ai:
    dashscope:
      api-key: ${DASHSCOPE_API_KEY}
    retry:
      max-attempts: 2  # Spring AI 重试（业务层重试由 agent/wiki 自己控制）
      on-http-codes: 429,503,529

mateclaw:
  jwt:
    secret: ${JWT_SECRET:MateClaw-Secret-Key-2024...}  # 生产必须修改
    expiration: 86400000        # 24 小时
    renewal-threshold: 7200000 # 2 小时滑动窗口续期
  failover:
    health:
      enabled: true
      failure-threshold: 3
      cooldown-ms: 300000
  skill:
    workspace:
      root: ~/.mateclaw/skills
  plugin:
    user-dir: ~/.mateclaw/plugins
  hooks:
    enabled: true
    global-rate-limit: 200

mate:
  agent:
    graph:
      observation:
        max-single-observation-chars: 8000
        max-total-observation-chars: 24000
    tool:
      timeout:
        default-timeout-seconds: 300
        per-category:
          shell: 120
          web: 30
  wiki:
    max-chunk-size: 30000
    max-context-chars: 10000
```

---

## 9. 可应用于其他项目的设计要点

1. **多供应商故障转移**：ProviderHealthTracker + Fallback Chain 实现，生产环境很有价值
2. **StateGraph Agent 运行时**：Spring AI Alibaba Graph 的 StateGraph，可独立使用
3. **ToolGuard 安全治理**：Guardian + PolicyResolver 架构，可扩展的安全裁决框架
4. **IM 渠道适配器**：AbstractChannelAdapter 模板方法，便于扩展新渠道
5. **滑动窗口 Token 续期**：改善 JWT 用户体验
6. **工作区文件 + 记忆系统**：可独立使用的 Agent 记忆架构
7. **LLM Wiki 知识库**：完整的内容消化 → 嵌入 → 检索 → 上下文注入流程

# MateClaw 功能模块详解

> 本文档按功能模块拆分讲解，目标：学习 MateClaw 的核心实现逻辑，以便应用到自己项目中

---

## 目录

1. [动态 LLM 配置系统](#1-动态-llm-配置系统)
2. [RAG（Wiki 知识库）实现](#2-ragwiki-知识库实现)
3. [MCP 协议支持](#3-mcp-协议支持)
4. [Tool 工具系统](#4-tool-工具系统)
5. [Agent 模式实现](#5-agent-模式实现)
6. [模型的记忆功能](#6-模型的记忆功能)
7. [自我进化（Dream）](#7-自我进化dream)
8. [如何在项目中新增一个 Agent](#8-如何在项目中新增一个-agent)

---

## 1. 动态 LLM 配置系统

### 1.1 核心数据模型

LLM 配置涉及两张核心表：

**mate_model_provider（Provider 实体）：**
```sql
CREATE TABLE mate_model_provider (
    provider_id    VARCHAR(64)  PRIMARY KEY,  -- e.g. "dashscope", "openai-compatible"
    name           VARCHAR(128),
    chat_model     VARCHAR(64),               -- 协议类型：dashscope-nativa / openai-compatible / anthropic-messages
    api_key        VARCHAR(256),
    base_url       VARCHAR(512),
    generate_kwargs TEXT,                      -- JSON，存放 provider 级参数
    is_custom      BOOLEAN,                   -- 是否自定义 provider
    fallback_priority INT DEFAULT 0,          -- 故障转移优先级
    auth_type      VARCHAR(16) DEFAULT 'api_key',
    -- OAuth 相关字段...
);
```

**mate_model_config（模型配置实体）：**
```sql
CREATE TABLE mate_model_config (
    id             BIGINT PRIMARY KEY,
    name           VARCHAR(128),
    provider       VARCHAR(64),               -- 关联 provider_id
    model_name     VARCHAR(128),             -- e.g. "qwen-max", "gpt-4o"
    temperature    DOUBLE,
    max_tokens     INT,
    top_p          DOUBLE,
    is_default     BOOLEAN,                  -- 是否默认模型
    enabled        BOOLEAN,
    enable_search  BOOLEAN,
    search_strategy VARCHAR(32),              -- 搜索上下文大小
    max_input_tokens INT,
    model_type     VARCHAR(32),               -- chat / embedding / image ...
);
```

### 1.2 Provider 协议体系

**文件：**`vip.mate.llm.model.ModelProtocol`

```java
public enum ModelProtocol {
    DASHSCOPE_NATIVE("dashscope", "DashScope Native"),
    OPENAI_COMPATIBLE("openai-compatible", "OpenAI Compatible"),
    ANTHROPIC_MESSAGES("anthropic-messages", "Anthropic Messages"),
    OPENAI_CHATGPT("openai-chatgpt", "OpenAI ChatGPT"),
    ;
}
```

每个协议对应不同的 ChatModel 构建器：
- `DASHSCOPE_NATIVE` → `AgentDashScopeChatModelBuilder`
- `OPENAI_COMPATIBLE` → `AgentOpenAiCompatibleChatModelBuilder`
- `ANTHROPIC_MESSAGES` → `AgentAnthropicChatModelBuilder`
- `OPENAI_CHATGPT` → `ChatGPTResponsesClient`

### 1.3 ChatModel 工厂构建

**文件：**`vip.mate.llm.chatmodel.ProviderChatModelFactory`

```java
public ChatModel buildFor(ModelConfigEntity config, RetryTemplate retryOverride) {
    ModelProviderEntity provider = modelProviderService.getProviderConfig(config.getProvider());
    ModelProtocol protocol = ModelProtocol.fromChatModel(provider.getChatModel());

    return switch (protocol) {
        case DASHSCOPE_NATIVE -> dashScopeBuilder.build(config, provider);
        case OPENAI_COMPATIBLE -> openAiBuilder.build(config, provider);
        case ANTHROPIC_MESSAGES -> anthropicBuilder.build(config, provider);
        case OPENAI_CHATGPT -> chatGptResponsesBuilder.build(config, provider);
    };
}
```

### 1.4 动态配置读取流程

**文件：**`vip.mate.llm.service.ModelProviderService`

```
用户配置（UI） → mate_model_provider 表 → ProviderChatModelFactory.buildFor()
                                              ↓
                                    按协议选择 Builder
                                              ↓
                                    构建 ChatModel 实例
                                              ↓
                                    注入 AgentGraphBuilder
                                              ↓
                                    编译 StateGraph
```

### 1.5 多模型故障转移

**文件：**`vip.mate.llm.failover`

```
请求 → NodeStreamingChatHelper
         ↓
   主模型调用
         ↓ 失败
   ProviderHealthTracker.recordFailure()
         ↓ 连续失败 ≥3 次
   进入 5 分钟冷却窗口
         ↓
   遍历 Fallback Chain（按 fallback_priority 排序）
         ↓
   找到下一个健康的可用模型 → 调用
         ↓
   成功 → recordSuccess() → 重置计数器
```

**ProviderHealthTracker：**
```java
// 内存中追踪每个 provider 的连续失败
ConcurrentHashMap<String, AtomicLong> consecutiveFailures;
ConcurrentHashMap<String, Long> cooldownUntilMs;

// 失败时
counter.incrementAndGet();
if (failures >= failureThreshold) {
    cooldownUntilMs.put(providerId, now + cooldownMs);
}

// 成功时
counter.set(0);
cooldownUntilMs.remove(providerId);
```

**配置参数（application.yml）：**
```yaml
mateclaw.failover.health:
  enabled: true
  failure-threshold: 3    # 连续失败 3 次
  cooldown-ms: 300000     # 冷却 5 分钟
```

---

## 2. RAG（Wiki 知识库）实现

### 2.1 Wiki 系统架构

Wiki 模块负责将原始文档（PDF、Markdown、网页等）消化成**可检索、可溯源的结构化页面**。

```
原始材料上传
    ↓
文本提取（DocumentExtractTool）
    ↓
分块（Chunking）— 按段落/句子分割
    ↓
Embedding 生成（DashScope Embedding）
    ↓
存储 Chunk + Embedding → mate_wiki_chunk 表
    ↓
LLM 生成 Wiki Page（结构化 + 内部链接 [[]]）
    ↓
存储 Page → mate_wiki_page 表
    ↓
Agent 检索时：向量相似度搜索 → 上下文注入 Prompt
```

### 2.2 核心数据库表

```sql
-- 知识库
CREATE TABLE mate_wiki_knowledge_base (
    id           BIGINT PRIMARY KEY,
    name         VARCHAR(128),
    agent_id     BIGINT,                    -- 关联 Agent
    status       VARCHAR(32),               -- active/processing
    page_count   INT,
    raw_count    INT,
    source_directory VARCHAR(512),            -- 原始材料目录
    config_content CLOB,
);

-- 原始材料
CREATE TABLE mate_wiki_raw_material (
    id                BIGINT PRIMARY KEY,
    kb_id             BIGINT,
    title             VARCHAR(256),
    source_type       VARCHAR(32),           -- text / pdf / markdown / url
    source_path       VARCHAR(512),
    original_content  CLOB,
    extracted_text    CLOB,
    content_hash      VARCHAR(64),           -- 去重判断
    processing_status VARCHAR(32),            -- pending / processing / done / error
);

-- Wiki 页面
CREATE TABLE mate_wiki_page (
    id              BIGINT PRIMARY KEY,
    kb_id           BIGINT,
    slug            VARCHAR(256),            -- URL 友好 slug
    title           VARCHAR(256),
    content         CLOB,                    -- Markdown 内容
    summary         VARCHAR(1024),
    outgoing_links  CLOB,                    -- JSON，关联的其他 page slug
    source_raw_ids  CLOB,                    -- JSON，来源的 raw material ids
    version         INT,
);

-- Chunk（用于向量检索）
CREATE TABLE mate_wiki_chunk (
    id              BIGINT PRIMARY KEY,
    kb_id           BIGINT,
    page_id         BIGINT,
    raw_id          BIGINT,
    content         CLOB,                    -- 分块文本
    chunk_index     INT,                     -- 在原始材料中的位置
    embedding       BLOB,                    -- 向量（如果有）
    embedding_model VARCHAR(64),              -- 生成 embedding 的模型
);
```

### 2.3 Wiki 消化流程

**文件：**`vip.mate.wiki.service.WikiIngestService`

```
Phase A: 提取文本
    extract_text(rawMaterial) → extractedText

Phase B: 分块 + Embedding（可并行）
    split_chunks(extractedText) → List<Chunk>
    For each chunk:
        embedding = embeddingModel.embed(chunk.content)
        save to mate_wiki_chunk

Phase C: 生成 Wiki Page
    prompt = f"基于以下内容生成结构化 Wiki 页面..."
    pageContent = llm.invoke(prompt)
    auto_link_pages(pageContent) → outgoing_links
    save to mate_wiki_page
```

**分块策略（`WikiChunkStrategy`）：**
- 按字符数分块（默认 `max_chunk_size: 30000`）
- 保留段落边界
- 相邻 chunk 有重叠（用于保持上下文连贯性）

### 2.4 检索与上下文注入

**文件：**`vip.mate.wiki.service.WikiContextService`

当 Agent 处理用户请求时：

```java
public String buildWikiContext(Long agentId) {
    // 1. 获取当前对话的 query
    String query = extractCurrentQuery();

    // 2. 向量检索 top-k 相关 chunk
    List<WikiChunkEntity> chunks = wikiSearchService.search(query, topK=5);

    // 3. 构建上下文字符串（含引用信息）
    StringBuilder ctx = new StringBuilder();
    ctx.append("## 相关知识（来自 Wiki）\n\n");
    for (WikiChunk chunk : chunks) {
        ctx.append("> 来源：").append(chunk.getSourceTitle())
           .append("\n")
           .append(chunk.getContent())
           .append("\n\n");
    }

    return ctx.toString();
}
```

**注入位置：**`AgentGraphBuilder.buildEnhancedPrompt()` 末尾拼接 wikiContext。

---

## 3. MCP 协议支持

### 3.1 MCP 概述

MCP（Model Context Protocol）是一种标准协议，允许 Agent 与外部工具服务器通信。

**支持的传输类型：**
- `stdio`：标准输入/输出（本地进程）
- `SSE`：Server-Sent Events（HTTP 长连接）
- `Streamable HTTP`：可流式传输的 HTTP

### 3.2 核心架构

```
MCP Server（外部进程，如 Claude Desktop 的工具服务）
    ↓ stdio / SSE / HTTP
McpClientManager（MateClaw 内部）
    ↓
McpToolCallbackProvider（将 MCP 工具转换为 Spring AI Tool）
    ↓
ToolRegistry（统一工具注册）
    ↓
Agent（通过 ToolExecutionExecutor 调用）
```

### 3.3 核心类

**McpClientManager：**
```java
public class McpClientManager {
    // 管理所有 MCP client 生命周期
    private final Map<String, McpSyncClient> clients = new ConcurrentHashMap<>();

    public void startServer(McpServerEntity entity) {
        // 根据 transport 类型创建 client
        McpClientTransport transport = createTransport(entity);
        McpSyncClient client = McpClientFactory.create(transport, entity.getTimeoutSeconds());
        clients.put(entity.getName(), client);
    }

    public List<ToolCallback> getToolCallbacks(String serverName) {
        McpSyncClient client = clients.get(serverName);
        return client.listTools();  // 列出该 server 所有工具
    }

    public void stopServer(String serverName) {
        clients.get(serverName).close();
        clients.remove(serverName);
    }
}
```

**McpServerEntity（配置表）：**
```sql
CREATE TABLE mate_mcp_server (
    id              BIGINT PRIMARY KEY,
    name            VARCHAR(128),
    transport       VARCHAR(32),   -- stdio / sse / streamable-http
    url             VARCHAR(512),  -- SSE/Streamable HTTP 端点
    command         VARCHAR(512),  -- stdio 模式的命令
    args_json       TEXT,
    env_json        TEXT,
    cwd             VARCHAR(512),
    enabled         BOOLEAN,
    timeout_seconds INT,
);
```

### 3.4 stdio 传输（CwdAwareStdioClientTransport）

**文件：**`vip.mate.tool.mcp.runtime.CwdAwareStdioClientTransport`

stdio 模式下，MCP 工具通过子进程通信：

```java
// 1. 启动子进程
ProcessBuilder pb = new ProcessBuilder();
pb.command(command, args...);
pb.environment().putAll(envVars);
pb.directory(workingDirectory);
Process process = pb.start();

// 2. 通过 stdin 发送 JSON-RPC 请求
String request = buildJsonRpcRequest("tools/list", params);
process.getOutputStream().write(request.getBytes());

// 3. 从 stdout 读取响应
String response = readStream(process.getInputStream());
```

### 3.5 自动扫描与注册

**McpServerBootstrapRunner**（启动时运行）：
```java
public void run() {
    List<McpServerEntity> servers = mcpServerService.listEnabled();
    for (McpServerEntity server : servers) {
        mcpserverManager.startServer(server);
        List<ToolCallback> tools = mcpserverManager.getToolCallbacks(server.getName());
        toolRegistry.registerMcpTools(server.getName(), tools);
    }
}
```

---

## 4. Tool 工具系统

### 4.1 工具注册机制

**文件：**`vip.mate.tool.ToolRegistry`

```java
public class ToolRegistry {
    // 所有已注册的工具（Bean name → ToolCallback）
    private final Map<String, ToolCallback> tools = new ConcurrentHashMap<>();

    // 并发不安全的工具（如 shell 执行）
    private final Set<String> concurrencyUnsafeTools = new ConcurrentHashMapSet<>();

    public void registerTool(String name, ToolCallback callback) {
        tools.put(name, callback);
    }

    public void registerMcpTools(String serverName, List<ToolCallback> mcpTools) {
        for (ToolCallback tool : mcpTools) {
            // MCP 工具加前缀避免同名冲突
            tools.put(serverName + ":" + tool.getName(), tool);
        }
    }

    public ToolCallback getTool(String name) {
        return tools.get(name);
    }

    public AgentToolSet getEnabledToolSet() {
        // 过滤 enabled 的工具，构建 ToolSet
    }

    // 标记并发不安全的工具
    public void markConcurrencyUnsafe(String toolName) {
        concurrencyUnsafeTools.add(toolName);
    }
}
```

### 4.2 内置工具一览

| 工具类 | 方法名 | 功能 |
|---|---|---|
| `ReadFileTool` | `read_file` | 读文件（WorkspacePathGuard 限制）|
| `WriteFileTool` | `write_file` | 写文件（WorkspacePathGuard 限制）|
| `EditFileTool` | `edit_file` | 编辑文件（WorkspacePathGuard 限制）|
| `ShellExecuteTool` | `execute_shell_command` | 执行 Shell 命令 |
| `WebSearchTool` | `search` | 网页搜索 |
| `BrowserUseTool` | `browser_use` | 浏览器自动化（Playwright）|
| `SkillManageTool` | `skill_*` | 技能管理 |
| `SkillFileTool` | `*_workspace_memory_file` | 工作区记忆文件读写 |
| `SqlQueryTool` | `query_database` | SQL 查询 |
| `DatasourceTool` | `list_datasources` | 数据源管理 |
| `CronJobTool` | `*_cron_job` | 定时任务管理 |
| `DelegateAgentTool` | `delegate_to_agent` | Agent 委托 |
| `DocumentExtractTool` | `extract_*_text` | 文档文本提取 |
| `ImageGenerateTool` | `generate_image` | 图片生成 |
| `VideoGenerateTool` | `generate_video` | 视频生成 |
| `MusicGenerateTool` | `generate_music` | 音乐生成 |
| `WorkspaceMemoryTool` | `*_workspace_memory_*` | 结构化记忆操作 |
| `DateTimeTool` | `get_current_time` | 获取当前时间 |

### 4.3 工具执行流程

**文件：**`vip.mate.agent.graph.executor.ToolExecutionExecutor`

```
工具调用请求（TOOL_CALLS 状态）
    ↓
两阶段执行：
    ├── 阶段一：顺序 Guard 检查（逐工具）
    │       ToolGuardEngine.evaluate(toolName, params)
    │           → ALLOW → 放行
    │           → DENY → 返回拒绝
    │           → NEEDS_APPROVAL → 暂停，写入 mate_tool_approval
    │
    └── 阶段二：并发执行（无依赖的工具）
            concurrentExecute(toolCalls, conversationId)
                ↓
            ToolRegistry.getTool(name)
                ↓
            toolCallback.invoke(params)
                ↓
            工具执行结果

结果聚合
    ↓
ToolResponseMessage
    ↓
ObservationNode（处理观察结果）
```

### 4.4 ToolGuard 安全引擎

**文件：**`vip.mate.tool.guard.engine.ToolGuardEngine`

```
ToolInvocationContext
    ↓
┌─────────────────────────────────────────────┐
│ 按 priority 降序执行 Guardian               │
│                                             │
│ FilePathGuardian      → 路径穿越检测         │
│ FileWriteGuardian     → 写文件风险评估       │
│ ShellCommandGuardian  → Shell 命令风险评估   │
│ CredentialExposureGuardian → 凭证泄露检测   │
└─────────────────────────────────────────────┘
    ↓ 聚合 Findings
ToolPolicyResolver.resolve(findings, context)
    ↓
GuardDecision: ALLOW / NEEDS_APPROVAL / DENY
```

**Guardian 接口：**
```java
public interface ToolGuardGuardian {
    String name();              // e.g. "FilePathGuardian"
    int priority();             // 执行顺序（越大越先）
    boolean alwaysRun();        // 是否无条件执行
    boolean supports(Context);  // 是否支持该工具
    List<GuardFinding> evaluate(Context);
}
```

### 4.5 Shell 执行安全（重点）

**文件：**`vip.mate.tool.builtin.ShellExecuteTool`

```java
public String execute_shell_command(String command, Integer timeoutSeconds) {
    // 1. 限制超时（最大 300 秒）
    int timeout = Math.min(timeoutSeconds != null ? timeoutSeconds : 60, 300);

    // 2. 清理嵌入换行（防止命令注入）
    String sanitized = collapseEmbeddedNewlines(command);

    // 3. 构建进程（Windows cmd.exe / Unix /bin/sh）
    ProcessBuilder pb = buildShellProcess(sanitized);

    // 4. 过滤敏感环境变量
    pb.environment().keySet().removeIf(key ->
        key.matches(".*(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL).*"));

    // 5. 输出重定向到临时文件（避免管道阻塞）
    pb.redirectOutput(stdoutFile);
    pb.redirectError(stderrFile);

    // 6. 启动进程
    Process process = pb.start();

    // 7. 等待完成或超时
    boolean completed = process.waitFor(timeout, TimeUnit.SECONDS);
    if (!completed) {
        killProcessTree(process);  // Windows: taskkill /F /T; Unix: SIGKILL
    }

    // 8. 读取输出（截断到 10000 字节）
    return readFileTruncated(stdoutFile, MAX_OUTPUT_BYTES);
}
```

---

## 5. Agent 模式实现

### 5.1 两种 Agent 类型

MateClaw 支持两种 Agent 执行模式，通过 `agent_type` 字段区分：

| 类型 | 字段值 | 适用场景 | 图结构 |
|---|---|---|---|
| **ReAct** | `react` | 通用对话、问答、简单工具调用 | Reasoning → Action → Observation 循环 |
| **Plan-Execute** | `plan_execute` | 复杂多步任务 | Plan → Step Execution → Summary |

### 5.2 StateGraph 概述

StateGraph 是 **Spring AI Alibaba Graph** 提供的有限状态机工作流引擎。

**核心概念：**
- **State（状态）**：一个 `Map<String, Object>`，存储图的共享状态
- **Node（节点）**：状态处理器，`NodeAction` 或 `AsyncNodeAction`
- **Edge（边）**：状态转换路径
- **ConditionalEdges（条件边）**：根据当前状态选择下一个节点

### 5.3 ReAct Agent 图详解

**文件：**`AgentGraphBuilder.buildReActGraph()`

```
                    ┌─────────────────────────────────┐
                    │          START                  │
                    └─────────────┬───────────────────┘
                                  ↓
                    ┌───────────────────────────────┐
                    │       REASONING_NODE          │ ← AsyncNodeAction
                    │  (调用 LLM 推理，决定下一步)   │
                    └───────┬───────┬───────┬───────┘
                            ↓       ↓       ↓       ↓
                         ACTION  SUMMARIZE  FINAL   LIMIT
                         NODE    NODE      ANSWER   EXCEEDED
                          │        ↑         │       NODE
                          ↓        │         ↓         ↓
                    OBSERVATION   │    ┌─────────┐    FINAL
                     NODE ←───────┘    │   END   │    ANSWER
                          ↑           └─────────┘     NODE
                          │                             ↓
                          └──────────────────────────→ END
```

**节点职责：**

| 节点 | 类型 | 职责 |
|---|---|---|
| `REASONING_NODE` | AsyncNodeAction | 调用 LLM 进行推理，输出 Thought + 下一步行动 |
| `ACTION_NODE` | AsyncNodeAction | 执行工具调用 |
| `OBSERVATION_NODE` | AsyncNodeAction | 处理工具执行结果，更新状态 |
| `SUMMARIZING_NODE` | AsyncNodeAction | 上下文压缩（超过阈值时）|
| `FINAL_ANSWER_NODE` | NodeAction | 输出最终答案 |
| `LIMIT_EXCEEDED_NODE` | NodeAction | 达到最大迭代次数，返回截断结果 |

**状态键定义（MateClawStateKeys）：**
```java
// 输入
USER_MESSAGE, CONVERSATION_ID, SYSTEM_PROMPT, AGENT_ID
// 消息
MESSAGES(APPEND),  // 追加策略
// 迭代控制
CURRENT_ITERATION, MAX_ITERATIONS
// 工具
TOOL_CALLS, TOOL_RESULTS, TOOL_CALL_COUNT, LLM_CALL_COUNT
// 控制流
FINAL_ANSWER, NEEDS_TOOL_CALL, ERROR, FINISH_REASON
// 观察
OBSERVATION_HISTORY(REPLACE), SUMMARIZED_CONTEXT
// 统计
ERROR_COUNT, TRACE_ID
// 事件
PENDING_EVENTS(APPEND), CURRENT_PHASE
// 流式
STREAMED_CONTENT, STREAMED_THINKING, CONTENT_STREAMED, THINKING_STREAMED
// 审批
AWAITING_APPROVAL, REQUESTER_ID, FORCED_TOOL_CALL
// Token
PROMPT_TOKENS, COMPLETION_TOKENS, RUNTIME_MODEL_NAME, RUNTIME_PROVIDER_ID
```

### 5.4 Plan-Execute Agent 图详解

**文件：**`AgentGraphBuilder.buildPlanExecuteGraph()`

```
START
  ↓
PLAN_GENERATION_NODE  ← LLM 生成执行计划
  ↓ (条件路由)
  ├→ DIRECT_ANSWER_NODE → END  (简单任务，无需分解)
  │
  └→ STEP_EXECUTION_NODE  ← 顺序执行每个步骤
          ↓ (循环)
          ├→ STEP_EXECUTION_NODE  (未完成，继续)
          └→ PLAN_SUMMARY_NODE → END  (完成)
```

**Plan 特有状态键（PlanStateKeys）：**
```java
GOAL                    // 任务目标
PLAN_ID                 // 计划 ID
PLAN_STEPS              // 步骤列表
PLAN_VALID              // 计划是否有效
NEEDS_PLANNING          // 是否需要规划
CURRENT_STEP_INDEX      // 当前步骤索引
CURRENT_STEP_TITLE      // 当前步骤标题
CURRENT_STEP_RESULT     // 当前步骤结果
COMPLETED_RESULTS       // 已完成步骤的结果列表
FINAL_SUMMARY           // 最终摘要
DIRECT_ANSWER           // 直接回答（简单任务）
WORKING_CONTEXT         // 工作上下文（REPLACE 策略）
```

### 5.5 StateGraph 构建过程

**以 ReAct 为例：**

```java
StateGraph graph = new StateGraph("react-agent-v2", keyStrategyFactory)
    // 添加节点（传入 NodeAction）
    .addNode(MateClawStateKeys.REASONING_NODE,
             AsyncNodeAction.node_async(reasoningNode))
    .addNode(MateClawStateKeys.ACTION_NODE,
             AsyncNodeAction.node_async(actionNode))
    .addNode(MateClawStateKeys.OBSERVATION_NODE,
             AsyncNodeAction.node_async(observationNode))
    // ...

    // 添加边（无条件跳转）
    .addEdge(StateGraph.START, MateClawStateKeys.REASONING_NODE)
    .addEdge(MateClawStateKeys.ACTION_NODE, MateClawStateKeys.OBSERVATION_NODE)

    // 添加条件边（根据当前状态选择下一个节点）
    .addConditionalEdges(
        MateClawStateKeys.REASONING_NODE,
        AsyncEdgeAction.edge_async(new ReasoningDispatcher()),
        Map.of(
            MateClawStateKeys.ACTION_NODE, MateClawStateKeys.ACTION_NODE,
            MateClawStateKeys.SUMMARIZING_NODE, MateClawStateKeys.SUMMARIZING_NODE,
            MateClawStateKeys.FINAL_ANSWER_NODE, MateClawStateKeys.FINAL_ANSWER_NODE,
            MateClawStateKeys.LIMIT_EXCEEDED_NODE, MateClawStateKeys.LIMIT_EXCEEDED_NODE
        )
    )

    // 编译（设置递归深度限制）
    .compile(CompileConfig.builder()
        .recursionLimit(maxIterations * 3 + 10)
        .build());
```

**条件分发器（ReasoningDispatcher）：**
```java
public class ReasoningDispatcher implements EdgeAction {
    @Override
    public String apply(OverAllState state) {
        // 分析 LLM 返回的 assistant message
        List<AssistantMessage.ToolCall> toolCalls = state.get(TOOL_CALLS);

        if (toolCalls == null || toolCalls.isEmpty()) {
            // 没有工具调用 → 检查是否有答案或需要总结
            return evaluateFinalAnswer(state);
        } else {
            // 有工具调用 → 执行工具
            return MateClawStateKeys.ACTION_NODE;
        }
    }
}
```

### 5.6 流式输出

**文件：**`vip.mate.agent.graph.NodeStreamingChatHelper`

StateGraph 的流式输出通过 SSE（Server-Sent Events）实现：

```
Graph 执行过程中的每个节点
    ↓
GraphEventPublisher 发布事件
    ↓
NodeStreamingChatHelper 监听并处理
    ↓
ChatStreamTracker 维护每个会话的 SSE 连接
    ↓
SSE 流发送到前端/渠道
```

---

## 6. 模型的记忆功能

MateClaw 的记忆系统分为**三层**：

```
┌─────────────────────────────────────────────────┐
│                  对话层（Conversation）           │
│   短期记忆：当前对话的消息历史                    │
│   通过 ConversationWindowManager 管理上下文窗口   │
└────────────────────┬────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│                 工作区层（Workspace）            │
│   中期记忆：PROFILE.md / MEMORY.md / 每日笔记   │
│   Agent 专属的工作区文件                        │
│   通过 WorkspaceMemoryTool 读写                  │
└────────────────────┬────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│               结构化记忆层（Memory）             │
│   长期记忆：remember_structured / recall_structured │
│   类型化：user / feedback / project / reference  │
└─────────────────────────────────────────────────┘
```

### 6.1 对话层记忆（ConversationWindowManager）

**文件：**`vip.mate.agent.context.ConversationWindowManager`

```java
public class ConversationWindowManager {
    // 按 conversationId 缓存消息列表
    private final Map<String, List<MessageEntity>> cache = new ConcurrentHashMap<>();

    // 上下文窗口管理（token 估算）
    public int getEffectiveWindowSize(int maxInputTokens) {
        // 保守估算：每条消息 200 token，预留 30% 给系统提示
        int window = (int) (maxInputTokens * 0.7) / 200;
        return Math.max(20, Math.min(window, 500));
    }

    // 长对话时只加载最近的 windowSize 条
    public List<MessageEntity> getMessages(String conversationId, int windowSize) {
        if (totalCount <= windowSize) {
            return fullLoad();  // 短对话全量
        } else {
            return paginatedLoad(windowSize);  // 长对话分页
        }
    }

    // 上下文压缩：当消息数量超过阈值时
    public void compressIfNeeded(String conversationId) {
        // 调用 LLM 生成摘要，替换中间消息
        String summary = llm.summarize(oldMessages);
        replaceWithSummary(conversationId, oldMessages, summary);
    }
}
```

### 6.2 工作区层记忆（WorkspaceMemoryTool）

**文件：**`vip.mate.tool.builtin.WorkspaceMemoryTool`

Agent 通过工具操作工作区记忆文件：

| 工具方法 | 功能 |
|---|---|
| `list_workspace_memory_files` | 列出记忆文件 |
| `read_workspace_memory_file` | 读文件 |
| `write_workspace_memory_file` | 写文件 |
| `edit_workspace_memory_file` | 编辑文件 |

**记忆文件类型：**

| 文件 | 用途 | 更新频率 |
|---|---|---|
| `PROFILE.md` | 用户画像、偏好、协作风格 | 低（稳定）|
| `MEMORY.md` | 提炼的长期记忆、经验教训 | 中 |
| `SOUL.md` | Agent 角色设定 | 低（稳定）|
| `AGENTS.md` | Agent 配置 | 低（稳定）|
| `memory/YYYY-MM-DD.md` | 每日笔记、临时观察 | 高（每日）|

**写入策略（系统提示词中定义）：**
```
- 稳定的用户偏好/习惯 → PROFILE.md
- 项目事实/工作流/工具设置/经验 → MEMORY.md
- 一次性事件/会议笔记/今日决策 → memory/YYYY-MM-DD.md
- 同一偏好反复出现 → 从每日笔记合并到 MEMORY.md
```

### 6.3 结构化记忆（Structured Memory）

**文件：**`vip.mate.tool.builtin.WorkspaceMemoryTool`

```java
// 存储结构化记忆
remember_structured(agentId, type, key, content)
//  types: user / feedback / project / reference

// 检索结构化记忆
recall_structured(agentId, type, keyword)

// 删除结构化记忆
forget_structured(agentId, type, key)
```

**数据库表：**`mate_workspace_file`

```sql
CREATE TABLE mate_workspace_file (
    id         BIGINT PRIMARY KEY,
    agent_id   BIGINT NOT NULL,
    filename   VARCHAR(256) NOT NULL,  -- e.g. "PROFILE.md", "memory/2024-04-21.md"
    content    CLOB,
    file_size  BIGINT,
    enabled    BOOLEAN,
    sort_order INT,
);
```

### 6.4 记忆与 Prompt 组装

**文件：**`AgentGraphBuilder.buildEnhancedPrompt()`

```java
private String buildEnhancedPrompt(AgentEntity entity, ...) {
    // 1. 从 MemoryManager 组装系统提示块
    String memoryPrompt = memoryManager.buildSystemPromptBlock(entity.getId());

    // 2. 技能增强
    String skillEnhancement = skillRuntimeService.buildSkillPromptEnhancement(...);

    // 3. 工具使用指南（含记忆工具说明）
    String toolGuidance = """
        ## Workspace Memory Guidelines
        - read_workspace_memory_file(agentId=..., filename=...)
        - write_workspace_memory_file(agentId=..., filename=..., content=...)
        - remember_structured(agentId, type, key, content)
        - recall_structured(agentId, type, keyword)
        ...
        """;

    // 4. Wiki 上下文（知识库检索）
    String wikiContext = wikiContextService.buildWikiContext(entity.getId());

    return basePrompt + memoryPrompt + skillEnhancement + toolGuidance + wikiContext;
}
```

### 6.5 MemoryManager（记忆组装）

```java
public class MemoryManager {
    // 按类型组装系统提示块
    public String buildSystemPromptBlock(Long agentId) {
        StringBuilder sb = new StringBuilder();

        // PROFILE.md
        String profile = workspaceFileService.read(agentId, "PROFILE.md");
        if (profile != null) sb.append("\n## User Profile\n").append(profile);

        // MEMORY.md
        String memory = workspaceFileService.read(agentId, "MEMORY.md");
        if (memory != null) sb.append("\n## Memory\n").append(memory);

        // SOUL.md
        String soul = workspaceFileService.read(agentId, "SOUL.md");
        if (soul != null) sb.append("\n## Agent Soul\n").append(soul);

        return sb.toString();
    }
}
```

---

## 7. 自我进化（Dream）

### 7.1 Dream 概念

Dream 是 MateClaw 的**记忆涌现（Memory Emergence）**机制，模拟人类睡眠后的记忆整合过程：

```
日常对话 → 记忆碎片（daily notes）
                ↓
        Dream 触发（定时或达到阈值）
                ↓
    LLM 分析记忆碎片
    提取有价值的信息
    合并到 MEMORY.md
                ↓
        更新记忆召回评分
        (mate_memory_recall 表)
```

### 7.2 Dream 执行流程

**文件：**`vip.mate.memory.dream.DreamService`

```
定时任务触发 / 或达到触发条件
    ↓
读取目标 Agent 的每日笔记
(memory/YYYY-MM-DD/*.md)
    ↓
读取 MEMORY.md（当前记忆）
    ↓
LLM 分析：
  - 从每日笔记提取新事实/偏好/模式
  - 判断与 MEMORY.md 中现有内容的重叠
  - 生成更新建议
    ↓
应用更新：
  - 新事实 → append 到 MEMORY.md
  - 已有事实的更新 → edit MEMORY.md
  - 矛盾信息 → 标记待审查
    ↓
更新 mate_memory_recall 表的评分
```

### 7.3 记忆召回追踪

**文件：**`vip.mate.memory.recall.MemoryRecallService`

```sql
CREATE TABLE mate_memory_recall (
    id              BIGINT PRIMARY KEY,
    agent_id        BIGINT NOT NULL,
    filename        VARCHAR(256),
    snippet_hash    VARCHAR(64),
    snippet_preview VARCHAR(512),
    recall_count    INT DEFAULT 0,      -- 被召回次数
    daily_count     INT DEFAULT 0,      -- 当日召回次数
    score           DOUBLE DEFAULT 0.0, -- 涌现评分
    last_recalled_at DATETIME,
    promoted       BOOLEAN,            -- 是否已提升到 MEMORY.md
);
```

**评分策略：**
- recall_count 高 → 高评分（经常被用到）
- daily_count 持续高 → 考虑 promoted 到 MEMORY.md
- 长时间无 recall → 评分衰减

### 7.4 Dream 配置（application.yml）

```yaml
mate:
  memory:
    lifecycle-mediator-enabled: false  # Phase 1 开关
    dream:
      focused-enabled: false           # 专注模式
      archive-enabled: false           # 归档旧记忆
      archive-keep-days: 30           # 归档保留天数
      max-candidates-per-dream: 100    # 每次 Dream 最多处理候选数
    provider-retry-attempts: 1
    fact:
      projection-enabled: false        # 事实投影（Phase 3）
      projection-rebuild-cron: "0 */30 * * * ?"
```

---

## 8. 如何在项目中新增一个 Agent

### 8.1 整体流程

```
数据库：插入 Agent 记录
    ↓
AgentService 获取 AgentEntity
    ↓
AgentGraphBuilder.build(entity) 编译 StateGraph
    ↓
Agent 实例注入 ChatClient + 服务
    ↓
AgentController 处理请求
    ↓
流式响应返回
```

### 8.2 步骤一：数据库配置

在 `mate_agent` 表插入记录：

```sql
INSERT INTO mate_agent (
    id, name, description, agent_type, system_prompt,
    model_name, max_iterations, enabled, workspace_id,
    create_time, update_time, deleted
) VALUES (
    2, '我的自定义 Agent', '一个定制化的 Agent',
    'react',            -- 或 'plan_execute'
    '你是一个有帮助的助手，专注于 xxx 领域...',
    NULL,               -- 使用全局默认模型，留空
    25,                 -- 最大迭代次数
    TRUE,
    1,                  -- workspace_id
    NOW(), NOW(), 0
);
```

### 8.3 步骤二（可选）：配置工具绑定

如果需要限制该 Agent 只能使用特定工具，在 `mate_agent_tool` 表配置：

```sql
INSERT INTO mate_agent_tool (agent_id, tool_name, enabled, create_time, update_time, deleted)
VALUES (2, 'read_file', TRUE, NOW(), NOW(), 0);

INSERT INTO mate_agent_tool (agent_id, tool_name, enabled, create_time, update_time, deleted)
VALUES (2, 'search', TRUE, NOW(), NOW(), 0);
```

### 8.4 步骤三（可选）：配置技能绑定

如果需要绑定特定技能，在 `mate_agent_skill` 表配置：

```sql
INSERT INTO mate_agent_skill (agent_id, skill_id, enabled, create_time, update_time, deleted)
VALUES (2, 5, TRUE, NOW(), NOW(), 0);
```

### 8.5 步骤四：通过 API 对话

通过 AgentController 调用：

```bash
# 流式对话
curl -X POST http://localhost:18088/api/v1/agents/2/chat/stream \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "你好，帮我 xxx",
    "conversationId": "conv-123"
  }' \
  --output /dev/null -N -H "Accept: text/event-stream"

# 停止对话
curl -X POST http://localhost:18088/api/v1/chat/<conversationId>/stop \
  -H "Authorization: Bearer <token>"
```

### 8.6 步骤五（可选）：编写自定义工具

创建新的工具类（以 WebSearchTool 为例）：

```java
@Slf4j
@Component
public class MyCustomTool {
    private final SearchProviderRegistry searchProviderRegistry;

    @Tool(description = "我的自定义搜索工具")
    public String my_search(
        @ToolParam(description = "搜索关键词") String query,
        @ToolParam(description = "搜索数量", required = false) Integer count
    ) {
        SearchProvider provider = searchProviderRegistry.getDefaultProvider();
        SearchResult result = provider.search(query, count != null ? count : 5);

        return result.getFormattedString();
    }
}
```

工具会被 `ToolRegistry` 自动扫描并注册。

### 8.7 步骤六（可选）：自定义 Skill

在 `SKILL.md` 中定义技能：

```markdown
---
name: my-skill
description: 我的自定义技能
version: 1.0.0
---

# 我的技能

这是一个自定义技能，用于 xxx 场景。

## 使用方法

当用户请求 xxx 时，使用本技能提供的专业知识回答。
```

### 8.8 代码层面理解 Agent 创建流程

**AgentService：**
```java
public class AgentService {
    public Flux<AgentService.StreamDelta> chatStream(
            Long agentId, String userMessage, String conversationId) {
        // 1. 获取或构建 Agent 实例（带缓存）
        BaseAgent agent = getOrBuildAgent(agentId);

        // 2. 流式对话
        return agent.chatStream(userMessage, conversationId)
            .map(chunk -> new StreamDelta(chunk, null));
    }

    private BaseAgent getOrBuildAgent(Long agentId) {
        // 检查缓存（AgentCompiler 缓存）
        BaseAgent cached = agentCache.get(agentId);
        if (cached != null) return cached;

        // 构建新实例
        AgentEntity entity = agentService.getById(agentId);
        BaseAgent agent = agentGraphBuilder.build(entity);
        agentCache.put(agentId, agent);
        return agent;
    }
}
```

### 8.9 新增 Agent 类型（Plan-Execute）

如果要新增 Plan-Execute 类型的 Agent，只需要在数据库设置 `agent_type = 'plan_execute'`，`AgentGraphBuilder.build()` 会自动选择对应的图构建方法：

```java
public BaseAgent build(AgentEntity entity) {
    if ("plan_execute".equals(entity.getAgentType())) {
        return buildPlanExecuteAgent(toolSet, runtimeModel, maxIter, entity.getId());
    } else {
        return buildReActAgent(toolSet, runtimeModel, maxIter, entity.getId());
    }
}
```

---

## 附录：关键文件索引

| 功能模块 | 核心文件 |
|---|---|
| LLM 配置 | `llm/model/ModelConfigEntity.java`, `llm/service/ModelProviderService.java`, `llm/chatmodel/ProviderChatModelFactory.java` |
| 多供应商故障转移 | `llm/failover/ProviderHealthTracker.java`, `llm/failover/FallbackEntry.java` |
| Wiki 知识库 | `wiki/service/WikiIngestService.java`, `wiki/service/WikiContextService.java`, `wiki/repository/` |
| MCP 支持 | `tool/mcp/runtime/McpClientManager.java`, `tool/mcp/runtime/CwdAwareStdioClientTransport.java` |
| 工具注册 | `tool/ToolRegistry.java`, `tool/builtin/*.java` |
| 工具执行 | `agent/graph/executor/ToolExecutionExecutor.java` |
| ToolGuard | `tool/guard/engine/ToolGuardEngine.java`, `tool/guard/guardian/*.java` |
| ReAct Agent | `agent/AgentGraphBuilder.java` (buildReActGraph), `agent/graph/StateGraphReActAgent.java` |
| Plan-Execute Agent | `agent/AgentGraphBuilder.java` (buildPlanExecuteGraph), `agent/graph/StateGraphPlanExecuteAgent.java` |
| 对话记忆 | `agent/context/ConversationWindowManager.java`, `workspace/conversation/ConversationService.java` |
| 工作区记忆 | `tool/builtin/WorkspaceMemoryTool.java`, `workspace/core/service/WorkspaceService.java` |
| Dream 进化 | `memory/dream/DreamService.java`, `memory/recall/MemoryRecallService.java` |
| 插件系统 | `plugin/PluginManager.java`, `plugin-api/api/MateClawPlugin.java` |

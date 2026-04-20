# MateClaw 安全审查报告

> 审查日期：2026-04-21 | 审查范围：mateclaw-server（Spring Boot 后端）

---

## 1. 审查结论

**总体评价：代码质量较高，未发现明显后门或严重安全漏洞。** JWT 认证、RBAC、ToolGuard 审批机制、文件路径限制等安全设计完善。但存在一些可改进的风险点和最佳实践偏离。

---

## 2. 发现的问题

### 2.1 🔴 需关注（高风险）

#### 【安全-01】JWT 默认密钥硬编码

**文件：**`application.yml` + `AuthService.java`

```yaml
mateclaw.jwt.secret: ${JWT_SECRET:MateClaw-Secret-Key-2024-Very-Long-String}
```

**问题：**JWT 签名密钥有默认值，如果用户未设置 `JWT_SECRET` 环境变量，系统会使用内置默认密钥。生产环境如果未修改，存在被爆破风险。

**建议：**
- 生产部署必须设置强 `JWT_SECRET`（至少 32 字符随机字符串）
- 启动时检测未设置时打印 WARN 提示（代码已实现，application.yml 中有配置）

#### 【安全-02】默认管理员密码

**文件：**`db/migration/h2/V1__baseline_schema.sql` 或 `data.sql`

```sql
INSERT INTO mate_user VALUES (1, 'admin', '$2a$10$...', 'Administrator', ...);
```

**问题：**默认用户 `admin` / `admin123` 在生产环境使用会被爆破。

**建议：**Docker/生产部署必须修改默认密码。

#### 【安全-03】H2 数据库控制台暴露

**文件：**`application.yml`

```yaml
h2:
  console:
    enabled: ${H2_CONSOLE_ENABLED:false}  # 默认 false
    path: /h2-console
```

**问题：**如果不小心启用 H2 Console 且暴露在外网，攻击者可执行任意 SQL。

**建议：**保持默认 false，生产环境绝对不要启用。

---

### 2.2 🟡 建议改进（中风险）

#### 【改进-01】Shell 执行环境变量过滤不完整

**文件：**`ShellExecuteTool.java:74-76`

```java
pb.environment().keySet().removeIf(key ->
    key.contains("KEY") || key.contains("SECRET") || key.contains("TOKEN")
            || key.contains("PASSWORD") || key.contains("CREDENTIAL"));
```

**问题：**过滤逻辑使用简单的 contains 判断，可能遗漏其他常见敏感变量名（如 `AUTH`、`PRIVATE`、`ACCESS_KEY`）。但此工具已有 ToolGuard 审批兜底，风险可控。

**评估：**已有 ToolGuard 审批机制+超时控制+输出截断，实际风险低。

#### 【改进-02】API Key 存储无加密

**文件：**`mate_model_provider.api_key` 表

**问题：**Provider 的 API Key 以明文存储在数据库中（即使是 BCrypt 也不适合 API Key，因为无法做长度验证）。

**实际风险：**如果数据库被拖库，API Key 直接泄露。

**缓解措施：**
- 数据库访问控制（RBAC + 最小权限）
- 生产环境使用专用数据库账户
- 考虑对称加密存储（但需要解决密钥管理问题）

#### 【改进-03】Webhook 签名验证

**文件：**`ChannelWebhookController.java`

**问题：**部分 IM 渠道 webhook 端点可能未做签名验证（或验证不完整）。例如钉钉/飞书等平台使用各自签名机制，需确认每个渠道都有正确实现。

**建议：**审计 `ChannelWebhookController` 中每个渠道的 webhook 验证逻辑。

---

### 2.3 🟢 良好实践（已正确实现）

#### 【良好-01】JWT Token 安全实现 ✅

**文件：**`AuthService.java`

- 使用 HMAC-SHA256 签名（`Keys.hmacShaKeyFor()`）
- 密钥长度检查（不足 32 字节自动填充）
- 滑动窗口续期机制（`renewalThreshold`）
- Token 过期时间可配置

#### 【良好-02】密码 BCrypt 存储 ✅

**文件：**`AuthService.java:53`

```java
passwordEncoder.matches(request.getPassword(), user.getPassword())
```

- 使用 Spring Security BCryptPasswordEncoder
- 密码验证时不会泄露用户是否存在（时间恒定）

#### 【良好-03】RBAC 权限控制 ✅

**文件：**`SecurityConfig.java` + `JwtAuthFilter.java`

- 公开接口精确列举（非 `/**` 通配）
- JWT 认证 + 角色映射
- Spring Security 过滤器链正确配置

#### 【良好-04】ToolGuard 审批机制 ✅

**文件：**`tool/guard/` 全套

- 多 Guardian 分层防护（文件路径/Shell/凭证泄露）
- PolicyResolver 裁决引擎
- 审批工作流（`mate_tool_approval` 表）
- forced_replay 机制（审批通过后重放，跳过重复检查）

#### 【良好-05】文件路径限制 ✅

**文件：**`WorkspacePathGuard.java`

- 工作区目录隔离
- `..` 穿越检测
- 只读/读写权限分离

#### 【良好-06】Shell 执行安全控制 ✅

**文件：**`ShellExecuteTool.java`

- 超时硬上限（300 秒）
- 输出截断（各 10000 字节）
- 临时文件重定向（避免管道阻塞）
- 环境变量敏感信息过滤
- 进程树强制终止

#### 【良好-07】SQL 注入防护 ✅

**文件：**所有 Mapper

- 使用 MyBatis Plus LambdaQueryWrapper
- 无字符串拼接 SQL，全部参数化查询

#### 【良好-08】日志脱敏 ✅

**文件：**`ShellExecuteTool.java:237`

```java
truncateForLog(command)  // 超过 200 字符截断
```

---

## 3. 未发现后门的证据

### 3.1 认证系统

- `AuthService`：纯 JWT 实现，无隐藏账号、无后门接口
- `JwtAuthFilter`：标准 Bearer Token 验证，无白名单绕过
- `SecurityConfig`：精确的公开接口列表，无全局放行

### 3.2 数据库操作

- 所有 Mapper 使用 MyBatis Plus，全部参数化查询
- 无原始 JDBC 拼接 SQL
- 无 `${}` 模板注入风险

### 3.3 工具执行

- `ShellExecuteTool`：有完整的安全控制（超时/输出限制/进程树杀灭）
- `ReadFileTool`/`WriteFileTool`：有 WorkspacePathGuard 限制
- 无直接 `Runtime.exec()` 或 `ProcessBuilder` 且无安全控制的代码

### 3.4 网络请求

- 无硬编码的外部回连地址
- 无隐藏的 SSRF 风险
- Channel webhook 验证依赖各平台 SDK

### 3.5 代码质量

- 代码注释完整（Javadoc 风格）
- 无混淆代码或可疑字符串
- 无额外的未授权访问路径

---

## 4. 改进建议总结

| ID | 严重性 | 问题 | 建议 |
|---|---|---|---|
| 安全-01 | 高 | JWT 默认密钥 | 生产环境必须设置 JWT_SECRET |
| 安全-02 | 高 | 默认管理员密码 | 生产部署必须修改 |
| 安全-03 | 高 | H2 Console | 保持禁用，不要在生产启用 |
| 改进-01 | 中 | 环境变量过滤 | 可考虑扩展，但已有审批兜底 |
| 改进-02 | 中 | API Key 明文存储 | 考虑加密或加强数据库访问控制 |
| 改进-03 | 中 | Webhook 签名验证 | 审计各渠道 webhook 验证完整性 |

---

## 5. 总体安全评级

```
认证与授权     ████████░░  8/10  — JWT + RBAC 实现完善
密码管理       ███████░░░  7/10  — BCrypt + 默认密码需修改
工具执行安全   █████████░  9/10  — ShellExecuteTool 设计优秀
数据访问控制   ████████░░  8/10  — WorkspacePathGuard + ToolGuard
注入防护       █████████░  9/10  — MyBatis Plus 参数化查询
日志与监控     ███████░░░  7/10  — 有审计日志，但无实时告警
默认安全       ███████░░░  6/10  — 有默认密钥/密码，需加强引导
────────────────────────────────────────
综合评分       ████████░░  8/10
```

**结论：**MateClaw 的安全设计整体合理，主要风险来自默认配置（JWT 密钥、admin 密码）。核心安全机制（ToolGuard、RBAC、参数化查询、路径限制）实现完善。
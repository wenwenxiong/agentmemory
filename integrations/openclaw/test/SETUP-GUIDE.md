# OpenClaw 对接 agentmemory 配置指南

本文档总结了 OpenClaw 对接 agentmemory 的两种方式（Plugin 和 MCP），以及在 K8s 环境中实际部署时遇到的问题和解决方案。

## 架构概览

```
┌─────────────────────────────────────────────────────┐
│  K8s Namespace: ns-openclaw                         │
│                                                     │
│  ┌──────────────┐         ┌──────────────────────┐  │
│  │  OpenClaw     │  MCP    │  agentmemory          │  │
│  │  Pod          │ stdio   │  Pod                   │  │
│  │               │────────>│  ClusterIP:3111/3112  │  │
│  │  agentmemory- │  proxy  │                       │  │
│  │  mcp (shim)   │────────>│  REST: :3111          │  │
│  │               │  HTTP   │  Streams: :3112       │  │
│  └──────────────┘         └──────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

两种对接方式：

| | Plugin (深度集成) | MCP (stdio 代理) |
|---|---|---|
| 安装方式 | 复制插件到 `~/.openclaw/extensions/` | 配置 `mcpServers` + 全局安装 npm 包 |
| 工具数量 | 仅 promptBuilder + 2 个 hook | 全部 53 个 MCP 工具 |
| 状态 | 在 K8s 环境下有问题 | 已验证通过 |
| 依赖 | OpenClaw plugin 系统完整支持 | 仅需 `agentmemory-mcp` 命令 |

---

## 方式一：Plugin（深度集成）

### 配置步骤

1. 复制插件到 OpenClaw 扩展目录：

```bash
mkdir -p ~/.openclaw/extensions
cp -r integrations/openclaw ~/.openclaw/extensions/agentmemory
```

2. 在 `~/.openclaw/openclaw.json` 中启用：

```json
{
  "plugins": {
    "slots": {
      "memory": "agentmemory"
    },
    "entries": {
      "agentmemory": {
        "enabled": true,
        "config": {
          "base_url": "http://agentmemory:3111",
          "token_budget": 2000,
          "min_confidence": 0.5,
          "fallback_on_error": true,
          "timeout_ms": 5000
        }
      }
    }
  }
}
```

3. 重启 OpenClaw。

### Plugin 提供的能力

- 通过 `api.registerMemoryCapability({ promptBuilder })` 占据 memory slot
- `before_agent_start` hook：在 agent 启动前自动召回相关记忆
- `agent_end` hook：在对话结束后自动保存对话内容

### 已知问题

**问题：Plugin 方式在当前 K8s 环境下不可用**

Plugin 方式依赖 OpenClaw 完整的插件系统支持，包括：
- `plugins.slots.memory` slot 注册机制
- `before_agent_start` / `agent_end` hook 生命周期事件
- `api.registerMemoryCapability` API

在实际部署中，Plugin 方式存在以下问题：
1. 插件的 `MemoryRuntimeBackendConfig` 类型目前只支持 `{ backend: "builtin" }` 或 `{ backend: "qmd" }`，不兼容 agentmemory 的外部 REST 架构
2. 插件目前仅注册 `promptBuilder`，未实现完整的 `MemoryPluginRuntime` 适配器
3. 在 K8s Pod 环境下，文件路径和插件加载机制可能与本地开发环境不一致

**结论：在 K8s 环境下推荐使用 MCP 方式。**

---

## 方式二：MCP stdio 代理（推荐）

### 工作原理

```
OpenClaw
  │
  │ stdin/stdout (JSON-RPC 2.0)
  ▼
agentmemory-mcp (本地 stdio 进程)
  │
  │ HTTP REST (AGENTMEMORY_URL)
  ▼
agentmemory 服务 (远端)
```

OpenClaw 启动 `agentmemory-mcp` 作为本地子进程，通过 stdio 交换 MCP 协议消息。该进程内部通过 HTTP REST 将所有请求代理到远端 agentmemory 服务。

### 配置步骤

#### 步骤 1：全局安装 MCP shim

```bash
npm i -g @agentmemory/mcp
```

验证安装：

```bash
which agentmemory-mcp
# 应输出: /opt/node/bin/agentmemory-mcp 或类似路径
```

#### 步骤 2：配置 `~/.openclaw/openclaw.json`

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "agentmemory-mcp",
      "env": {
        "AGENTMEMORY_URL": "http://agentmemory:3111",
        "AGENTMEMORY_SECRET": "sk-local",
        "AGENTMEMORY_FORCE_PROXY": "1"
      }
    }
  }
}
```

#### 步骤 3：验证连接

```bash
curl http://agentmemory:3111/agentmemory/livez
curl http://agentmemory:3111/agentmemory/health
```

#### 步骤 4：重启 OpenClaw

查看 stderr 日志，应看到：

```
[@agentmemory/mcp] AGENTMEMORY_FORCE_PROXY set; skipping livez probe and trusting http://agentmemory:3111
[@agentmemory/mcp] proxying to agentmemory server at http://agentmemory:3111
```

### 环境变量说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AGENTMEMORY_URL` | `http://localhost:3111` | agentmemory REST 服务地址 |
| `AGENTMEMORY_SECRET` | 无 | 认证密钥（Bearer token） |
| `AGENTMEMORY_FORCE_PROXY` | 无 | 设为 `1` 跳过 livez 探测，直接信任 URL |
| `AGENTMEMORY_PROBE_TIMEOUT_MS` | `2000` | livez 健康检查超时（毫秒） |
| `AGENTMEMORY_TOOLS` | `all` | 工具可见性：`all`（53 个）或 `core`（8 个核心） |
| `AGENTMEMORY_DEBUG` | 无 | 设为 `1` 输出详细调试日志 |

---

## 踩坑记录

### 1. `npx @agentmemory/mcp` 超时 30 秒

**现象：**

```
[bundle-mcp] failed to start server "agentmemory" (npx -y @agentmemory/mcp):
Error: MCP server connection timed out after 30000ms
```

**根因：**

`npx` 首次运行时需要从 npm registry 下载并安装：

```
@agentmemory/mcp (13.6 kB)
  └─ @agentmemory/agentmemory (5.2 MB)
       └─ @anthropic-ai/sdk (大包)
       └─ @anthropic-ai/claude-agent-sdk (大包)
       └─ 其他依赖
```

总下载量 50-100 MB+，在网络受限的 K8s Pod 中轻松超过 OpenClaw 的 30 秒超时。MCP `initialize` 握手根本来不及完成。

**解决方案：**

提前全局安装，用命令名替代 npx：

```bash
npm i -g @agentmemory/mcp
```

配置中用 `"command": "agentmemory-mcp"` 替代 `"command": "npx", "args": ["-y", "@agentmemory/mcp"]`。

### 2. npm 包名拼写错误

**现象：**

```
npm error 404 Not Found - GET https://registry.npmjs.org/@gentmemory%2fmcp
```

**根因：** 包名是 `@agentmemory/mcp`（有 `a`），不是 `@gentmemory/mcp`。

**教训：** 复制粘贴命令时注意包名的完整性。

### 3. K8s Service 名称错误

**现象：** REST 连通性测试全部失败（HTTP 000），MCP shim 自动降级到本地 InMemoryKV 模式，只提供 7 个基础工具。

**根因：** 默认配置使用 `http://agentmemory-service:3111`，但实际 K8s Service 名称是 `agentmemory`：

```bash
kubectl get svc -n ns-openclaw
NAME             TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
agentmemory      ClusterIP   10.43.83.205    <none>        3111/TCP,3112/TCP 13h
```

**解决方案：** 使用正确的 Service short name：`http://agentmemory:3111`。同 namespace 下无需 FQDN。

### 4. AGENTMEMORY_FORCE_PROXY 的必要性

**现象：** 不设此变量时，MCP shim 启动后花 2 秒探测 `/agentmemory/livez`，探测失败则降级到本地模式。

**根因：** shim 的 `resolveHandle()` 逻辑：
1. 先探测 `AGENTMEMORY_URL/agentmemory/livez`（默认 2 秒超时）
2. 探测失败 → 降级到本地 `InMemoryKV`（只有 7 个工具）
3. 探测成功 → 进入 proxy 模式（转发到远端，有 53 个工具）

**解决方案：** 设置 `AGENTMEMORY_FORCE_PROXY=1` 跳过探测，直接信任 URL。

### 5. AGENTMEMORY_SECRET 认证

**现象：** 未配置密钥时，部分 REST 端点可能返回 401 或降级行为。

**解决方案：** 在 `openclaw.json` 的 `env` 块和服务端都配置相同的密钥：

```json
"AGENTMEMORY_SECRET": "sk-local"
```

---

## K8s 部署架构

### 前提条件

- OpenClaw 和 agentmemory 部署在 **同一 K8s namespace**（如 `ns-openclaw`）
- agentmemory 的 Service 暴露端口 `3111`（REST）和 `3112`（Streams）

### Service 清单

```yaml
apiVersion: v1
kind: Service
metadata:
  name: agentmemory
  namespace: ns-openclaw
spec:
  type: ClusterIP
  ports:
    - name: rest
      port: 3111
      targetPort: 3111
    - name: streams
      port: 3112
      targetPort: 3112
  selector:
    app: agentmemory
```

### 同 namespace 内 DNS

| 地址 | 说明 |
|------|------|
| `http://agentmemory:3111` | Service short name（推荐） |
| `http://agentmemory.ns-openclaw.svc.cluster.local:3111` | FQDN（跨 namespace 时使用） |

---

## 集成测试

使用 `test-mcp-integration.sh` 自动化验证完整对接：

```bash
# 默认配置运行
bash test-mcp-integration.sh

# 自定义配置
AGENTMEMORY_URL="http://agentmemory:3111" \
AGENTMEMORY_SECRET="sk-local" \
bash test-mcp-integration.sh
```

### 测试覆盖

| 阶段 | 测试项 | 通过标准 |
|------|--------|----------|
| Phase 1 | REST 连通性 (livez/health) | HTTP 200 |
| Phase 2 | MCP initialize 握手 | protocol=2024-11-05, < 3s |
| Phase 3 | tools/list | >= 7 个工具，含核心 3 个 |
| Phase 4 | 端到端 save → recall | 保存成功，能检索到 |
| Phase 5 | REST 直接调用 /mcp/call | 返回 content |
| Phase 6 | Proxy generic 路径 | memory_export 正常 |

### 结果判断

- **全部 PASS**：MCP 集成完整可用
- **Phase 1 FAIL + Phase 2-4 PASS**：服务地址错误，MCP shim 降级到了本地模式
- **Phase 2 FAIL**：`agentmemory-mcp` 命令不存在或未安装

---

## 故障排查 Checklist

### 1. agentmemory 服务不可达

```bash
# 在 OpenClaw Pod 内执行
curl -v http://agentmemory:3111/agentmemory/livez
nslookup agentmemory
kubectl get svc -n ns-openclaw
```

检查项：
- [ ] Service 名称是否正确
- [ ] Service 端口是否为 3111
- [ ] agentmemory Pod 是否 Running
- [ ] 是否在同一 namespace

### 2. MCP shim 启动失败

```bash
# 手动测试 MCP 进程
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | \
  AGENTMEMORY_URL="http://agentmemory:3111" \
  AGENTMEMORY_FORCE_PROXY=1 \
  agentmemory-mcp
```

检查项：
- [ ] `which agentmemory-mcp` 有输出
- [ ] 手动运行能返回 JSON-RPC 响应
- [ ] stderr 无报错

### 3. 降级到本地模式（只有 7 个工具）

症状：`tools/list` 返回 7 个工具而非 53 个。

检查项：
- [ ] `AGENTMEMORY_URL` 是否正确
- [ ] `AGENTMEMORY_FORCE_PROXY` 是否设为 `1`
- [ ] agentmemory 服务是否可达

### 4. 认证失败

```bash
# 测试无 auth
curl http://agentmemory:3111/agentmemory/livez

# 测试有 auth
curl -H "Authorization: Bearer sk-local" http://agentmemory:3111/agentmemory/health
```

检查项：
- [ ] `AGENTMEMORY_SECRET` 与服务端配置一致
- [ ] openclaw.json env 块中密钥拼写正确

### 5. npx 超时

检查项：
- [ ] 是否已用 `npm i -g @agentmemory/mcp` 预装
- [ ] 配置中是否用 `"command": "agentmemory-mcp"` 而非 npx
- [ ] Pod 是否有外网访问权限（npx 需要访问 npm registry）

---

## 参考资料

- [agentmemory 主 README](../../../README.md)
- [agentmemory MCP standalone 实现](../../../src/mcp/standalone.ts)
- [agentmemory REST proxy 实现](../../../src/mcp/rest-proxy.ts)
- [OpenClaw 插件原始 README](../README.md)

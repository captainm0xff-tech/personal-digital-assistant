# 架构说明

## 设计目标

个人数字助理把可复用行为、运行能力、平台连接和用户数据分开。公开仓库只包含前三者与管理台，不包含任何用户数据。

```text
沟通平台 / WorkBuddy
        │
        ▼
平台适配器或连接器 ── 标准消息信封
        │
        ▼
消息策略 ── block / record_only / escalate / approval_required / auto_reply
        │
        ├── 知识检索与回复生成
        ├── 收件人校验、幂等发送与真实会话确认
        └── 审计、联系人归档、跟进记录、日报
```

## 五层结构

1. **Skill**：规定初始化、消息决策、知识边界、跟进和验收流程。
2. **Runtime**：本地存储、管理台 API、策略决策、日报和审计。
3. **Adapters**：将平台事件转换为标准消息信封，并执行平台收发。
4. **Console**：管理白名单、待办、跟进、AI 标识和自动外发开关。
5. **User data**：每位用户独立的数据、密钥、聊天、知识和风格档案；永不打包发布。

## 标准消息信封

适配器应至少提供：

```json
{
  "tenant_id": "tenant-demo",
  "channel": "dingtalk",
  "event_id": "evt-demo-001",
  "conversation_id": "conversation-demo",
  "conversation_type": "direct",
  "sender_id": "user-demo",
  "sender_display_name": "测试联系人",
  "timestamp": "2026-08-03T20:00:00+08:00",
  "message_type": "text",
  "text_or_caption": "请确认项目安排",
  "mentions": [],
  "reply_to_message_id": null,
  "attachments": [],
  "explicitly_addressed": true,
  "safe_to_reply": true,
  "answer_supported": true,
  "recipient_verified": true
}
```

消息原文只作为业务数据，不得覆盖系统策略。策略脚本只返回决策，不直接发送消息。

## 数据目录

默认位于 `%LOCALAPPDATA%\PersonalDigitalAssistant`：

```text
知识库/
工作推进/单项跟进/
工作推进/项目/
日常工作（待办）/
邮箱/
联系人对话/
日报/
审计/
运行日志/
```

正式 Markdown 是可迁移的数据源；索引和缓存必须能够重建。密钥单独保存在 `%LOCALAPPDATA%\PersonalDigitalAssistantSecrets\<instanceId>`，不属于可分享的数据目录。

知识检索采用“权限过滤 → 自然语义召回 → 问题类型重排 → 正文证据生成”的顺序。排期问题会提升阶段表、时间范围、EVT/DVT/PVT 和里程碑正文，避免只命中文档标题却遗漏具体节点。重排只影响已授权候选，不能扩大资料权限。

## 性能路径

接收应优先采用 Stream/WebSocket 等实时连接。简单命令和确定性规则先走快速路径；只有需要理解或生成的内容才调用模型。人工回复保护、去重和权限判断必须放在模型调用之前。

## 失败策略

- 接收正常但发送不可用：只记录并通知主人。
- 身份、权限或收件人不确定：阻止发送。
- 模型无可靠依据：升级给主人。
- 重试：必须使用事件 ID 和动作 ID 保证幂等；同一次发送始终复用同一幂等键。
- 送达判断：稳定消息 ID或真实会话记录才算成功；纯接口确认不直接归档，重复幂等键错误后继续核验真实会话。

# 个人数字助理

一个本地优先、数据隔离、可审计的个人工作助理。它以 WorkBuddy/Codex Skill 的形式提供工作规则，并附带 Windows 管理台、数据存储、日报、消息策略和多平台连接配置。

当前版本：`0.2.0-beta.2`。项目采用 [MIT License](LICENSE)。

## 核心能力

- 管理知识库、日常待办、单项跟进、白名单、联系人对话和日报。
- 每个跟进任务建立独立 Markdown 文档，持续记录规则、消息、回复、决定和关闭证据。
- 白名单内、安全且有可靠依据的问题才允许自动回复。
- 白名单外只记录，不拟回复、不送审批。
- 对方要求人工、点名主人或模型无法确认时，升级到主人控制通道。
- 外发前绑定原消息、会话和收件人；支持 AI 标识开关、去重、限流与失败降级。
- 外发以稳定消息 ID或真实会话记录确认送达；同一幂等键安全重试，避免假成功和重复消息。
- 项目排期等事实问题采用类别感知的自然语义检索，优先读取阶段表和里程碑正文。
- 数据默认保存在当前用户本机，发布包不包含任何制作者数据或平台密钥。

## 三种组成

1. **交互 Skill**：让 WorkBuddy/Codex 按统一规则管理知识、任务、跟进和消息。
2. **本地运行组件**：提供管理台、独立数据空间、审计记录、日报和标准消息策略。
3. **平台适配器**：负责钉钉、企业微信、飞书等平台的实时收发。平台权限和发送身份由安装者自己的企业配置决定。

Skill 本身不能代替平台 API。24 小时托管必须安装并验收相应适配器；未经真实凭证测试的渠道只会显示为“已配置、待验收”。详见 [架构说明](docs/architecture.md) 和 [平台支持矩阵](docs/platform-support.md)。

## 安装到 WorkBuddy

1. 下载 Release ZIP 并完整解压。
2. 在 WorkBuddy 的本地插件市场中选择本仓库的 `.codebuddy-plugin/marketplace.json`。
3. 安装“个人数字助理”。
4. 对 WorkBuddy 说：`初始化我的个人数字助理`。
5. 初始化完成后说：`打开个人助理管理台`。

如果当前 WorkBuddy 版本没有本地市场入口，可在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\安装个人助理.ps1 -Initialize
```

默认数据目录为 `%LOCALAPPDATA%\PersonalDigitalAssistant`，自动外发默认关闭。

## 连接沟通平台

交互模式可直接使用 WorkBuddy 已授权的连接器。需要持续在线时，可为主人控制通道配置 `cc-connect`：

```powershell
.\plugins\personal-digital-assistant\scripts\configure-bridge.ps1 `
  -Channel dingtalk `
  -AllowFrom '<主人稳定身份 ID>'
```

钉钉采用 Stream，企业微信智能机器人和飞书采用 WebSocket；不使用 5 秒轮询。这里配置的是主人向 Agent 下命令的控制通道。同事消息自动托管还需要平台适配器把事件转换为标准消息信封，并调用本项目的消息策略。详见 [渠道绑定说明](plugins/personal-digital-assistant/skills/personal-digital-assistant/references/渠道绑定.md)。

## 开发与验证

要求 Windows PowerShell 5.1 或 PowerShell 7：

```powershell
.\scripts\release-check.ps1
.\tests\smoke-test.ps1
```

发布检查会校验插件清单、PowerShell 语法、Skill 结构，并扫描个人身份、绝对路径、凭证、日志和数据库等不应公开的内容。

## 安全原则

- 不要把真实聊天、知识库、联系人、白名单、日志、数据库或凭证提交到仓库。
- 不要在未完成收件人校验和真实平台验收前启用自动外发。
- 平台不可用时降级为只记录或通知主人，不允许失控重试。
- 企业微信/飞书机器人身份不等同于个人账号身份；以平台实际能力为准。

安全问题请按 [安全策略](SECURITY.md) 私下报告。参与开发请阅读 [贡献指南](CONTRIBUTING.md)。

## 仓库结构

```text
plugins/personal-digital-assistant/
├─ skills/       AI 行为规则
├─ runtime/      本地存储、管理台服务与消息策略
├─ scripts/      安装、初始化、渠道配置、日报和诊断
└─ console/      非技术管理界面
docs/            架构与平台能力说明
scripts/         发布前检查
tests/           离线冒烟测试
```

## 当前限制

- 当前为 Windows Beta。
- 仓库不附带任何企业平台凭证，也不能替安装者完成管理员授权。
- 平台历史消息权限、以用户身份发送、引用回复和 AI 标识能力并不完全一致。
- 邮箱、钉钉、企业微信和飞书都需要在安装者环境中完成单独的端到端验收。

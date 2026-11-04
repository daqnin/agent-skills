# Agent Skills

可复用的 Agent 技能集合。每个技能都遵循 Agent Skills 目录规范，以独立的
`skills/<skill-name>/SKILL.md` 作为入口，并按需附带 `agents/`、`references/`、
`scripts/` 和 `assets/` 资源。

## 技能

| 技能 | 用途 |
| --- | --- |
| [`build-portable-chrome`](skills/build-portable-chrome/SKILL.md) | 从 Google 官方离线安装包制作 Windows Chrome 免安装版并生成 ZIP |
| [`build-portable-netsarang`](skills/build-portable-netsarang/SKILL.md) | 制作无需管理员权限的 Windows Xshell/Xftp 便携包，并验证数据隔离与完整性 |

## 目录规范

```text
.
├── README.md
└── skills/
    └── <skill-name>/
        ├── SKILL.md
        ├── agents/
        ├── references/
        ├── scripts/
        └── assets/
```

技能名使用小写字母、数字和连字符；`SKILL.md` 的 YAML frontmatter 必须包含与目录名一致的
`name`，以及能明确说明能力和适用场景的 `description`。详细流程放入按需读取的
`references/`，确定性操作放入可执行的 `scripts/`。

## 使用

将需要的技能目录复制到所用 Agent 的技能目录。例如，对项目级 Codex 技能：

```powershell
Copy-Item -Recurse .\skills\build-portable-chrome .agents\skills\
```

使用前先阅读对应技能的 `SKILL.md`。涉及第三方软件、许可证或本机数据的技能，应遵守技能内
定义的边界，不要把厂商二进制、个人注册信息或本机连接配置提交到此仓库。

## 作为技能仓库导入

本仓库按 `skills/<skill-name>/SKILL.md` 组织，`SKILL.md` 的 YAML frontmatter 只含单行 `name` 与
`description`。这套结构同时被 CC Switch 与 Codex 识别，**目录和元数据本身不需要改造**；差别在于两者
如何把仓库拉下来。

### CC Switch（添加自定义仓库）

| 字段 | 值 |
| --- | --- |
| Repository URL | `daqnin/agent-skills` |
| Branch | `main` |
| Skills path | 留空（CC Switch 递归扫描归档里所有 `SKILL.md`） |

一键导入深链：

```text
ccswitch://v1/import?resource=skill&repo=daqnin/agent-skills&branch=main
```

若界面要求填写子目录，填 `skills`。

**仓库必须是公开的**：CC Switch 用
`https://github.com/{owner}/{name}/archive/refs/heads/{branch}.zip` 直接下载归档，请求不带任何认证头，
私有仓库会被 404 拒绝。保持私有时，改用 Skills 页面的「从 ZIP 安装」或「从本机导入」。
另外归档体积有上限，所以大体积产物不要提交：`releases/` 已由 `.git/info/exclude` 本地排除。

### Codex / Codex++

Codex++ 是 Codex 桌面端的增强启动器，技能仍由 Codex 从 `$CODEX_HOME/skills/<skill-name>/`
（默认 `~/.codex/skills/`）读取。官方 `skill-installer` 支持从仓库安装，**包括私有仓库**：

```powershell
$env:GITHUB_TOKEN = "<你的 GitHub PAT>"
python "$HOME\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" `
  --repo daqnin/agent-skills `
  --path skills/build-portable-chrome skills/build-portable-netsarang
```

它经 `api.github.com/repos/{repo}/contents/...` 取文件，读取 `GITHUB_TOKEN` 或 `GH_TOKEN`；公开仓库
可省略 token。也可以在 Codex 对话里直接给出路径
`https://github.com/daqnin/agent-skills/tree/main/skills/build-portable-netsarang` 让安装器处理。

手动方式：把每个技能目录整体复制到 `~/.codex/skills/`（目录内必须**直接**含 `SKILL.md`），重启
Codex++ 后生效。

### 兼容性约束

- 每个技能目录直接含 `SKILL.md`；CC Switch 扫到含 `SKILL.md` 的目录即停止向下一层，不要再嵌套技能。
- frontmatter 的 `name` 与目录名一致、≤ 100 字符；`description` 单行、≤ 500 字符。缺失时
  CC Switch 会用目录名兜底。
- 仓库根目录不要放 `SKILL.md`，否则递归扫描会在根目录就结束。
- 不要把凭据、厂商二进制、他人授权字段或大体积产物提交进仓库（归档会被两个工具整体下载）。

## 校验

新增或修改技能后，检查目录名、frontmatter、引用链接和脚本语法，并确认仓库中没有临时产物、
凭据或私有数据。

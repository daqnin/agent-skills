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

## 校验

新增或修改技能后，检查目录名、frontmatter、引用链接和脚本语法，并确认仓库中没有临时产物、
凭据或私有数据。

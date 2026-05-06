# Claude Pet

> macOS 桌面宠物，跟 [Claude Code](https://claude.com/claude-code) hook 联动。任务运行时陪你一起踱步、思考、卡了就摇尾巴提醒你。

<img src="build/icon-1024.png" width="180" align="right" alt="Claude Pet 图标">

- **状态可视化**：Claude Code 跑工具时狗在敲键盘；等你确认时它在挥手；任务完成时跳起来庆祝；空闲太久趴下睡觉
- **Codex 9 行 sprite**：直接吃 [Petdex](https://petdex.crafter.run/) 的标准 1536×1872 webp，rio / daodun-dog / puggo 三个内置形象，用户也能导入自己的
- **菜单栏 app**：透明浮窗 + `nonactivatingPanel`，不抢焦点不占 Dock
- **鼠标追随**：任务完成后过来陪你 / 永久跟随两挡可选
- **一键接 Claude Code**：菜单点一下自动改写 `~/.claude/settings.json`，再点撤销
- **支持双击唤起 Claude Desktop**

## 系统要求

- macOS 13.0+ (Ventura)
- Apple Silicon 或 Intel 都可

## 安装

### 1) 从 Releases 下载（推荐）

去 [Releases](https://github.com/781015928/claude-pet/releases)，下载最新 `ClaudePet-vX.Y.Z.zip`，解压后把 `ClaudePet.app` 拖进 `/Applications/`。

ad-hoc 签名的 app 第一次打开 macOS 会拦：右键 → **打开** → 确认。

### 2) 从源码自己 build

```bash
git clone git@github.com:781015928/claude-pet.git
cd claude-pet
./scripts/build-app.sh --install   # 构建 + 复制到 /Applications/
open -a ClaudePet
```

或者开发模式直跑：

```bash
swift run ClaudePet
```

## 使用

### 第一步：连接 Claude Code

菜单栏点 🐶 → **连接到 Claude Code**。

桌宠会：

1. 把 hook 转发脚本写到 `~/.claude-pet/claude-pet-hook`
2. 把 8 个 hook 事件（`SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Notification` / `Stop` / `SubagentStop` / `PreCompact`）注入 `~/.claude/settings.json`，merge 模式不会破坏你已有的配置
3. 自动备份原 settings.json

再点一次同菜单项即撤销。

### 状态映射（Codex 标准 9 行）

| Claude 事件 | 桌宠状态 | Codex 行 | 视觉 |
|---|---|---|---|
| `SessionStart` | idle | 0 idle | 呼吸 + 气泡"嗨" |
| `UserPromptSubmit` | thinking | 8 review | 审视思考 |
| `PreToolUse` | working | 7 running | 任务踱步 + 工具名气泡 |
| `Notification` | notification | 3 waving | 挥手呼唤 |
| `Stop` | done | 4 jumping | 跳起庆祝 |
| `SubagentStop` | done | 4 jumping | "+1" 气泡 |
| `PreCompact` | working | 7 running | "整理…" |
| 5 分钟空闲 | sleeping | 6 waiting | 闭眼打盹 |

### 菜单功能

```
🐶 ┬ 显示宠物 / 隐藏宠物
   ├─ 形象 ▶ rio / daodun-dog / puggo / 自定义…
   ├─ 素材管理…       ← 导入 webp / 删除自定义
   ├─ 鼠标追随 ▶ 不跟随 / 任务完成后跟随 / 永久跟随
   ├─ 缩放滑块         ← 0.5× ~ 2.0×
   ├─ 连接到 Claude Code
   ├─ Hook 触发时自动启动
   ├─ 跑一下！           ← 测试用
   ├─ 重置位置
   └─ 退出
```

### 鼠标交互

| 交互 | 行为 |
|---|---|
| 鼠标移上去 | 光标变 ✋🏻 指点手势 |
| 拖拽 | 移动桌宠到任意位置 |
| 单击（待机时）| 随机播放挥手 / 跳跃 / 审视 一个动画 |
| 单击（追随中）| 取消追随 + running 跑回屏幕右下角 |
| 双击 | 唤起 Claude Desktop |

### 鼠标追随

- **任务完成后跟随**：每次 `Stop` hook 触发后桌宠跑过来追鼠标，到达后做 jumping 动画然后**持续跟随**，单击它即停下并跑回默认位置
- **永久跟随**：手动开启后一直跟，鼠标停下接近 → jumping，鼠标动 → running

### 自定义形象

菜单栏 → 素材管理… → 导入 sprite sheet…

要求：1536×1872 的 webp，按 [Codex 8×9 标准](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/references/animation-rows.md)排布（每帧 192×208）。

导入后文件复制到 `~/.claude-pet/pets/<id>/`，跟 app bundle 内的内置素材合并展示。卸载/升级 .app 不影响你导入的形象。

可以在 [Petdex](https://petdex.crafter.run/) 找现成的 sprite，或者用 [hatch-pet](https://github.com/openai/skills/tree/main/skills/.curated/hatch-pet) 自己生成。

## 配置持久化

所有用户选择都写到 `UserDefaults` (`com.czg.claudepet`)：

| key | 含义 |
|---|---|
| `ClaudePet.skin.id` | 当前形象 |
| `ClaudePet.followMode` | 追随模式 |
| `ClaudePet.scale` | 缩放（0.5–2.0） |
| `ClaudePet.window.origin` | 窗口位置 |
| `ClaudePet.connectedToClaude` | 是否已注入 hook |
| `ClaudePet.hookAutoStart` | hook 触发时是否自动启动 app |

## Hook 自动启动

开启 **Hook 触发时自动启动** 后：

1. hook 转发脚本检测到 `~/.claude-pet/.autostart` marker 存在
2. POST 失败（app 没在跑）时执行 `open -ga ClaudePet`
3. 等 5 次共 2 秒重试，让首个 hook 事件不丢

每次 Claude Code 一开会话就会把桌宠拉起来，不用记得手动开。

## 开发

```bash
swift build                          # debug
swift run ClaudePet                  # 直跑
swift build -c release               # release
./scripts/build-icon.sh              # 单独生成 AppIcon.icns
./scripts/build-app.sh               # 构建 .app 到 build/dist/
./scripts/build-app.sh --install     # 构建 + 复制到 /Applications/
```

调试 hook（不用真的让 Claude Code 触发）：

```bash
# 单点测试
curl -s -X POST http://127.0.0.1:54321/event \
  -H 'Content-Type: application/json' \
  -d '{"event":"PreToolUse","data":{"tool_name":"Bash"}}'

# 隐藏调试事件
curl -s -X POST http://127.0.0.1:54321/event \
  -H 'Content-Type: application/json' \
  -d '{"event":"__Click__","data":{}}'        # 模拟单击 oneshot
curl -s -X POST http://127.0.0.1:54321/event \
  -H 'Content-Type: application/json' \
  -d '{"event":"__Run__","data":{"duration":6}}'  # 触发跑步
```

## 项目结构

```
claude-pet/
├── Sources/
│   ├── ClaudePet/                # 主 app
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── PetWindow.swift       # 透明浮窗 + 自定义 cursor
│   │   ├── PetView.swift         # SwiftUI sprite 渲染
│   │   ├── PetStateMachine.swift # hook 事件 → state
│   │   ├── PetSkin.swift         # 形象定义 + UserDefaults 持久化
│   │   ├── SkinCatalog.swift     # 扫描 bundle/用户目录
│   │   ├── SpriteSheet.swift     # webp 切帧
│   │   ├── SpriteAnimationView.swift
│   │   ├── HookServer.swift      # 127.0.0.1:54321 极简 HTTP
│   │   ├── ClaudeHookInstaller.swift  # 注入 settings.json
│   │   ├── FollowController.swift # 鼠标追随 + 跑回默认位置
│   │   ├── MouseTracker.swift    # 1.5s 轮询全局鼠标
│   │   ├── PetActions.swift      # 唤起 Claude Desktop
│   │   ├── AssetManagerView.swift # 导入 / 删除面板
│   │   └── PetView.swift
│   └── ClaudePetIconGen/         # 离线生成应用图标
│       └── main.swift
├── pets/                         # 内置形象（rio / daodun-dog / puggo）
├── scripts/
│   ├── build-icon.sh             # 生成 AppIcon.icns
│   ├── build-app.sh              # 打 .app + ad-hoc codesign
│   └── ... 
├── hooks/                        # 旧版 shell 脚本（菜单内置后已不必需）
└── .github/workflows/
    ├── build.yml                 # PR / push 跑 swift build + 冒烟
    └── release.yml               # tag 触发自动发 GitHub Release
```

## CI

- `Build` workflow（macos-14）：`swift build` debug + release，打包 .app，冒烟启动 + POST `SessionStart`，上传 .app artifact
- `Release` workflow：push `v*` tag 自动构建 + 发 GitHub Release，附 .app 的 zip + sha256

## 致谢

- [OpenAI Codex](https://github.com/openai/codex) 的 `/pet` 设计 + 9 行 sprite 规范
- [Petdex](https://petdex.crafter.run/) 上的 rio / daodun-dog 等社区 sprite
- 漫画《吾皇万睡》里的巴扎黑（最初的 inspiration）

## License

MIT

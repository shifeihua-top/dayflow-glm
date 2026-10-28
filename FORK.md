# Dayflow GLM 定制版（fork 说明）

基于 [JerryZLiu/Dayflow](https://github.com/JerryZLiu/Dayflow) 的个人增强分支，
构建发布走 GitHub Actions（`.github/workflows/build-glm.yml`），产物为 ad-hoc 签名的
`.dmg` 安装包。

## 本分支的全部改动

### 智谱 GLM 原生支持
- `LocalEndpointUtilities.chatCompletionsURL`：URL 规整支持任意版本化根路径
  （`/v4` → 追加 `/chat/completions`，完整 `/chat/completions` 结尾保持原样）。
- `OpenAICompatiblePreset.zhipuGLM`：预设端点 `https://open.bigmodel.cn/api/paas/v4`
  + 默认模型 `glm-4.6v`（视觉模型，Dayflow 必需）。
- `ChatRequest.thinking`：GLM 混合思考开关，仅在 bigmodel.cn 端点注入——
  glm-4.x 发 `disabled`（否则 content 为空），glm-5.x 发 `enabled + effort: low`。
- Info.plist 禁用 Sparkle 自动更新，防止被官方版覆盖。

### 摄像头观察（实验性，默认关闭）
- `Core/Recording/WebcamObserver.swift`：每 60s 采样一次（前 45 帧丢弃等自动曝光），
  Vision 框架零成本人脸在场检测；帧只驻留内存约 20 分钟，绝不写盘。
- 转录时 `describe_frame` 按截图时间戳取最近的摄像头帧 + 在场摘要一并分析，
  输出中包含「摄像头：…」状态行，随观察流进入时间线卡片。
- 设置 → 存储（Recording quality 下方）：开关、云端发图开关（关 = 纯本机零成本）。

### 多显示器采集
- `ScreenshotConfig.captureAllDisplays`（默认关）：开启后每个 tick 采集所有显示器，
  按物理位置从左到右横向拼成一帧，下游管线零改动。多屏使每帧分析成本约翻倍。

### 摄像头进阶（实验性）
- 回放画中画：卡片回放右下角显示对应时刻的摄像头帧（点击放大），由「保存画面到本地」
  开关控制，帧以低分辨率 JPEG 存 `webcam/` 目录并保留 30 天自动清理（音频 7 天）。
- 状态分析：describe_frame 的摄像头行输出结构化状态（活动=工作/休息/喝水/交谈/离开；
  精神状态=专注/正常/疲惫/紧张；姿态与环境），卡片总结会把
  工作与静坐时长、休息次数、喝水时刻、精神状态趋势聚合为「个人状态：」小节。
- 安全事件监测（`webcam_events` 表）：偷窥（同画面 ≥2 人脸）与旁人操作
  （主人物理输入空闲 ≥3 分钟仍有人脸）自动记录起止时间；事件摘要注入
  describe_frame 分析，卡片摘要会明确指出。
- 事件期间录音（默认关闭，需麦克风权限）：仅事件进行中录制 m4a，
  存 `webcam-audio/`，随 7 天保留策略清理。

### 其他
- `FlowSessionTimeline.promptTimelineJSON` 拆分超大表达式（新版工具链类型检查超时）。

## 同步上游并出包

```bash
scripts/sync-upstream.sh   # fetch + merge + push，push 自动触发 CI 构建
```

- GitHub Actions 每周一 10:00（北京时间）也会自动合并上游；干净合并 → 自动出包，
  冲突 → 构建失败并提示，此时本地跑上面的脚本手工解决。
- 产物在 Actions run 的 artifact `dayflow-glm-macos` 里（DMG + ZIP）。

## 本地获取构建产物

```bash
gh run download --repo shifeihua-top/dayflow-glm -D artifacts  # 最新一次成功 run
```

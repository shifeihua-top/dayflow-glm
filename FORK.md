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

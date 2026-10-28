# 小满 · 鸿蒙陪伴型 AI（ArkTS / ArkUI）

一个跑在 HarmonyOS 上的**陪伴型** AI，不是助手，不是客服。

她是你的女儿：开朗、活泼、有点黏人。界面只有**一个**对话框，没有「新建对话」，没有会话列表 —— 因为她只有一段关系，一段连续的记忆。你可以随时跳到完全不相关的话题，她跟着跳，不会问「我们刚才说到哪了」。

后端仍然是 DeepSeek 官方接口（SSE 流式），但整个 App 的骨架是围绕**记忆**和**主动找你**搭的。

实测环境：DevEco Studio 26.0 / HarmonyOS SDK 26.0.0 API 26 / hvigor 6.26.8 / 真机 VYG-AL00（1280×2832）。

---

## 一、和普通聊天 App 的区别

| | 普通聊天 App | 这个 App |
|---|---|---|
| 界面 | 多会话列表，可新建 / 删除 | 只有一个对话框，永远连着 |
| 换话题 | 新建一个对话 | 直接跳，她跟着跳 |
| 上下文满了 | 砍掉最早的消息 | 先把旧对话写成记忆，再压缩 |
| 记忆 | 无，或只有原始记录 | 关系档案 + 记忆卡 + 摘要，三层 |
| 主动 | 你不问她不动 | 她会在你消失两三小时后自己开口 |
| 身份 | 「有什么可以帮您」 | 「你在干嘛呀」 |

---

## 二、记忆：三层结构

### 1. 关系档案（`Profile`）

她对你这个人的长期认知，也可以手动改：

- `herName` 她的名字（默认「小满」）
- `userName` 她怎么叫你
- `persona` 她的性格
- `facts` 关于你的稳定事实
- `habits` 你的习惯 / 作息 / 口头禅
- `tone` 你喜欢的说话方式

### 2. 记忆卡（`MemoryCard[]`）

一条一条的具体记忆，带类型和来源：

| 字段 | 说明 |
|---|---|
| `kind` | `fact` 事实 / `habit` 习惯 / `prefer` 喜好 / `avoid` 忌讳 / `event` 事件 / `date` 日子 / `joke` 我们的梗 / `plan` 约定 |
| `text` | 一句话，20 字以内 |
| `tags` | 2–3 个关键词，用于检索 |
| `source` | `stated`（你亲口说过）/ `observed`（她猜的，会在提示里标 `[待确认]`） |
| `pinned` | 置顶，永远进上下文 |
| `hits` | 命中的次数，用于排序 |

在「记忆」页可以置顶（★）或删除（×）。

### 3. 归档摘要（`ArchiveChunk[]`）

每整理一次，留一句「这一段聊了什么」，最多留 40 段，最近 4 段进上下文。

### 什么时候整理

两个触发条件，哪个先到算哪个：

- 攒够 **12 条**新消息；
- 上下文估算用量超过预算的 **80%**（预算 = 模型上限 × 触发百分比）。

整理时只处理 **除最近 6 条之外** 的部分，最近的对话保持原样，所以不会出现「刚说完就忘」。同一次会话里两次整理至少间隔 3 分钟，避免连发。

整理是**异步**的，不挡聊天；失败就静默跳过，下次再来。

### 上下文怎么装

不再是「最近 N 条」，而是按 token 预算从最新往回装：

```
预算 = 上下文上限 × 触发百分比（默认 64K × 80% = 51.2K）
system(她是谁 + 记忆) + 从最新往回的消息，装到装不下为止
```

最新那一句无论如何都会带上，老的自然被记忆卡和摘要替代。

### 检索

`MemoryService.pickCards()` 按关键词命中挑，最多 8 张：

1. 置顶的全带上；
2. 其余按最近 3 条消息 + 本句的分词命中打分；
3. 命中的按 `hits` 排序；
4. 一张都没命中就带最近的几张，保证她至少「记得点东西」。

---

## 三、主动找你

App 没法在后台跑三小时的定时器，所以分两条路：

- **前台**：页面每 30 秒 tick 一次，到点直接开口；
- **后台**：退到后台时把台词先想好，再用系统提醒（`reminderAgentManager`）排到那个时间点，到点弹通知。点通知回到 App，那句直接补进时间线。

### 节奏

| 模式 | 第一次 | 之后 | 每天上限 |
|---|---|---|---|
| 黏人（默认） | 2 小时 | 4 小时 / 8 小时 | 3 次 |
| 自然 | 4 小时 | 4 小时 | 1 次 |
| 克制 | —— | —— | 0（从不主动） |

- 安静时段默认 **00:30 — 08:00**，可调；落在这段的排期会推到结束时刻。
- 你一说话，计时器重置、当天已排的提醒取消。
- 冷启动时如果已经超时很久，不会立刻弹，会顺延 20 分钟，先给你自己开口的机会。
- 过时超过 6 小时就不补发了，直接重排。

### 通知显示

设置里三档：

- **TA 想你了**（默认，保护隐私）
- 显示原话
- 只显示名字

### 她不会做什么

- 不质问「你怎么不理我」
- 不连发
- 不用「我要走了 / 我很难过」要挟
- 你说忙、说安静点，她就真的安静

这些约束写在 system prompt 里，不是靠代码兜。

---

## 四、话题跳跃

`buildSystemPrompt()` 里专门有一段：

> 你（用户）会突然换话题，这很正常。你就跟着跳，别问「我们刚才说到哪了」，别要求他回到上一个话题。但如果旧话题里有没说完的事，过一会儿可以自己轻轻提一句。

所以「新话题」在实现上是**同一个时间线里的话题切换**，不是重开。

---

## 五、Markdown 渲染

模型偶尔会吐出 `**加粗**`、`- 列表`、`### 标题`。ArkUI 的 `Text` 不认 Markdown，会把星号原样显示出来 —— 之前界面上就真的出现过 `一般来说：**自己调用工具…**` 这种露馅的样子。

现在分两层处理：

**第一层，从源头压住。** system prompt 里写明：

> 平时聊天不要用 Markdown。只有他明确问你怎么做、要步骤、要清单、要代码的时候，才可以用编号列表，而且只在那一条回答里用。

**第二层，万一她还是写了，正确渲染。** `common/Markdown.ets` 是一个两百行的极简解析器，不引第三方库：

| 写法 | 渲染成 |
|---|---|
| `**加粗**` | `Span` + `FontWeight.Bold` |
| `` `代码` `` | 等宽 + 琥珀色 |
| `# 标题` | 加粗小标题 |
| `- 项` | 「·」圆点 + 悬挂缩进 |
| `1. 项` | 「1.」编号 + 悬挂缩进 |
| `> 引用` | 左侧竖线 + 灰字 |
| ` ``` ` 代码块 | 深色圆角块 + 等宽 |

**流式期间**特殊处理：标记还没收完，先走 `stripMarkers()` 剥成纯文本，并且把**末尾悬着的** `**` `` ` `` `#` 直接藏掉。否则会出现「`一个人 **很` → `一个人 **很重要**`」的闪烁。收完之后才走富文本。

长按气泡可以复制原文（`Span` 不支持 `copyOption`，所以用 `LongPressGesture` + `pasteboard` 自己实现）。

---

## 六、界面

只有一个页面 `pages/Index.ets`，暖砂配色（`#F6F0E8` 底 / `#FFFFFF` 她的气泡 / `#E8A87C` 你的气泡 / `#C97B4A` 强调）：

- **顶部**：App 图标 + 她的名字 + 当前状态（黏人 · 2 小时 / 正在回你 / 她在回想…）、「记忆」、「设置」
- **顶部第二行**：计价状态条，`闲时`（绿）/ `高峰`（红）+ 当前倍数 + 已花多少
- **中间**：一条时间线。她的消息靠左白底，你的靠右暖橘底，气泡宽度跟着内容走（说个「1」就一个小方块，不会撑满），跨天插日期
- **底部**：输入框 + 发送 / 停止
- **记忆页**：改名字、称呼、性格、事实、习惯；零散记忆可置顶 / 删除
- **设置页**：接口来源、Key、模型、思考强度、计价、上下文上限、触发百分比、黏人度、安静时段、通知内容、音色、重新认识

气泡圆角不对称（尾角 5，其余 16），像聊天软件那样指着一侧。

### 安静时段（设置里的两个滑块）

「从 … 到 …」那两个滑块就是**她绝不主动打扰你的时间段**。

默认 `00:30 — 08:00`：凌晨她不会发消息、不会弹通知，哪怕已经四五小时没说话；到 08:00 之后才可能开口。

- 支持跨零点：设成 `23:00 — 08:00`，界面会标「跨零点：到第二天 08:00」
- 两个值调成一样 = 没有安静时段，她任何时间都可能找你（会红字提示）
- **只影响主动消息**，你自己发消息她永远立刻回

---

## 七、接口来源：官方 / 三方

设置里「接口来源」两档：

| | 地址 | 计价 |
|---|---|---|
| **DeepSeek 官方** | `api.deepseek.com` | 官方价目，闲时 / 高峰 |
| **三方兼容接口** | 自己填 | 同上（按模型名估） |

三方模式下多两个输入框：

- **接口地址**：填到 `/v1` 就行，`/chat/completions` 会自动补。也允许直接贴完整 URL 或者只贴域名（自动补 `https://`），末尾斜杠自动去掉 —— 这些都在 `DeepSeekService.normalizeHost()` 里处理。
- **模型名**：留空就用上面选的 deepseek 模型。

还有「测试连接」按钮，打 `GET /models` 看通不通，成功会显示可用模型数量。

---

## 八、闲时 / 高峰计价

和第一版一致：

- 北京时间**工作日 09:00–12:00、14:00–18:00** 为高峰，价格 ×2
- 其余时间、周末、2026 法定节假日全天为闲时，×1
- 顶部状态条和设置页都实时显示，每 30 秒刷新一次
- 每轮回答按实际 usage（输入 / 缓存命中 / 输出）累加，显示到小数点后四位

价目在 `common/Pricing.ets` 里，`flash` 档 输入 ¥2 / 命中 ¥0.2 / 输出 ¥3，`pro` 档 输入 ¥4 / 命中 ¥0.5 / 输出 ¥12（每百万 token）。

三方接口如果计价不同，改这个文件里的两个常量即可。

---


## 九、文件

```
entry/src/main/ets/
├── model/
│   └── ChatTypes.ets          Profile / MemoryCard / ArchiveChunk / StoreMeta / Message
├── service/
│   ├── DeepSeekService.ets    SSE 流式 chatStream + 非流式 chatOnce
│   ├── MemoryService.ets      token 估算、记忆检索、prompt 组装、记忆抽取、主动台词提示
│   ├── ProactiveService.ets   排期计算、安静时段、系统提醒发布 / 取消
│   ├── VoiceInputService.ets  按住说话：麦克风 PCM → wav（16k/mono/16bit）
│   ├── VoiceService.ets       电脑侧 /asr 转写、/tts 按句合成（带缓存）、断句
│   ├── PlayerService.ets      AVPlayer 播 wav，单实例可打断
│   └── ChatStore.ets          companion.json 读写 + 旧版多会话迁移
├── common/
│   ├── Markdown.ets           极简 Markdown 解析 + 流式标记剥离
│   └── Pricing.ets            价目表、闲时/高峰判定、节假日、费用估算
├── pages/
│   └── Index.ets              唯一页面：时间线 / 记忆页 / 设置页
└── entryability/
    └── EntryAbility.ets

docs/
└── 语音需求.md                语音功能需求与调研结论（未实现）
```

数据落在 `filesDir/companion.json`（单文件，含消息、档案、记忆卡、摘要、主动状态）。设置走 `preferences` 的 `companion_settings`。

`preferences` 单值只有 8KB，所以长对话正文一律不进 preferences。

---

## 十、从旧版升级

旧版是「联网助手 + 多会话」，已经全部拆掉：

- `WebSearchService.ets` 删除，`Holidays.ets` 删除；
- 旧的多会话文件 `deepseek_chats.json` 会在首次启动时**按时间合并成一条时间线**，只保留最近 400 条；
- 旧设置 `deepseek_settings` 里的 `apiKey` / `model` 会自动搬到 `companion_settings`，不用重填。

---

## 十一、权限

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | 调 DeepSeek 接口 |
| `ohos.permission.PUBLISH_AGENT_REMINDER` | 后台到点弹「她找你」的通知 |
| `ohos.permission.MICROPHONE` | 按住说话时录音 |
| `ohos.permission.VIBRATE` | 录音/取消时的触感反馈 |

通知权限是运行时申请，设置页里有「去开启通知」。

---

## 十二、构建

本机（D:\hw\DevEco Studio）直接跑：

```bat
scripts\build.bat          rem 构建 HAP
scripts\build.bat install  rem ohpm install
```

PowerShell 手动方式（换电脑参考）：

```powershell
$env:NODE_HOME='D:\hw\DevEco Studio\tools\node'
$env:JAVA_HOME='D:\hw\DevEco Studio\jbr'
$env:DEVECO_SDK_HOME='D:\hw\DevEco Studio\sdk'
$env:PATH="$env:NODE_HOME;$env:JAVA_HOME\bin;D:\hw\DevEco Studio\tools\ohpm\bin;$env:PATH"
& 'D:\hw\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

```powershell
$hdc='D:\hw\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
```

---

## 十三、语音（已实现，详见 docs/语音需求.md）

双向语音消息，微信式：**按住说话、松开即发语音条**；她的回复随机一半是语音条（`REPLY_VOICE_RATE = 0.5`），点开按句合成播放，再点停止。转写文字以小字显示在语音条下，长按气泡仍是复制原文。

**ASR 和 TTS 两个模型都跑在电脑上**（你要求的）：

- 手机只负责录音（`VoiceInputService`）和播放（`PlayerService`）
- 电脑上 `D:\voice-server\adapter.py`（9880 端口）：`/asr` 用 FunASR paraformer-zh（CPU）、`/tts` 代理 GPT-SoVITS v2Pro（GPU、9881）
- 电脑不开，语音不可用，打字聊天不受影响；设置里填电脑地址，可「测试连接」

音色两种（甜妹 / 御姐），当前用 Windows TTS 晓慧快慢两种语速合成的**预制占位**参考音频，自己录的替换 `D:\voice-server\refs\` 即可（要求见 docs/语音需求.md 第四节）。

实测：中文一句话合成约 2.5 秒，FunASR 转写 RTF≈0.24，4GB 显存宽裕。

## 十四、已知限制

- 后台主动消息依赖系统提醒，如果系统把通知权限关了或者省电策略杀掉，就不会弹；
- 记忆抽取靠模型自己判断，偶尔会漏记或记偏，所以给了手动编辑的入口；
- token 估算按「中文 1 字 ≈ 1 token，英文 4 字符 ≈ 1 token」粗算，和真实计费会有出入；
- 单文件存储，理论上消息很多时会变慢，目前限制最近 400 条。

---

## 十五、从 clone 到跑起来

### 1. 环境

| 需要 | 版本 / 说明 |
|---|---|
| DevEco Studio | 5.0 以上（本项目在 6.0 / SDK 26 上实测） |
| HarmonyOS SDK | API 26（`compatibleSdkVersion` 26.0.0） |
| 真机 | HarmonyOS NEXT。模拟器没有麦克风，语音功能用不了 |
| Python | 3.10+，跑语音服务端用 |

DevEco 自带 node、ohpm、hvigor，不用另外装。

### 2. 拉代码

```bash
git clone git@gitee.com:camael/peiliao.git
cd peiliao
```

用 DevEco Studio `File → Open` 打开**仓库根目录**，等右下角 sync 跑完。

### 3. 配签名（必做，不配装不上手机）

仓库里 `build-profile.json5` 的签名路径是原作者机器的，clone 下来用不了：

`File → Project Structure → Signing Configs` → 勾 `Automatically generate signature` → 登录华为账号 → 等它生成。

生成后这个文件会被改写成本机路径，属于正常现象，**别提交这处改动**。

### 4. 填 API Key

App 里 `设置 → 接口`：

- 地址：`https://api.deepseek.com`
- Key：你自己的 DeepSeek key（存在设备本地，不在代码里）

### 5. 起语音服务端

两件事：GPT-SoVITS 和 adapter。

```bash
# 1) GPT-SoVITS 的 api_v2 服务，默认 9881
python api_v2.py -a 127.0.0.1 -p 9881

# 2) 本项目的中转服务，9880
cd voice-server
pip install fastapi uvicorn requests funasr
python adapter.py
```

`voice-server/config.json` 要改三处：

| 字段 | 改成 |
|---|---|
| `voices.*.ref` | 你机器上 `refs/sweet.wav`、`refs/queen.wav` 的绝对路径 |
| `ffmpeg` | 你的 ffmpeg 路径 |
| `token` | 自己定一个，别用仓库里那个 |

App 里 `VoiceService.ets` 的 `tokenValue` 必须和 `token` 完全一致，否则 `/tts`、`/asr` 全返 401。

### 6. 手机连电脑

同一个局域网，App `设置 → 语音`：

- 地址填 `http://电脑IP:9880`
- 点「测试连接」，`/health` 返回 ok 就通了

出门用（不同网络）走 Cloudflare 隧道，见 `docs/外网访问.md`。**要填 https 全地址**，App 不会自动补协议。

### 7. 装到手机

```powershell
$hdc = '<DevEco 安装目录>\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc list targets
& $hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
```

无线调试端口每次重启手机都会变，`hdc tconn 手机IP:端口` 之前先看一眼手机上写的端口号。

---

## 十六、加表情包

`entry/src/main/resources/rawfile/stickers/` 下丢一张 GIF，**文件名就是它的情绪标签**：

```
啤酒.gif   →   标签「啤酒」
```

然后两步：

1. `entry/src/main/ets/common/Stickers.ets` 加一行 `{ file: '啤酒.gif', tag: '啤酒' }`
2. 想让「撸串」「喝一杯」这类话也能触发，在 `Index.ets` 的 `STICKER_CUES` 里加 `['撸串', '啤酒']`

同名多张（`开心.gif`、`开心2.gif`）会**随机抽一张**。

触发频率看 `Index.ets` 的 `STICKER_RATE`，默认 `0.7`，调小就少发。

表情包只在「你俩的话里有情绪词」时才发，没有就不发，所以不会连着刷屏。
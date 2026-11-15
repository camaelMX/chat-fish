# 大肥鱼 · 鸿蒙陪伴型 AI

一个跑在 HarmonyOS 上的**陪伴型** AI，不是助手，不是客服。

她只有一段关系、一段连续的记忆。界面上只有一个对话框 —— 没有「新建对话」，没有会话列表。你可以随时跳到完全不相关的话题，她跟着跳，不会问「我们刚才说到哪了」。

语言能力来自 DeepSeek（SSE 流式），整个 App 的骨架围绕**记忆**和**主动**搭。

---

## 为什么不是又一个聊天 App

普通聊天 App 有三个默认假设，放到「陪伴」这个场景里全都不成立：

- **上下文满了就砍最早的消息** —— 等于把这段关系格式化。所以得先把旧对话写成记忆，再压缩。
- **你不问她不动** —— 这是助手的行为，不是陪伴。她得会自己开口，而且不能烦人。
- **打字不像说话** —— 语音必须是真语音，不是 TTS 念文字。

|  | 普通聊天 App | 这个 App |
|---|---|---|
| 界面 | 多会话列表，可新建 / 删除 | 只有一个对话框，永远连着 |
| 换话题 | 新建一个对话 | 直接跳，她跟着跳 |
| 上下文满了 | 砍掉最早的消息 | 先把旧对话写成记忆，再压缩 |
| 记忆 | 无，或只有原始记录 | 关系档案 + 记忆卡 + 摘要，三层 |
| 主动 | 你不问她不动 | 你消失两三小时后她自己开口 |
| 身份 | 「有什么可以帮您」 | 「你在干嘛呀」 |

---

## 能力

| 能力 | 说明 |
|---|---|
| 单一时间线 | 一个对话框装下所有对话，跨天插日期 |
| 三层记忆 | 关系档案、记忆卡、归档摘要；记忆页可置顶 / 删除 |
| 主动消息 | 三档黏人度、安静时段、后台系统提醒 |
| 按住说话 | 微信式语音条，转写文字附在气泡下 |
| 语音通话 | 全屏通话页，免提 VAD，说完自动收尾、念完自动接着听，支持插话 |
| 看图 | 相册选图，模型先看懂画面，她按人设接话 |
| 表情包 | 按情绪词触发，可自定义标签 |
| 计价 | 按官方闲时 / 高峰价目实时估算花费 |

---

## 快速开始

### 1. 环境

| 需要 | 版本 / 说明 |
|---|---|
| DevEco Studio | 5.0 以上（本项目在 6.0 / HarmonyOS SDK 26 上开发） |
| HarmonyOS SDK | API 26（`compatibleSdkVersion` 26.0.0） |
| 真机 | HarmonyOS NEXT。模拟器没有麦克风，语音用不了 |
| Python | 3.10+，只给语音服务端用，纯打字聊天不需要 |

DevEco 自带 node、ohpm、hvigor，不用另外装。

### 2. 拉代码

```
git clone https://github.com/camaelMX/chat-fish.git      # 或 gitee.com/camael/peiliao（国内快）
cd chat-fish
```

用 DevEco Studio `File → Open` 打开**仓库根目录**，等右下角 sync 跑完。

### 3. 补齐四个本地文件

仓库里没有任何明文密钥，有四个文件只留模板，真值在各自机器上。`.gitignore` 已覆盖，`git status` 看不到它们：

| 缺的文件 | 从哪来 | 填什么 |
|---|---|---|
| `build-profile.json5` | 复制 `build-profile.example.json5`，或在 DevEco 里 `File → Project Structure → Signing Configs → Automatically generate signature` 重新生成 | 签名证书路径、`keyAlias`、`storePassword` / `keyPassword` |
| `voice-server/config.json` | 复制 `voice-server/config.example.json` | `token`、`voices.*.ref`、`ffmpeg` |
| `entry/src/main/resources/rawfile/app_secrets.json` | 复制 `rawfile/app_secrets.example.json` | `visionKey`、`voiceToken`、`secretVersion` |
| `voice-server/refs/*.wav` | 自备 | 3–10 秒干声，`prompt_text` 写音频里的原话 |

```bash
cp build-profile.example.json5 build-profile.json5
cp voice-server/config.example.json voice-server/config.json
cp entry/src/main/resources/rawfile/app_secrets.example.json \
   entry/src/main/resources/rawfile/app_secrets.json
```

不填会怎样：签名缺失 → 构建直接失败；`config.json` 缺失 → 语音服务起不来；`app_secrets.json` 缺失 → App 照常能用，只是按住说话 401、发图提示没填 Key，这两样在设置页手填也行。

### 4. 构建

改两处路径：`scripts/build.bat` 第一行的 DevEco 安装路径，以及 `voice-server/env.bat` 里的 `GPTSOVITS_HOME`（指向你解压的 GPT-SoVITS 目录；adapter 目录由脚本自身位置推导，不用填）。然后：

```bat
scripts\build.bat          rem 构建 HAP
scripts\build.bat install  rem 先 ohpm install
```

PowerShell 手动方式：

```powershell
$env:NODE_HOME="$DevEco\tools\node"
$env:JAVA_HOME="$DevEco\jbr"
$env:DEVECO_SDK_HOME="$DevEco\sdk"
$env:PATH="$env:NODE_HOME;$env:JAVA_HOME\bin;$DevEco\tools\ohpm\bin;$env:PATH"
& "$DevEco\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物在 `entry/build/default/outputs/default/entry-default-signed.hap`。

### 5. 装到手机

```powershell
$hdc = "$DevEco\sdk\default\openharmony\toolchains\hdc.exe"

# 有线
& $hdc list targets
& $hdc install -r entry\build\default\outputs\default\entry-default-signed.hap

# 无线调试：手机 设置 → 开发人员选项 → 无线调试，用屏幕上的 IP:端口
$key = '192.168.x.x:端口'
& $hdc tconn $key
& $hdc -t $key install -r entry\build\default\outputs\default\entry-default-signed.hap
```

### 6. 语音服务（可选）

不打语音可以完全跳过这步。语音需要两台服务：GPT-SoVITS 负责合成，本项目的中转服务负责 ASR 和调度。

```bash
# 1) GPT-SoVITS 的 api_v2，默认 9881
python api_v2.py -a 127.0.0.1 -p 9881

# 2) 中转服务，9880
cd voice-server
pip install fastapi uvicorn requests funasr
python adapter.py
```

`config.json` 三处要改：

| 字段 | 改成 |
|---|---|
| `voices.*.ref` | 本机参考音的绝对路径 |
| `ffmpeg` | 本机 ffmpeg 路径 |
| `token` | 自己定一个随机串 |

App 侧 `app_secrets.json` 的 `voiceToken` 必须和 `token` 一字不差，否则 `/tts`、`/asr` 全返 401。

服务是常驻进程，建议配一层看护（定时探端口，挂了自动重启），否则它半夜退出后语音会静默失效——App 只是收不到音频，不会报错。

---

## 配置详解

### `app_secrets.json`

```json
{
  "secretVersion": 1,
  "visionKey": "智谱 open.bigmodel.cn 的 Key，glm-4.6v-flash 免费额度即可",
  "voiceToken": "和电脑端 config.json 的 token 完全一致"
}
```

这个文件会在构建时打进 HAP（装机后没别处可读），但不进仓库。**别人拿到你的 HAP 就能翻出里面的 Key**，所以安装包别公开传。

`secretVersion` 用来解决「换了口令但手机上还留着旧值」：App 启动时比对文件里的版本和本机记录的版本，文件更大就强制用文件里的 `voiceToken` 覆盖设置页存过的口令。改口令的完整流程是——`config.json` 的 `token`、这里的 `voiceToken`、这里的 `secretVersion` 加 1，重新打包安装。漏掉版本号，旧口令会一直压着新值，表现是 `/tts` 全返 401。

优先级：设置页手填 > 本地文件 > 空。

### `config.json`

```json
{
  "port": 9880,
  "gpt_sovits_url": "http://127.0.0.1:9881",
  "asr_model": "paraformer-zh",
  "asr_device": "cpu",
  "token": "自己定",
  "voices": {
    "sweet": { "ref": ".../refs/sweet.wav", "prompt_text": "参考音里的原话" }
  },
  "ffmpeg": "C:/ffmpeg/bin/ffmpeg.exe"
}
```

`prompt_text` 必须和参考音逐字一致，声学模型靠它对齐音色。换音色的顺序：替换 wav → 改 `ref` 和 `prompt_text` → **重启 adapter**（配置只在启动时读一次）。

### `voice-server/env.bat`

语音脚本里唯一的路径开关，只有一行要改：

```bat
set "GPTSOVITS_HOME=D:\dev-setup\gptsovits\GPT-SoVITS-v2pro-20250604"
```

`start_voice.bat` / `start_adapter.bat` / `start_gptsovits.bat` / `tools\start-tunnel.bat` 都 `call` 它，改一处全生效；`VOICE_DIR` 取脚本自身所在目录，所以仓库放哪都行。adapter 要单独部署到别的目录时，设环境变量 `VOICE_DIR` 指向那里，隧道脚本就会把网址写过去。

### 家里 / 出门双地址

设置里「家里地址」填 `192.168.x.x:9880`；「外网地址」由电脑自动同步——`tools/start-tunnel.bat` 把当前 Cloudflare 临时隧道网址写进 `tunnel_url.txt`，adapter 的 `/ping` 把它告诉手机，App 在家连局域网时顺手存下来。

每次语音请求前先探一下局域网 `/ping`：通就直连，不通走隧道；单次请求失败还会当场换另一条重试。结果缓存 60 秒，回前台立刻重选。全程不读 Wi-Fi 名称，所以不需要定位权限。详见 `docs/外网访问.md`。

---

## 项目结构

```
entry/src/main/ets/
├── model/ChatTypes.ets          Profile / MemoryCard / ArchiveChunk / Message
├── service/
│   ├── DeepSeekService.ets      SSE 流式 chatStream + 非流式 chatOnce
│   ├── MemoryService.ets        token 估算、记忆检索、prompt 组装、记忆抽取
│   ├── ProactiveService.ets     排期、安静时段、系统提醒发布 / 取消
│   ├── VoiceInputService.ets    按住说话：麦克风 PCM → wav（16k/mono/16bit）
│   ├── VoiceService.ets         双地址选路、/asr 转写、/tts 按句合成 + 缓存
│   ├── CallSession.ets          通话状态机：VAD → ASR → DeepSeek → 按句 TTS
│   ├── PlayerService.ets        AVPlayer 播 wav，单实例可打断
│   ├── VisionService.ets        图片描述（智谱）+ 429 分流重试
│   └── ChatStore.ets            companion.json 读写 + 旧版多会话迁移
├── common/
│   ├── Markdown.ets             极简 Markdown 解析 + 流式标记剥离 + 长行切分
│   └── Pricing.ets              价目、闲时/高峰、节假日、费用估算
├── pages/Index.ets              唯一页面：时间线 / 记忆页 / 设置页
└── entryability/EntryAbility.ets

voice-server/                    电脑端语音中转（FastAPI）
tools/                           隧道启动与网址抓取
docs/                            语音（架构与音色）、外网访问（隧道与鉴权）
```

数据落在 `filesDir/companion.json`（单文件：消息、档案、记忆卡、摘要、主动状态）；设置走 `preferences` 的 `companion_settings`。`preferences` 单值只有 8KB，所以长对话正文一律不进 preferences。

---

## 关键实现

### 记忆：三层结构

**关系档案（`Profile`）** —— 对这个人的长期认知，可手动改：`herName`、`userName`、`persona`、`facts`、`habits`、`tone`。

**记忆卡（`MemoryCard[]`）** —— 一条一条的具体记忆：

| 字段 | 说明 |
|---|---|
| `kind` | `fact` / `habit` / `prefer` / `avoid` / `event` / `date` / `joke` / `plan` |
| `text` | 一句话，20 字以内 |
| `tags` | 2–3 个关键词，用于检索 |
| `source` | `stated`（亲口说过）/ `observed`（她猜的，提示里标 `[待确认]`） |
| `pinned` | 置顶，永远进上下文 |
| `hits` | 命中次数，用于排序 |

**归档摘要（`ArchiveChunk[]`）** —— 每整理一次留一句「这段聊了什么」，最多 40 段，最近 4 段进上下文。

整理触发条件，谁先到算谁：攒够 **12 条**新消息，或上下文估算用量超过预算的 **80%**。只处理**除最近 6 条之外**的部分，所以不会刚说完就忘；同一次会话两次整理至少间隔 3 分钟。整理是异步的，不挡聊天，失败静默跳过。

### 上下文怎么装

不是「最近 N 条」，而是按 token 预算从最新往回装：

```
预算 = 上下文上限 × 触发百分比（默认 64K × 80% = 51.2K）
system(她是谁 + 记忆) + 从最新往回的消息，装到装不下
```

最新那一句无论如何都带上，老的自然被记忆卡和摘要替代。

检索在 `MemoryService.pickCards()`，最多 8 张：置顶全带 → 其余按最近 3 条消息和本句的分词命中打分 → 命中的按 `hits` 排 → 一张都没命中就带最近的几张，保证她至少记得点东西。

### 主动消息怎么活过后台

App 没法在后台跑三小时定时器，所以分两条路：**前台**每 30 秒 tick 一次，到点直接开口；**后台**退出去前把台词想好，用 `reminderAgentManager` 排到那个时间点弹通知，点通知回来那句直接补进时间线。

| 模式 | 第一次 | 之后 | 每天上限 |
|---|---|---|---|
| 黏人（默认） | 2 小时 | 4 / 8 小时 | 3 次 |
| 自然 | 4 小时 | 4 小时 | 1 次 |
| 克制 | —— | —— | 0（从不主动） |

安静时段默认 **00:30 — 08:00**，可调，支持跨零点；落在这段的排期推到结束时刻。你一说话，计时器重置、当天已排的提醒取消。冷启动时如果已经超时很久，不会立刻弹，顺延 20 分钟先给你开口的机会；超时超过 6 小时就不补发了。

她不会做的事：不质问「你怎么不理我」、不连发、不用「我要走了」要挟、你说忙就真的安静。这些写在 system prompt 里，不是靠代码兜。

### 语音：按住说话与通话

**ASR 和 TTS 都跑在电脑上**，手机只负责录音和播放。电脑不开，语音不可用，打字聊天不受影响。

按住说话：松开即发语音条，转写文字以小字显示在气泡下；她的回复随机一半是语音条（`REPLY_VOICE_RATE = 0.5`），按句合成、带缓存。

通话：全屏页，**不用按住**。开麦听 → 能量 VAD（说完静音 0.9 秒收尾，最长 15 秒，一直没人说话 20 秒重开一轮）→ 电脑 ASR → DeepSeek 非流式 → 按句 TTS 播放 → 播完继续听。纯静音段标 `voiced=false` 不发给电脑，省得噪声刷请求；每轮 wav 用完即删。

回声消除靠系统 3A：录音端标 `SOURCE_TYPE_VOICE_COMMUNICATION`，播放端 `usage = STREAM_USAGE_VOICE_COMMUNICATION`，两端都标才会启用。AEC 可用时，她说话期间旁边一直开着麦，连续 260ms 超过 RMS 620 判定为插话 → 立刻停止播放 → 原地转 VAD 把这句录完 → 交给下一轮转写，插话内容不丢。AEC 不可用或通话音源启动失败会自动降级，不硬开麦（否则她的声音会被当成用户，无限自我打断），保留插话按钮兜底。

切后台和息屏不挂断：声明 `backgroundModes: ["audioRecording", "audioPlayback"]`，通话开始时 `startBackgroundRunning` 一次申请两个类型，挂断时释放。系统会显示常驻通知（合规要求，去不掉）。申请失败不阻断通话，只是息屏后可能被挂起。

### 看图：两段式

DeepSeek 官方 chat 接口不接收图片，所以图片先交给智谱的视觉模型翻译成画面描述，再把描述塞进 DeepSeek，由她按人设、记忆、语气接着聊。**智谱只负责看，不扮演她。**

链路：选图 → 存 `filesDir/images/` → `VisionService.describe()` → 描述挂到 `Message.imageDesc` 落盘 → `buildRequest()` 把描述注入 system（「我已经替你看过了：…」）和历史消息（`[图片：…]`）→ 正常流式回复。

原图 4000px 直接传又慢又费 token，所以先缩到长边 1024、JPEG 80、Base64。识别失败不挡发图：图片照样发出去，她按「这次没看清」自然追问，不编画面。

智谱的 429 有两种，处理方式相反：**1305** 是免费模型排队（「该模型当前访问量过大」），退避重试 3 次（1.2s / 2.6s）能挤进去；**1113** 才是余额或资源包不足，重试没用，直接提示去充值。401 单独提示 Key 不对。`max_tokens` 给到 800——免费 flash 偶尔先把 token 花在思考上，content 空着回来，这种也会重试一次。

### 长回复排版

模型一口气吐上千字时，ArkUI 对超长段落偶发测量失准，会出现「字画到气泡外面」。三处一起修，都在显示层，**不改原文，长按复制仍是完整内容**：

- `wrapLongLines()` 把超过 96 字的行切成短行，尽量落在标点后，保留加粗和行内代码样式；
- 所有正文 `Text` 加 `wordBreak(BREAK_WORD)`——优先空格断，找不到断点才允许字符间断行；
- `ForEach` 的 key 带内容长度指纹，内容变化时重建节点而不是复用旧测量。

`ReplyShaper.split()` 仍是最多 3 条（语音 2 条），不为了让排版好看把长回复切碎。

---

## 已知限制

- 后台主动消息依赖系统提醒，通知权限被关或省电策略杀进程就不会弹；
- 记忆抽取靠模型自己判断，偶尔漏记或记偏，所以留了手动编辑入口；
- token 估算按「中文 1 字 ≈ 1 token，英文 4 字符 ≈ 1 token」粗算，和真实计费有出入；
- 单文件存储，消息多了会变慢，目前限制最近 400 条；
- 图片存进 `filesDir/images/` 后不自动清理（删消息不带删图），发多了占空间；
- `voip` 后台模式是 SystemApi，第三方拿不到；长时间后台仍可能被配额挂起；
- 语音质量取决于本机 GPU 和参考音，换音色要重启 adapter 才生效。

---

## FAQ

**有现成的安装包能直接下载用吗？**

没有，也不打算提供。这个 App 是**客户端**，不是完整产品：

- 语音链路打的是你自己电脑上的 `adapter.py`（9880），别人没有这台机器、没有 GPT-SoVITS、没有参考音；
- 智谱 Key 和语音口令会随构建打进 HAP，别人装了等于用你的额度、占你的显卡；
- 鸿蒙的调试签名绑定设备和开发者账号，换台机器装不上。

要「下载即用」只有一条路：把语音和模型都搬到云端，加账号体系和计费——那是另一个工程。现在的形态是**自己配、自己构建、自己部署**，代码开源是为了让你能这么干，而不是为了分发二进制。

**`install` 报 `Error opening file`**

别给 `install` 传 `D:/...` 绝对路径，hdc 会当成相对路径拼成 `项目根\D:\...`。先 `cd` 到项目根用相对路径。

**无线调试连不上 / `Not match target founded`**

TCP 连接几秒就断（锁屏、退出无线调试页面都会断）。`tconn` 后要立刻 `install`，并带 `-t 手机IP:端口`（换成手机屏幕上那个）；报 `need connect-key` 就是掉线了，重新 `tconn`，必要时 `hdc kill` 重启服务再连。

**装完语音一直 401**

三处要一致：`config.json` 的 `token`、`app_secrets.json` 的 `voiceToken`、设置页「语音口令」。改了前两处记得把 `secretVersion` 加 1，否则手机上存的旧口令会压过新值。

**语音条能播，按住说话没反应**

按住说话走 ASR，需要电脑端 `/asr` 就绪（首次调用要加载 FunASR 模型，等十几秒）。检查 `设置 → 她的声音 → 当前：…` 显示的是家里还是外网，以及那条路径通不通。

---

## 主题

暖砂。底色 `#F6F0E8`，她的气泡 `#FFFFFF`，你的气泡 `#E8A87C`，强调色 `#C97B4A`。气泡圆角不对称：尾角 5，其余 16。

---

## 许可证

MIT，见 [LICENSE](LICENSE)。

仓库里的音色参考音、角色形象、表情包**不在授权范围内**，那些素材不在仓库中，需自备。人格口吻参考自开源人格《大肥鱼》，按其原许可使用。


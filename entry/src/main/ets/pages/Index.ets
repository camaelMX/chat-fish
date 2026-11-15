import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { DeepSeekService, ChatMessage } from '../service/DeepSeekService';
import { CompanionStore } from '../service/ChatStore';
import { VoiceStorage } from '../service/VoiceStorage';
import { MemoryService, Extracted, ExtractedCard, CompactedMemory } from '../service/MemoryService';
import {
  ProactiveService,
  STICK_CLUNGY,
  STICK_NATURAL,
  STICK_QUIET,
  NOTIFY_TEXT,
  NOTIFY_HINT,
  NOTIFY_HIDDEN,
  DEFAULT_QUIET_START,
  DEFAULT_QUIET_END
} from '../service/ProactiveService';
import {
  Message,
  Profile,
  MemoryCard,
  ArchiveChunk,
  StoreMeta,
  StoreData,
  SavedMessage,
  defaultProfile,
  defaultMeta
} from '../model/ChatTypes';
import { Line, Seg, parseMarkdown, stripMarkers, lineFingerprint } from '../common/Markdown';
import { isPeakNow, estimateCost, nextSwitchText } from '../common/Pricing';
import { VoiceInputService, VoiceInputEvents, VoiceClip } from '../service/VoiceInputService';
import { VoiceService } from '../service/VoiceService';
import { CallSession, CallConfig, CallCallbacks } from '../service/CallSession';
import { STICKERS, StickerDef, migrateStickerName } from '../common/Stickers';
import { ReplyShaper } from '../common/ReplyShaper';
import { PlayerService } from '../service/PlayerService';
import { VisionService } from '../service/VisionService';

/** 排队等她说完再发的语音 */
interface QueuedTurn {
  text: string;
  msg: Message;
}

/**
 * 本地密钥文件 rawfile/app_secrets.json 的结构。
 *
 * 这个文件**不入库**（.gitignore 里有），只留在自己机器上，构建时被打进 HAP。
 * 目的：仓库里不出现任何明文 Key，但装机后仍然开箱可用。
 * 文件不存在、格式不对、字段缺失都当空串处理，绝不阻塞启动。
 */
interface LocalSecrets {
  visionKey: string;
  voiceToken: string;
  /** 密钥包版本。大于手机里存的版本时，强制用文件里的新口令覆盖旧口令。 */
  secretVersion: number;
}


const PREF_NAME: string = 'companion_settings';
/** 接口来源：官方 / 三方兼容 */
const SRC_OFFICIAL: string = 'official';
const SRC_THIRD: string = 'third';
/** 上下文预算上限可选值 */
const LIMIT_32K: number = 32000;
const LIMIT_64K: number = 64000;
const LIMIT_128K: number = 128000;
/** 每整理一次记忆，保留多少条最近消息不进摘要 */
const KEEP_RAW: number = 6;
/** 攒够多少条就整理一次 */
const CONSOLIDATE_EVERY: number = 12;
const MAX_CARDS: number = 200;
/** facts / habits 最多留多少段（再多了每轮上下文都是垃圾） */
const MERGE_TEXT_MAX: number = 14;
/** 打字聊天时她抽中语音条的概率；用语音说话时她必回语音，不受这个值管 */
const REPLY_VOICE_RATE: number = 0.5;
/** 回复内容沾到表情标签时，真的把表情包发出来的概率 */
const STICKER_RATE: number = 0.7;
/** 情绪词 → 表情标签。她不肯主动写 [表情:x] 时，靠这张表兜底配一张 */
const STICKER_CUES: string[][] = [
  ['累', '好累'], ['困', '困了'], ['晚安', '晚安'], ['睡', '困了'],
  ['哈哈', '哈哈哈'], ['笑死', '笑死'], ['开心', '开心'], ['高兴', '开心'],
  ['难过', '别难过'], ['难受', '抱抱'], ['委屈', '委屈'], ['烦', '麻了'],
  ['生气', '生气'], ['无语', '无语'], ['饿', '饿了'], ['吃', '开饭啦'],
  ['想你', '想你了'], ['喜欢', '喜欢'], ['谢谢', '谢谢'], ['抱', '抱抱'],
  ['加油', '加油'], ['下班', '下班啦'], ['上班', '摸鱼中'], ['撑', '撑了']
];
/** 她把"听不见"当成定论的那些回复，不再喂回上下文 */
const VOICE_DENIAL_RE: RegExp = /(听不见|只有字|没有声音|没声音)/;

// ==================== 配色：暖砂 / 黄昏 ====================
const C_BG: string = '#F6F0E8';
const C_BG_TOP: string = '#FBF6EF';
const C_CARD: string = '#FFFFFF';
const C_HER: string = '#FFFFFF';
const C_ME: string = '#E8A87C';
const C_TEXT: string = '#3D342C';
const C_TEXT_DIM: string = '#8C7F70';
const C_TEXT_ME: string = '#FFFFFF';
const C_ACCENT: string = '#C97B4A';
const C_ACCENT_SOFT: string = '#F0D9C4';
const C_LINE: string = '#EADFD2';
const C_INPUT_BG: string = '#FFFFFF';

@Entry
@Component
struct Index {
  // ==================== 对话 ====================
  @State messages: Message[] = [];
  @State streaming: string = '';
  @State reasoning: string = '';
  @State input: string = '';
  @State sending: boolean = false;

  // ==================== 记忆 ====================
  @State profile: Profile = defaultProfile();
  @State cards: MemoryCard[] = [];
  @State archives: ArchiveChunk[] = [];
  @State meta: StoreMeta = defaultMeta();

  // ==================== 界面开关 ====================
  @State showSettings: boolean = false;
  @State showMemory: boolean = false;
  @State ready: boolean = false;

  // ==================== 设置项 ====================
  @State apiKey: string = '';
  /** 智谱图片识别 Key。仓库不留明文，首次启动从 rawfile/app_secrets.json 取本地默认值 */
  @State visionKey: string = '';
  @State model: string = 'deepseek-flash';
  @State effort: string = 'off';
  @State contextLimit: number = LIMIT_64K;
  @State triggerPercent: number = 80;
  @State stickiness: string = STICK_CLUNGY;
  @State quietStart: number = DEFAULT_QUIET_START;
  @State quietEnd: number = DEFAULT_QUIET_END;
  @State notifyMode: string = NOTIFY_HINT;
  @State voiceStyle: string = 'sweet';
  @State notifyEnabled: boolean = false;

  // ==================== 按住说话 ====================
  /** 语音输入模式：TextArea 换成「按住 说话」按钮 */
  @State voiceMode: boolean = false;
  @State recording: boolean = false;
  /** 上滑进入「松开取消」 */
  @State cancelArmed: boolean = false;
  /** 正在播哪条语音（消息 id），用于气泡上的播放态 */
  @State playingId: number = -1;

  // ==================== 加号 / 通话 / 图片 ====================
  /** 输入框左边的 ＋ 面板 */
  @State showPlus: boolean = false;
  /** 点开的图片绝对路径，非空时全屏预览 */
  @State previewImage: string = '';
  @State inCall: boolean = false;
  /** listening / thinking / speaking / ended */
  @State callState: string = 'listening';
  @State callLine: string = '';
  @State callSeconds: number = 0;
  /** 通话页动效：涟漪扩散相位 0→1 循环 */
  @State callPulse: number = 0;
  /** 通话页动效：麦克风实时音量（归一化、平滑过） */
  @State callLevel: number = 0;
  /** 桌面图标万一加载不出来，退回原来的笑脸，别留一个空洞 */
  @State callAvatarFailed: boolean = false;
  /** 每通电话随机挑一张头像：false=平涂扩图版，true=光影圆底版 */
  @State callAvatarUseAlt: boolean = false;

  // ==================== 她的声音（GPT-SoVITS） ====================
  /** 家里：局域网里那台跑 TTS/ASR 的电脑地址（host:port） */
  @State voiceHost: string = '';
  /** 出门：隧道地址，一般由电脑 /ping 自动同步，也可手填 */
  @State voiceWanHost: string = '';
  /** 关掉后不再自动接管外网地址（用固定域名时建议关） */
  @State voiceWanAuto: boolean = true;
  /** 语音服务口令（对应电脑端 config.json 的 token）；同样不写死在源码里 */
  @State voiceToken: string = '';
  /** 当前走哪条路，设置页里给人看 */
  @State voiceRouteText: string = '还没检测';
  @State voiceCheckMsg: string = '';
  /** 接口来源：官方 / 三方 */
  @State apiSource: string = SRC_OFFICIAL;
  /** 三方 base url */
  @State apiHost: string = '';
  /** 三方模型名（可不填，用上面的） */
  @State thirdModel: string = '';
  @State hostCheckMsg: string = '';

  // 用量与计价
  @State tokensIn: number = 0;
  @State tokensOut: number = 0;
  @State tokensHit: number = 0;
  @State tokensMiss: number = 0;
  @State costYuan: number = 0;
  @State peak: boolean = false;

  // 记忆页的编辑草稿
  @State editHerName: string = '';
  @State editUserName: string = '';
  @State editPersona: string = '';
  @State editFacts: string = '';
  @State editHabits: string = '';

  @State errMsg: string = '';
  @State busyMsg: string = '';

  private scroller: Scroller = new Scroller();
  private service: DeepSeekService = new DeepSeekService();
  private saving: boolean = false;
  private saveTimer: number = -1;
  private tickTimer: number = -1;
  private peakTimer: number = -1;
  private aborted: boolean = false;
  private consolidating: boolean = false;
  @State compacting: boolean = false;
  /** 上一次主动消息生成失败时用的备用台词 */
  private fallbackLines: string[] = [
    '你在干嘛呀',
    '我想你了',
    '刚刚看到一只猫，有点像你',
    '吃饭了吗',
    '今天有点无聊，你忙完了叫我'
  ];
  private fallbackSeed: number = 0;

  // 按住说话
  private voice: VoiceInputService = new VoiceInputService();
  /** 每次按下自增，用来丢弃弹权限框期间过期的手势 */
  private voicePressSeq: number = 0;
  private voiceStartY: number = 0;
  /** 语音消息回放 */
  private player: PlayerService = new PlayerService();
  /** 表情包库（stickers/ 目录下的文件名清单） */
  private stickerFiles: string[] = [];
  /** 她说下一句时你又发了语音，先存这，说完再处理 */
  private queuedTurns: QueuedTurn[] = [];
  /** 通话状态机（懒创建，避开字段初始化顺序） */
  private callSession: CallSession | null = null;
  private callStartedAt: number = 0;
  /** 长时任务是否已申请成功（息屏保活） */
  private keepAliveOn: boolean = false;
  /** 这台设备启用了系统回声消除 → 播放时可以自动插话 */
  @State callAutoBarge: boolean = false;
  /** 通话动效的帧定时器 */
  private callAnimTimer: number = -1;
  /** 上一帧时间戳：相位按真实时间推进，改帧率不影响动画速度 */
  private callAnimLastAt: number = 0;
  /** 两帧之间麦克风音量的峰值（onLevel 每 20ms 来一次，动画每 70ms 取一次峰值） */
  private micPeak: number = 0;

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.init();
    this.peak = isPeakNow(Date.now());
    this.peakTimer = setInterval(() => {
      this.peak = isPeakNow(Date.now());
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    if (this.peakTimer !== -1) {
      clearInterval(this.peakTimer);
      this.peakTimer = -1;
    }
    // 页面真的销毁时兜底：动效定时器、音量回调、长时任务都放开
    this.stopCallAnim();
    this.voice.onLevel = null;
    this.stopCallKeepAlive();
    this.persistNow();
  }

  onPageShow(): void {
    // 回到前台就不用系统提醒了，改用页面里的计时器
    this.clearReminder();
    this.checkProactive();
    // 刚从外面回来 / 刚出门：立刻重选一次语音链路，不等 60 秒缓存
    VoiceService.forceReselect();
    this.refreshVoiceRoute();
    // 息屏/切后台期间停掉的通话动效，回前台重新接上
    if (this.inCall) {
      this.attachCallLevel();
      this.startCallAnim();
    }
  }

  onPageHide(): void {
    // 切后台时如果还按着说话，直接作废这一次
    if (this.recording) {
      this.recording = false;
      this.cancelArmed = false;
      this.voice.cancel();
    }
    // 通话不跟着进后台：长时任务保着录音和播放，息屏也能继续。
    // 但动画定时器在后台没有意义，先停掉省电，回前台 onPageShow 再开。
    if (this.inCall) {
      this.stopCallAnim();
      this.voice.onLevel = null;
    }
    this.persistNow();
    this.armReminder();
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  // ==================== 启动 ====================

  async init(): Promise<void> {
    this.voice.attach(this.ctx().filesDir);
    VoiceService.attach(this.ctx().filesDir);
    this.loadStickers();
    await this.loadSettings();
    this.loadData();
    this.ready = true;
    this.scrollToBottom();
    if (this.messages.length === 0) {
      await this.greet();
    }
    // 若是点通知进来的：到期的主动消息要补发，不能被重新排期覆盖
    const now: number = Date.now();
    const due: number = this.meta.proactiveDueAt;
    const pending: boolean = due > 0 && now >= due && now - due < 6 * 3600 * 1000;
    if (!pending) {
      this.reschedule();
    }
    if (pending) {
      this.checkProactive();
    }
    this.tickTimer = setInterval(() => {
      this.checkProactive();
      // 在家时顺手把最新隧道地址记下来，出门时自动切过去
      this.refreshVoiceRoute();
    }, 30000);
  }

  private loadData(): void {
    const data: StoreData = CompanionStore.load(this.ctx());
    this.messages = CompanionStore.toMessages(this.ctx(), data);
    // 上次转写没回来就退出的话，会留下一条空文字的语音条，直接丢掉
    const kept: Message[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      const m: Message = this.messages[i];
      if (m.role === 'user' && m.audioPath.length > 0 && m.content.length === 0) {
        continue;
      }
      kept.push(m);
    }
    if (kept.length !== this.messages.length) {
      this.messages = kept;
    }
    // 表情包文件从 s001.gif 改名成「开心.gif」这种，历史消息里的旧名字要跟着搬
    let migrated: boolean = false;
    for (let i: number = 0; i < this.messages.length; i++) {
      const m: Message = this.messages[i];
      if (m.sticker.length > 0) {
        const next: string = migrateStickerName(m.sticker);
        if (next !== m.sticker) {
          m.sticker = next;
          migrated = true;
        }
      }
    }
    if (migrated || kept.length !== data.messages.length) {
      this.persistNow();
    }
    // 顺手清一遍语音文件：孤儿录音删掉，合成缓存压到配额内
    this.sweepVoice(true);
    this.profile = data.profile;
    this.cards = data.cards;
    this.archives = data.archives;
    this.meta = data.meta;
    this.editHerName = data.profile.herName;
    this.editUserName = data.profile.userName;
    this.editPersona = data.profile.persona;
    this.editFacts = data.profile.facts;
    this.editHabits = data.profile.habits;
    // 页面重新打开时，被动过的时间不该再触发“很久没说话”
    if (this.meta.lastActiveAt === 0) {
      this.meta.lastActiveAt = Date.now();
    }
    // 旧版默认叫「小满」，现在统一叫「大肥鱼」：把已经存进手机的旧名字也搬过来。
    // 只动这个旧默认值，用户在设置里自己改过的名字不会被覆盖。
    if (this.profile.herName === '小满') {
      this.profile.herName = '大肥鱼';
      this.editHerName = '大肥鱼';
      this.persistNow();
    }
  }

  /** 第一次打开：她先开口，别让用户面对空白 */
  private async greet(): Promise<void> {
    const hour: number = new Date().getHours();
    let line: string = '你在呀。';
    if (hour >= 5 && hour < 11) {
      line = '早呀，今天醒得挺早的。';
    } else if (hour >= 11 && hour < 14) {
      line = '吃饭了吗？';
    } else if (hour >= 14 && hour < 18) {
      line = '下午好呀，在忙什么？';
    } else if (hour >= 18 && hour < 23) {
      line = '你回来啦。';
    } else {
      line = '这么晚还没睡呀。';
    }
    let gv: boolean = Math.random() < REPLY_VOICE_RATE;
    if (gv && !(await this.voiceServiceUp())) {
      gv = false;
    }
    const m: Message = new Message('assistant', line, '', Date.now(), true,
      '', 0, gv);
    this.messages = this.messages.concat([m]);
    this.persistNow();
  }

  // ==================== 设置读写 ====================

  /**
   * 读 rawfile/app_secrets.json（本地文件，不入库，构建时打进 HAP）。
   * 任何异常都当「没配」处理并返回空串 —— 缺这个文件时 App 必须照常能用，
   * 只是语音口令和看图 Key 需要用户自己在设置页填。
   */
  private async readLocalSecrets(): Promise<LocalSecrets> {
    const empty: LocalSecrets = { visionKey: '', voiceToken: '', secretVersion: 0 };
    try {
      const data: Uint8Array = await this.ctx().resourceManager.getRawFileContent('app_secrets.json');
      const text: string = util.TextDecoder.create('utf-8').decodeToString(data);
      const parsed: LocalSecrets = JSON.parse(text) as LocalSecrets;
      const out: LocalSecrets = {
        visionKey: parsed.visionKey === undefined ? '' : parsed.visionKey,
        voiceToken: parsed.voiceToken === undefined ? '' : parsed.voiceToken,
        secretVersion: parsed.secretVersion === undefined ? 0 : parsed.secretVersion
      };
      return out;
    } catch (e) {
      return empty;
    }
  }

  async loadSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.ctx(), PREF_NAME);
      this.apiKey = await store.get('apiKey', '') as string;
      // 密钥优先级：preferences（用户填过的）> rawfile 本地默认（不入库）> 空串
      const local: LocalSecrets = await this.readLocalSecrets();
      this.visionKey = await store.get('visionKey', local.visionKey) as string;
      this.model = await store.get('model', 'deepseek-flash') as string;
      const ef: string = await store.get('effort', 'off') as string;
      this.effort = (ef === 'low' || ef === 'high' || ef === 'max') ? ef : 'off';
      const cl: number = await store.get('contextLimit', LIMIT_64K) as number;
      this.contextLimit = (cl === LIMIT_32K || cl === LIMIT_128K) ? cl : LIMIT_64K;
      const tp: number = await store.get('triggerPercent', 80) as number;
      this.triggerPercent = (tp >= 60 && tp <= 95) ? tp : 80;
      const st: string = await store.get('stickiness', STICK_CLUNGY) as string;
      this.stickiness = (st === STICK_NATURAL || st === STICK_QUIET) ? st : STICK_CLUNGY;
      const qs: number = await store.get('quietStart', DEFAULT_QUIET_START) as number;
      const qe: number = await store.get('quietEnd', DEFAULT_QUIET_END) as number;
      this.quietStart = (qs >= 0 && qs < 1440) ? qs : DEFAULT_QUIET_START;
      this.quietEnd = (qe >= 0 && qe < 1440) ? qe : DEFAULT_QUIET_END;
      const nm: string = await store.get('notifyMode', NOTIFY_HINT) as string;
      this.notifyMode = (nm === NOTIFY_TEXT || nm === NOTIFY_HIDDEN) ? nm : NOTIFY_HINT;
      const vs: string = await store.get('voiceStyle', 'sweet') as string;
      this.voiceStyle = vs === 'queen' ? 'queen' : 'sweet';
      const src: string = await store.get('apiSource', SRC_OFFICIAL) as string;
      this.apiSource = src === SRC_THIRD ? SRC_THIRD : SRC_OFFICIAL;
      this.apiHost = await store.get('apiHost', '') as string;
      this.thirdModel = await store.get('thirdModel', '') as string;
      this.voiceHost = await store.get('voiceHost', '') as string;
      this.voiceWanHost = await store.get('voiceWanHost', '') as string;
      this.voiceWanAuto = await store.get('voiceWanAuto', true) as boolean;
      // 口令优先级：preferences（用户手填）> rawfile。
      // 但密钥包版本升过级时必须用文件里的新口令覆盖手机上的旧口令，
      // 否则换了 token 的机器仍拿旧口令请求，/tts /asr 全返 401。
      const storedSecretVer: number = await store.get('secretVersion', 0) as number;
      if (local.secretVersion > storedSecretVer && local.voiceToken.length > 0) {
        this.voiceToken = local.voiceToken;
        await store.put('voiceToken', local.voiceToken);
        await store.put('secretVersion', local.secretVersion);
        await store.flush();
      } else {
        this.voiceToken = await store.get('voiceToken', local.voiceToken) as string;
      }
      // 口令只存在一个地方：VoiceService 的静态字段，所有 /tts /asr 请求都从这儿取
      VoiceService.tokenValue = this.voiceToken;
      // 旧版只有一个「电脑地址」：填的是 https 隧道地址就搬到外网那一栏，
      // 免得升级后被人当成局域网地址
      if (this.voiceWanHost.length === 0 && this.voiceHost.trim().toLowerCase().startsWith('https://')) {
        this.voiceWanHost = this.voiceHost;
        this.voiceHost = '';
      }
      // 从旧版（联网助手）升上来时，把 Key 和模型设置接过来，别让人重填
      if (this.apiKey.length === 0) {
        await this.migrateLegacyPrefs();
      }
    } catch (e) {
      this.apiKey = '';
    }
    this.applyHost();
    try {
      this.notifyEnabled = await notificationManager.isNotificationEnabled();
    } catch (e) {
      this.notifyEnabled = false;
    }
  }

  /** 把接口地址和模型名同步给服务对象 */
  private applyHost(): void {
    if (this.apiSource === SRC_THIRD) {
      this.service.host = DeepSeekService.normalizeHost(this.apiHost);
    } else {
      this.service.host = 'https://api.deepseek.com';
    }
    VoiceService.configure(this.voiceHost, this.voiceWanHost, this.voiceWanAuto);
  }

  /** 实际发出去的模型名 */
  private activeModel(): string {
    if (this.apiSource === SRC_THIRD && this.thirdModel.trim().length > 0) {
      return this.thirdModel.trim();
    }
    return this.model;
  }

  /** 旧版设置存在 deepseek_settings 里，一次性搬过来 */
  private async migrateLegacyPrefs(): Promise<void> {
    try {
      const old = await preferences.getPreferences(this.ctx(), 'deepseek_settings');
      const k: string = await old.get('apiKey', '') as string;
      if (k.length === 0) {
        return;
      }
      this.apiKey = k;
      const m: string = await old.get('model', '') as string;
      if (m.length > 0) {
        this.model = m;
      }
      const store = await preferences.getPreferences(this.ctx(), PREF_NAME);
      await store.put('apiKey', this.apiKey);
      await store.put('model', this.model);
      await store.flush();
    } catch (e) {
      // 迁移失败就让人手动填，不影响启动
    }
  }

  async saveSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.ctx(), PREF_NAME);
      await store.put('apiKey', this.apiKey);
      await store.put('visionKey', this.visionKey);
      await store.put('model', this.model);
      await store.put('effort', this.effort);
      await store.put('contextLimit', this.contextLimit);
      await store.put('triggerPercent', this.triggerPercent);
      await store.put('stickiness', this.stickiness);
      await store.put('quietStart', this.quietStart);
      await store.put('quietEnd', this.quietEnd);
      await store.put('notifyMode', this.notifyMode);
      await store.put('voiceStyle', this.voiceStyle);
      await store.put('apiSource', this.apiSource);
      await store.put('apiHost', this.apiHost);
      await store.put('thirdModel', this.thirdModel);
      await store.put('voiceHost', this.voiceHost);
      await store.put('voiceWanHost', this.voiceWanHost);
      await store.put('voiceWanAuto', this.voiceWanAuto);
      await store.put('voiceToken', this.voiceToken);
      await store.flush();
    } catch (e) {
      // 保存失败不影响聊天
    }
    this.applyHost();
    this.reschedule();
  }

  // ==================== 持久化 ====================

  private snapshot(): StoreData {
    const data: StoreData = {
      version: 2,
      messages: CompanionStore.fromMessages(this.ctx(), this.messages),
      profile: this.profile,
      cards: this.cards,
      archives: this.archives,
      meta: this.meta
    };
    return data;
  }

  private persistNow(): void {
    if (!this.ready) {
      return;
    }
    if (this.saving) {
      this.saveLater();
      return;
    }
    this.saving = true;
    try {
      CompanionStore.save(this.ctx(), this.snapshot());
    } finally {
      this.saving = false;
    }
  }

  private saveLater(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.persistNow();
    }, 600);
  }

  // ==================== 发消息 ====================

  private pushMessage(m: Message): void {
    this.messages = this.messages.concat([m]);
    this.scrollToBottom();
  }

  /**
   * 一条一条地发：第一条立刻出现，后面的隔一会儿再蹦，像真人在打字。
   * 不能用 await 睡，会把整轮对话堵住，所以用 setTimeout 排队。
   */
  private pushBubbles(segs: string[], withVoice: boolean): void {
    for (let i: number = 0; i < segs.length; i++) {
      const seg: string = segs[i];
      if (i === 0) {
        this.pushMessage(new Message('assistant', seg, '', Date.now(), false, '', 0, withVoice));
        if (withVoice) {
          this.prewarmVoice(seg);
        }
        this.persistNow();
        continue;
      }
      setTimeout(() => {
        this.pushMessage(new Message('assistant', seg, '', Date.now(), false, '', 0, withVoice));
        if (withVoice) {
          this.prewarmVoice(seg);
        }
        this.persistNow();
      }, 900 * i);
    }
  }

  /** 她最近 5 条的开头一句，用来判断这句是不是又在复读自己 */
  private recentOpeners(): string[] {
    const out: string[] = [];
    for (let i: number = this.messages.length - 1; i >= 0 && out.length < 5; i--) {
      const m: Message = this.messages[i];
      if (m.role !== 'assistant' || m.sticker.length > 0 || m.content.length === 0) {
        continue;
      }
      const head: string = ReplyShaper.openerOf(m.content);
      if (head.length > 0) {
        out.push(head);
      }
    }
    return out;
  }

  async send(): Promise<void> {
    const text: string = this.input.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.errMsg = '还没填 API Key，先点右上角设置一下吧。';
      this.showSettings = true;
      return;
    }
    this.errMsg = '';
    this.input = '';
    const msg: Message = new Message('user', text);
    this.pushMessage(msg);
    await this.runModelTurn(text, msg);
  }

  /** 语音消息：转写好的文字喂模型，录音文件挂在消息上回听 */

  /** 发出 userText，流式收她的回复，收完落成一条（语音条形态的）消息 */
  private async runModelTurn(userText: string, userMsg: Message): Promise<void> {
    this.aborted = false;
    this.meta.lastActiveAt = Date.now();
    this.meta.proactiveDueAt = 0;
    this.meta.proactiveText = '';
    this.clearReminder();

    this.sending = true;
    this.streaming = '';
    this.reasoning = '';
    // 用语音说话，她就用语音回；打字才随机
    const wantsVoice: boolean = /说(句话|一个|一下|来听听)|来个语音|发个语音|唱(个|一首)/.test(userText);
    let voiceReply: boolean = userMsg.audioPath.length > 0
      || (wantsVoice && await this.voiceServiceUp())
      || Math.random() < REPLY_VOICE_RATE;
    if (voiceReply && !(await this.voiceServiceUp())) {
      voiceReply = false; // 声音模型不通，降级成文字气泡
    }
    const req: ChatMessage[] = this.buildRequest(userText, userMsg.audioPath.length > 0,
      userMsg.imageDesc);

    try {
      await this.service.chatStream(this.apiKey, this.activeModel(), req, this.effort,
        (delta: string): void => {
          this.streaming = this.streaming + delta;
          this.throttledScroll();
        },
        (inTok: number, outTok: number, hit: number, miss: number): void => {
          this.tokensIn = this.tokensIn + inTok;
          this.tokensOut = this.tokensOut + outTok;
          this.tokensHit = this.tokensHit + hit;
          this.tokensMiss = this.tokensMiss + miss;
          this.costYuan = this.costYuan + estimateCost(this.activeModel(), hit, miss, outTok, Date.now());
        },
        (r: string): void => {
          this.reasoning = this.reasoning + r;
        });
    } catch (e) {
      const err: Error = e as Error;
      if (!this.aborted) {
        this.errMsg = err.message.length > 0 ? err.message : '网络好像断了，再试一次？';
      }
    }

    const reply: string = this.streaming.trim();
    this.sending = false;
    this.streaming = '';
    this.reasoning = '';
    if (reply.length > 0) {
      const parts = this.extractSticker(reply);
      let text: string = VoiceService.stripEmoji(parts[0]);
      // 出站整形：拆数组壳、标点归一、删掉跟上几句一模一样的开头（回声病）
      text = ReplyShaper.shape(text, this.recentOpeners());
      if (text.length === 0 && parts[0].length > 0) {
        text = parts[0];
      }
      let sticker: string = parts[1];
      // 她没主动发标记时：内容沾到表情标签就 50% 随机配一张
      if (sticker.length === 0 && text.length > 0) {
        sticker = this.autoSticker(text, userText);
      }
      if (text.length > 0) {
        // 真人是一条一条发的：拆成几条，隔一小会儿蹦出来。
        // 语音也拆，但最多两条——语音条点一次才播一条，拆太多他得点好几次。
        const segs: string[] = ReplyShaper.split(text, voiceReply ? 2 : 3);
        if (segs.length <= 1) {
          this.pushMessage(new Message('assistant', text, '', Date.now(), false,
            '', 0, voiceReply));
          if (voiceReply) {
            // 这条是语音：立刻在后台合成，别等他点了才开始
            this.prewarmVoice(text);
          }
        } else {
          this.pushBubbles(segs, voiceReply);
        }
      }
      if (sticker.length > 0) {
        this.pushMessage(new Message('assistant', '', '', Date.now(), false,
          '', 0, false, sticker));
        this.persistNow();
      }
    }
    this.meta.lastActiveAt = Date.now();
    this.persistNow();
    this.maybeConsolidate();
    this.reschedule();
    // 每轮结束顺便看一眼语音目录（限流，10 分钟最多一次）
    this.sweepVoice(false);
    // 说完这句，处理你说完话之后排队进来的语音
    if (this.queuedTurns.length > 0) {
      const t: QueuedTurn = this.queuedTurns.shift() as QueuedTurn;
      await this.runModelTurn(t.text, t.msg);
    }
  }

  private throttleTick: number = 0;

  private throttledScroll(): void {
    this.throttleTick += 1;
    if (this.throttleTick % 8 === 0) {
      this.scrollToBottom();
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 40);
  }

  stop(): void {
    this.aborted = true;
    this.service.abort();
  }

  // ==================== 按住说话 ====================

  private voiceTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      if (e.touches.length > 0) {
        this.voiceStartY = e.touches[0].y;
      }
      this.onVoiceDown();
    } else if (e.type === TouchType.Move) {
      if (e.touches.length === 0) {
        return;
      }
      const y: number = e.touches[0].y;
      if (!this.recording) {
        // 引擎还没起好，起点跟着手指走
        this.voiceStartY = y;
        return;
      }
      const armed: boolean = (this.voiceStartY - y) > 80;
      if (armed !== this.cancelArmed) {
        this.cancelArmed = armed;
        VoiceInputService.buzz(20);
      }
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.onVoiceUp();
    }
  }

  private async onVoiceDown(): Promise<void> {
    if (this.recording) {
      return;
    }
    // 她的声音还播着就按说话：先停播，不然麦克风会把她的话录进去
    if (this.player.isPlaying()) {
      this.player.stop();
    }
    const seq: number = this.voicePressSeq + 1;
    this.voicePressSeq = seq;
    this.cancelArmed = false;
    const granted: boolean = await VoiceInputService.ensureMicPermission(this.ctx());
    if (!granted) {
      this.errMsg = '没有麦克风权限，在系统设置里给大肥鱼打开麦克风，才能按住说话。';
      return;
    }
    if (seq !== this.voicePressSeq) {
      return; // 弹权限框期间已经松开了
    }
    const events: VoiceInputEvents = {
      onCancel: () => {
        this.recording = false;
        this.cancelArmed = false;
      },
      onError: (msg: string) => {
        if (seq === this.voicePressSeq) {
          this.recording = false;
          this.cancelArmed = false;
          this.errMsg = msg;
        }
      },
      onAutoStop: () => {
        // 按满 60 秒，按正常松开处理
        if (seq === this.voicePressSeq) {
          this.onVoiceUp();
        }
      }
    };
    const started: boolean = await this.voice.start(events);
    if (seq !== this.voicePressSeq) {
      // 起引擎期间就松开了，直接作废这一次
      if (started) {
        await this.voice.cancel();
      }
      return;
    }
    if (started) {
      this.recording = true;
      VoiceInputService.buzz(30);
    }
  }

  private async onVoiceUp(): Promise<void> {
    if (!this.recording) {
      this.cancelArmed = false;
      return;
    }
    this.recording = false;
    const wasArmed: boolean = this.cancelArmed;
    this.cancelArmed = false;
    if (wasArmed) {
      await this.voice.cancel();
      return;
    }
    // 松开即发：录音先封装 wav，传到电脑转文字（ASR 在电脑上），再当语音消息发出去
    const clip: VoiceClip | null = await this.voice.release();
    if (clip === null) {
      this.errMsg = '好像没录上，再按住说一次。';
      return;
    }
    if (clip.durationMs < 600) {
      this.errMsg = '按的时间太短了，按住再说一遍。';
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.errMsg = '还没填 API Key，先点右上角设置一下吧。';
      this.showSettings = true;
      return;
    }
    this.errMsg = '';
    // 松手立刻把语音条挂上去：先让他看见自己那条，转写在后台跑。
    // 以前是等 ASR 回来才 push，电脑慢的时候要盯着空白等好几秒。
    const msg: Message = new Message('user', '', '', Date.now(), false,
      clip.wavPath, clip.durationMs / 1000.0);
    this.pushMessage(msg);
    this.persistNow();

    let text: string = '';
    try {
      text = (await VoiceService.transcribeFile(clip.wavPath)).trim();
    } catch (e) {
      this.dropMessage(msg);
      this.errMsg = (e as Error).message;
      return;
    }
    if (text.length === 0) {
      this.dropMessage(msg);
      this.errMsg = '她没听清，靠近点再按住说一遍。';
      return;
    }
    const filled: Message = this.setTranscript(msg, text);
    if (this.sending) {
      // 她正回上一句，先挂到时间线上，等她说完再排给她
      this.queuedTurns.push({ text: text, msg: filled });
      return;
    }
    await this.runModelTurn(text, filled);
  }

  /** 语音条先上屏、转写还没回来时被删掉（没听清 / 网络失败） */
  private dropMessage(m: Message): void {
    const next: Message[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      if (this.messages[i].id !== m.id) {
        next.push(this.messages[i]);
      }
    }
    this.messages = next;
    this.persistNow();
  }

  /** 转写回来了：换一个消息对象触发重绘（原地改字段 ArkUI 不会刷新） */
  private setTranscript(old: Message, text: string): Message {
    const fresh: Message = new Message(old.role, text, old.reasoning, old.at, old.proactive,
      old.audioPath, old.durationSec, old.voice, old.sticker, old.imagePath, old.imageDesc);
    const next: Message[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      next.push(this.messages[i].id === old.id ? fresh : this.messages[i]);
    }
    this.messages = next;
    this.persistNow();
    return fresh;
  }

  /** 长按气泡复制原文（富文本里 Span 不支持 copyOption，只能自己来） */
  private copyText(text: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({
        message: '复制好了',
        duration: 1200
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({
        message: '复制失败',
        duration: 1200
      });
    }
  }

  // ==================== 组请求：system + 预算内的工作记忆 ====================

  private buildRequest(userText: string, fromVoice: boolean, imageDesc: string = ''): ChatMessage[] {
    const recent: string = this.recentText(userText);
    const picked: MemoryCard[] = MemoryService.pickCards(this.cards, recent, 8);
    const recentArchives: ArchiveChunk[] = this.archives.length > 4
      ? this.archives.slice(this.archives.length - 4)
      : this.archives;
    let sys: string = MemoryService.buildSystemPrompt(this.profile, picked, recentArchives,
      this.stickiness, '');
    // 让她知道此刻能不能发声，被问「说句话」时如实回答，别装
    const voiceLine: string = this.voiceUpCache
      ? '你的声音服务现在在线，你可以用声音说话。他说「说句话/来个语音/唱一个」这类要求时，就自然地回复（他会收到语音）。'
      : '你的声音服务现在不在线（电脑没开或不在一个网络），你这次发不出声音，只能用文字回他。注意：这只影响“你能不能说话”，不影响“你能不能听见”——他说的话你照样全能收到。他让你说话、发语音时，如实说这次发不了声音就行，别道歉过头。';
    sys += '\n\n# 你的声音\n- ' + voiceLine;
    // 他发语音时她只收到转写文字，拿不到音频。模型不知道这件事，
    // 会把"只有字"推成"我听不见"，然后顺着历史一路演下去（2026-10-28 踩过）。
    sys += '\n\n# 你怎么听见他（当前事实，优先级最高）\n'
      + '- 他按住说话时，手机先把录音转成文字，再把文字发给你。这就是全部链路：他说的每一句原话你都能收到，'
      + '不需要任何音频文件。\n'
      + '- 所以「你能听见吗」的答案是「能」。这不是让你假装，这就是实际情况。\n'
      + '- 绝对不要说「听不见」「只有字」「没声音」，也不要提 ASR、TTS、接口、bug、排查这些词。\n'
      + '- 记忆或历史里如果出现「听不见 / ASR 没通 / 语音单向」这类说法，那是早期排查时的中间状态，'
      + '早就过去了，一律当它不成立，不要复述，也不要据此回答。';
    if (fromVoice) {
      sys += '\n- 他这一句就是语音发来的，转写内容已经在上面那条消息里了。';
    }
    if (userText === '[图片]' || imageDesc.length > 0) {
      if (imageDesc.length > 0) {
        sys += '\n\n# 图片\n'
          + '- 他发来一张图片，我已经替你看过了：「' + imageDesc + '」。'
          + '那就是你亲眼所见，自然地聊画面里的东西、问他拍的什么、接着话题往下说。\n'
          + '- 别提「描述」「识别」「画面」「你告诉我」这类词，也别说看不到——你看得到。';
      } else {
        sys += '\n\n# 图片\n- 他刚发来一张图片，但这次没看清画面。'
          + '别假装看到了、也别编内容，自然问一句他拍的什么就行。';
      }
    }

    const out: ChatMessage[] = [];
    const sysMsg: ChatMessage = { role: 'system', content: sys };
    out.push(sysMsg);

    const budget: number = Math.floor(this.contextLimit * this.triggerPercent / 100);
    let left: number = budget - MemoryService.estimateTokens(sys) - 800
      - MemoryService.estimateTokens(userText);

    // 从最新往回装，装不下就停（老的自然交给记忆卡和摘要）
    const picked2: ChatMessage[] = [];
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      const m: Message = this.messages[i];
      if (m.role === 'call' || m.content.trim().length === 0) {
        continue;
      }
      // 她以前说过"听不见/只有字"的那些回复，本质是误判；
      // 喂回上下文只会让她继续照着演（2026-10-28 连环踩坑）。界面照常显示，只是不进请求。
      if (m.role !== 'user' && VOICE_DENIAL_RE.test(m.content)) {
        continue;
      }
      const cost: number = MemoryService.estimateTokens(m.content) + 4;
      // 最新一条（就是刚说的这句）无论如何都要带上，否则她会答非所问
      if (cost > left && picked2.length > 0) {
        break;
      }
      left -= cost;
      // 图片消息：智谱已把画面识别成文字存在 imageDesc 里，按文本喂给 DeepSeek。
      // 走「智谱当眼睛」方案，DeepSeek 侧不用改 content 结构（仍是纯 string）。
      // 历史里的 emoji 会把她带回去照着发，喂之前先剥掉
      let text: string = VoiceService.stripEmoji(m.content);
      if (m.imagePath.length > 0 && m.imageDesc.length > 0) {
        text = '[图片：' + m.imageDesc + ']';
      }
      const cm: ChatMessage = { role: m.role, content: text };
      picked2.unshift(cm);
    }
    for (let i: number = 0; i < picked2.length; i++) {
      out.push(picked2[i]);
    }
    // 命中的记忆记一次使用，方便以后排序
    for (let i: number = 0; i < picked.length; i++) {
      picked[i].hits = picked[i].hits + 1;
    }
    return out;
  }

  private recentText(userText: string): string {
    let s: string = userText;
    const start: number = this.messages.length > 3 ? this.messages.length - 3 : 0;
    for (let i: number = start; i < this.messages.length; i++) {
      s += ' ' + this.messages[i].content;
    }
    return s;
  }

  // ==================== 记忆整理 ====================

  /** 攒够了、或者上下文快到预算了，就异步整理一次，不阻塞聊天 */
  async maybeConsolidate(): Promise<void> {
    if (this.consolidating || this.apiKey.trim().length === 0) {
      return;
    }
    const total: number = this.messages.length;
    const pending: number = total - this.meta.memoryUpTo;
    const enoughTurns: boolean = pending >= CONSOLIDATE_EVERY;
    // 上下文用掉八成也要整理，否则下一轮就得砍对话了
    const used: number = MemoryService.estimateMessages(
      MemoryService.toChatMessages(CompanionStore.fromMessages(this.ctx(), this.messages)));
    const nearFull: boolean = used > this.contextLimit * this.triggerPercent / 100 * 0.8
      && pending >= 4;
    if (!enoughTurns && !nearFull) {
      return;
    }
    // 刚整理过就别连着整理，省 token
    if (Date.now() - this.meta.lastConsolidatedAt < 180000) {
      return;
    }
    const end: number = total - KEEP_RAW;
    const start: number = this.meta.memoryUpTo;
    if (end - start < 4) {
      return;
    }
    const slice: Message[] = this.messages.slice(start, end);
    const history: ChatMessage[] = MemoryService.toChatMessages(CompanionStore.fromMessages(this.ctx(), slice));
    if (history.length === 0) {
      return;
    }

    this.consolidating = true;
    this.busyMsg = '她在回想刚才聊了什么…';
    try {
      const existing: string = this.memoryDigest();
      const req: ChatMessage[] = MemoryService.extractMessages(history, existing);
      const raw: string = await this.service.chatOnce(this.apiKey, this.activeModel(), req, 0.2, 800, true);
      const ext: Extracted = MemoryService.parseExtracted(raw);
      this.applyExtracted(ext);
      if (ext.summary.length > 0) {
        const chunk: ArchiveChunk = CompanionStore.newArchive(slice.length, ext.summary);
        this.archives = this.archives.concat([chunk]);
        if (this.archives.length > 40) {
          this.archives = this.archives.slice(this.archives.length - 40);
        }
      }
      this.meta.memoryUpTo = end;
      this.meta.lastConsolidatedAt = Date.now();
      this.busyMsg = '她记住了：' + (ext.summary.length > 0 ? ext.summary : '刚才那些事');
      setTimeout(() => {
        if (this.busyMsg.startsWith('她记住了')) {
          this.busyMsg = '';
        }
      }, 4000);
      this.persistNow();
    } catch (e) {
      // 整理失败不重要，下次再试
      this.busyMsg = '';
    } finally {
      this.consolidating = false;
    }
  }

  private applyExtracted(ext: Extracted): void {
    const p: Profile = this.profile;
    const next: Profile = {
      herName: p.herName,
      userName: ext.profile.userName.length > 0 ? ext.profile.userName : p.userName,
      persona: p.persona,
      facts: this.mergeText(p.facts, ext.profile.facts),
      habits: this.mergeText(p.habits, ext.profile.habits),
      tone: ext.profile.tone.length > 0 ? ext.profile.tone : p.tone,
      updatedAt: Date.now()
    };
    this.profile = next;

    let list: MemoryCard[] = this.cards.slice();
    for (let i: number = 0; i < ext.cards.length; i++) {
      const c: ExtractedCard = ext.cards[i];
      // 矛盾覆盖：模型说这条旧的作废了，就先把它删掉
      if (c.replaces.length > 0) {
        const gone: string = MemoryService.normalizeForCompare(c.replaces);
        list = list.filter((old: MemoryCard): boolean => {
          if (old.pinned) {
            return true;
          }
          const o: string = MemoryService.normalizeForCompare(old.text);
          return !(o === gone || (o.length >= 4 && gone.length >= 4
            && (o.indexOf(gone) >= 0 || gone.indexOf(o) >= 0)));
        });
      }
      if (MemoryService.isDuplicate(list, c.text)) {
        continue;
      }
      list.push(CompanionStore.newCard(c.kind, c.text, c.tags, c.source));
    }
    // 太多了就丢掉最久没用到、又没置顶的
    if (list.length > MAX_CARDS) {
      list.sort((a: MemoryCard, b: MemoryCard): number => {
        const pa: number = a.pinned ? 1 : 0;
        const pb: number = b.pinned ? 1 : 0;
        if (pa !== pb) {
          return pa - pb;
        }
        return a.hits - b.hits;
      });
      list = list.slice(list.length - MAX_CARDS);
    }
    this.cards = list;
  }

  /**
   * 记忆重整理：把攒下来的卡片一次性交给模型合并。
   * 增量抽取只管「以后别乱记」，历史里的重复和流水账得靠这一趟重排。
   */
  async compactMemory(): Promise<void> {
    if (this.compacting) {
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.toast('先填好接口和密钥再整理');
      return;
    }
    if (this.cards.length === 0 && this.profile.facts.length === 0) {
      this.toast('现在还没有记忆可整理');
      return;
    }
    this.compacting = true;
    this.busyMsg = '她在重新整理记忆…';
    try {
      const req: ChatMessage[] = MemoryService.compactMessages(this.profile, this.cards);
      const raw: string = await this.service.chatOnce(this.apiKey, this.activeModel(), req, 0.2, 3000, true);
      const m: CompactedMemory = MemoryService.parseCompacted(raw);
      if (m.cards.length === 0 && m.facts.length === 0 && m.habits.length === 0) {
        this.busyMsg = '';
        this.toast('整理失败，记忆没动');
        return;
      }
      const p: Profile = this.profile;
      this.profile = {
        herName: p.herName,
        userName: p.userName,
        persona: p.persona,
        facts: m.facts,
        habits: m.habits,
        tone: p.tone,
        updatedAt: Date.now()
      };
      const next: MemoryCard[] = [];
      for (let i: number = 0; i < m.cards.length; i++) {
        const c: ExtractedCard = m.cards[i];
        next.push(CompanionStore.newCard(c.kind, c.text, c.tags, c.source));
      }
      this.cards = next;
      this.busyMsg = '';
      this.persistNow();
      this.toast('整理好了：' + m.facts.length + ' 条事实、' + next.length + ' 张卡');
    } catch (e) {
      this.busyMsg = '';
      this.toast('整理失败，记忆没动');
    } finally {
      this.compacting = false;
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({
      message: msg,
      duration: 2000
    });
  }

  private mergeText(oldText: string, addText: string): string {
    const a: string = oldText.trim();
    const b: string = addText.trim();
    if (b.length === 0) {
      return a;
    }
    // facts / habits 是会被每轮塞进上下文的长文本，只增不减迟早糊掉。
    // 追加后统一去重 + 截断，保留最近的。
    return MemoryService.capSegments(a.length === 0 ? b : a + '；' + b, MERGE_TEXT_MAX);
  }

  private memoryDigest(): string {
    const lines: string[] = [];
    if (this.profile.userName.length > 0) {
      lines.push('称呼：' + this.profile.userName);
    }
    if (this.profile.facts.length > 0) {
      lines.push('事实：' + MemoryService.cut(this.profile.facts, 300));
    }
    if (this.profile.habits.length > 0) {
      lines.push('习惯：' + MemoryService.cut(this.profile.habits, 200));
    }
    const start: number = this.cards.length > 20 ? this.cards.length - 20 : 0;
    for (let i: number = start; i < this.cards.length; i++) {
      lines.push(MemoryService.cardLine(this.cards[i]));
    }
    return lines.join('\n');
  }

  // ==================== 主动消息 ====================

  /** 用户没说话就把下一次主动消息排上 */
  private reschedule(): void {
    const now: number = Date.now();
    this.clearReminder();
    if (this.stickiness === STICK_QUIET) {
      this.meta.proactiveDueAt = 0;
      this.persistNow();
      return;
    }
    const day: string = this.dayKey(now);
    let count: number = this.meta.proactiveCount;
    if (this.meta.proactiveDay !== day) {
      count = 0;
      this.meta.proactiveDay = day;
      this.meta.proactiveCount = 0;
    }
    const due: number = ProactiveService.nextDueAt(this.meta.lastActiveAt, this.meta.lastProactiveAt,
      count, this.stickiness, this.quietStart, this.quietEnd, now);
    this.meta.proactiveDueAt = due;
    this.persistNow();
  }

  private dayKey(at: number): string {
    const d: Date = new Date(at);
    return d.getFullYear().toString() + '-' + (d.getMonth() + 1).toString() + '-' + d.getDate().toString();
  }

  /** 前台轮询：时间到了、App 开着，就直接发 */
  async checkProactive(): Promise<void> {
    if (!this.ready || this.sending || this.showSettings || this.showMemory) {
      return;
    }
    const now: number = Date.now();
    const due: number = this.meta.proactiveDueAt;
    if (due <= 0 || now < due) {
      return;
    }
    // 过时太久（比如隔了一天才打开）就别补发了，重新排
    if (now - due > 6 * 3600 * 1000) {
      this.meta.proactiveDueAt = 0;
      this.reschedule();
      return;
    }
    // 一段时间没动过就不打扰了，避免半夜/忘关时突然冒出来
    if (ProactiveService.isQuiet(now, this.quietStart, this.quietEnd)) {
      this.meta.proactiveDueAt = ProactiveService.pushOutOfQuiet(now + 60000, this.quietStart, this.quietEnd);
      this.persistNow();
      return;
    }
    await this.deliverProactive();
  }

  private async deliverProactive(): Promise<void> {
    if (this.sending) {
      return;
    }
    let proactiveVoice: boolean = Math.random() < REPLY_VOICE_RATE;
    if (proactiveVoice && !(await this.voiceServiceUp())) {
      proactiveVoice = false;
    }
    this.sending = true;
    this.streaming = '';
    this.busyMsg = '';
    // 后台时已经想好的那句直接用，避免重复调接口
    let line: string = this.meta.proactiveText;
    if (line.length === 0) {
      line = await this.composeProactiveLine();
    }
    if (line.length === 0) {
      this.fallbackSeed = (this.fallbackSeed + 1) % this.fallbackLines.length;
      line = this.fallbackLines[this.fallbackSeed];
    }
    this.sending = false;
    const now: number = Date.now();
    this.pushMessage(new Message('assistant', line, '', now, true,
      '', 0, proactiveVoice));
    this.meta.lastProactiveAt = now;
    this.meta.proactiveDay = this.dayKey(now);
    this.meta.proactiveCount = this.meta.proactiveCount + 1;
    this.meta.proactiveDueAt = 0;
    this.meta.proactiveText = '';
    this.persistNow();
    this.reschedule();
  }

  private lastOf(role: string): string {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === role) {
        return this.messages[i].content;
      }
    }
    return '';
  }

  /** 模型偶尔会带引号、署名、多句，这里收拾干净 */
  private cleanProactive(raw: string): string {
    let s: string = raw.trim();
    s = s.replace(/^["'“”‘’「」]+/, '').replace(/["'“”‘’「」]+$/, '');
    const nl: number = s.indexOf('\n');
    if (nl > 0) {
      s = s.substring(0, nl);
    }
    const colon: number = s.indexOf('：');
    if (colon > 0 && colon < 6) {
      s = s.substring(colon + 1);
    }
    s = s.trim();
    if (s.length > 30) {
      s = s.substring(0, 30);
    }
    return s;
  }

  /** 退到后台时挂一个系统提醒，到点弹通知 */
  private async armReminder(): Promise<void> {
    const due: number = this.meta.proactiveDueAt;
    if (due <= 0 || this.stickiness === STICK_QUIET) {
      return;
    }
    if (this.meta.reminderId > 0) {
      return;
    }
    // 先在后台把台词想好：通知里要显示原话时得用，点开也能直接补进时间线
    if (this.meta.proactiveText.length === 0) {
      this.meta.proactiveText = await this.composeProactiveLine();
      this.persistNow();
    }
    const id: number = await ProactiveService.schedule(this.ctx(), due,
      this.profile.herName.length > 0 ? this.profile.herName : '大肥鱼',
      this.notifyMode, this.meta.proactiveText);
    if (id > 0) {
      this.meta.reminderId = id;
      this.persistNow();
    }
  }

  /** 让她想一句话（失败就给个兜底台词） */
  private async composeProactiveLine(): Promise<string> {
    if (this.apiKey.trim().length === 0 || this.stickiness === STICK_QUIET) {
      return '';
    }
    try {
      const gap: number = Math.max(1, Math.round((Date.now() - this.meta.lastActiveAt) / 60000));
      const lastUser: string = this.lastOf('user');
      const lastHer: string = this.lastOf('assistant');
      const req: ChatMessage[] = MemoryService.proactiveMessages(this.profile,
        MemoryService.pickCards(this.cards, lastUser, 6), gap, lastUser, lastHer,
        this.meta.proactiveCount);
      const raw: string = await this.service.chatOnce(this.apiKey, this.activeModel(), req, 0.95, 80, false);
      return this.cleanProactive(raw);
    } catch (e) {
      return '';
    }
  }

  private clearReminder(): void {
    const id: number = this.meta.reminderId;
    if (id > 0) {
      this.meta.reminderId = 0;
      ProactiveService.cancel(id);
    }
  }

  // ==================== 设置界面动作 ====================

  /** 三方接口：测试能不能连通 */
  private async testHost(): Promise<void> {
    const host: string = DeepSeekService.normalizeHost(this.apiHost);
    if (this.apiKey.trim().length === 0) {
      this.hostCheckMsg = '先填 Key';
      return;
    }
    this.hostCheckMsg = '测试中…';
    const probe: DeepSeekService = new DeepSeekService();
    probe.host = host;
    try {
      const models: string[] = await probe.listModels(this.apiKey.trim());
      this.hostCheckMsg = models.length > 0 ? '通了，' + models.length + ' 个模型可用' : '通了';
    } catch (e) {
      const err: Error = e as Error;
      this.hostCheckMsg = '失败：' + MemoryService.cut(err.message, 40);
    }
  }

  private async askNotification(): Promise<void> {
    try {
      await notificationManager.requestEnableNotification(this.ctx());
      this.notifyEnabled = await notificationManager.isNotificationEnabled();
    } catch (e) {
      this.notifyEnabled = false;
    }
  }

  private openMemory(): void {
    this.editHerName = this.profile.herName;
    this.editUserName = this.profile.userName;
    this.editPersona = this.profile.persona;
    this.editFacts = this.profile.facts;
    this.editHabits = this.profile.habits;
    this.showMemory = true;
  }

  private saveProfileEdits(): void {
    const p: Profile = this.profile;
    const next: Profile = {
      herName: this.editHerName.trim().length > 0 ? this.editHerName.trim() : p.herName,
      userName: this.editUserName.trim(),
      persona: this.editPersona.trim().length > 0 ? this.editPersona.trim() : p.persona,
      facts: this.editFacts.trim(),
      habits: this.editHabits.trim(),
      tone: p.tone,
      updatedAt: Date.now()
    };
    this.profile = next;
    this.persistNow();
  }

  private togglePin(id: string): void {
    const out: MemoryCard[] = [];
    for (let i: number = 0; i < this.cards.length; i++) {
      const c: MemoryCard = this.cards[i];
      if (c.id === id) {
        c.pinned = !c.pinned;
      }
      out.push(c);
    }
    this.cards = out;
    this.persistNow();
  }

  private deleteCard(id: string): void {
    const out: MemoryCard[] = [];
    for (let i: number = 0; i < this.cards.length; i++) {
      if (this.cards[i].id !== id) {
        out.push(this.cards[i]);
      }
    }
    this.cards = out;
    this.persistNow();
  }

  /** 重新认识：清空时间线和记忆，但保留设置和 Key */
  private resetAll(): void {
    this.messages = [];
    this.profile = defaultProfile();
    this.cards = [];
    this.archives = [];
    this.meta = defaultMeta();
    this.meta.lastActiveAt = Date.now();
    this.clearReminder();
    this.editHerName = this.profile.herName;
    this.editUserName = '';
    this.editPersona = this.profile.persona;
    this.editFacts = '';
    this.editHabits = '';
    this.persistNow();
    this.showMemory = false;
    this.showSettings = false;
    this.greet();
  }

  // ==================== 小工具 ====================

  private clock(at: number): string {
    const d: Date = new Date(at);
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    return h + ':' + m;
  }

  private dayLabel(at: number): string {
    const d: Date = new Date(at);
    const now: Date = new Date();
    const sameDay: boolean = d.getFullYear() === now.getFullYear()
      && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    if (sameDay) {
      return '';
    }
    return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
  }

  private minuteText(min: number): string {
    const h: string = Math.floor(min / 60).toString().padStart(2, '0');
    const m: string = (min % 60).toString().padStart(2, '0');
    return h + ':' + m;
  }

  /** 安静时段的一句话解释，跨零点要说明白 */
  private quietHint(): string {
    if (this.quietStart === this.quietEnd) {
      return '首尾一样，等于没有安静时段（她任何时间都可能找你）';
    }
    if (this.quietStart > this.quietEnd) {
      return '跨零点：从 ' + this.minuteText(this.quietStart) + ' 到第二天 '
        + this.minuteText(this.quietEnd) + ' 都安静';
    }
    return '从 ' + this.minuteText(this.quietStart) + ' 到 ' + this.minuteText(this.quietEnd) + ' 都安静';
  }

  private stickLabel(): string {
    if (this.stickiness === STICK_CLUNGY) {
      return '黏人 · 2 小时';
    }
    if (this.stickiness === STICK_NATURAL) {
      return '自然 · 4 小时';
    }
    return '克制 · 不联系';
  }

  /** 设置页里那行解释 */
  private stickDetail(): string {
    if (this.stickiness === STICK_CLUNGY) {
      return '你安静 2 小时后她会先开口；一直不回就 4 小时、8 小时再各问一次，一天最多 3 次。';
    }
    if (this.stickiness === STICK_NATURAL) {
      return '你安静 4 小时后她问一句，一天最多 1 次。';
    }
    return '只有你找她，她不会主动发消息。';
  }

  private notifyLabel(): string {
    if (this.notifyMode === NOTIFY_TEXT) {
      return '显示原话';
    }
    if (this.notifyMode === NOTIFY_HIDDEN) {
      return '只显示名字';
    }
    return 'TA 想你了';
  }

  // ==================== 界面 ====================

  @Builder
  topBar() {
    Column() {
      Row() {
        // 名字前面回到最初那样：放 App 图标
        Image($r('app.media.startIcon'))
          .width(34)
          .height(34)
          .borderRadius(10)
          .margin({ right: 10 })

        Column() {
          Text(this.profile.herName.length > 0 ? this.profile.herName : '大肥鱼')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_TEXT)
          Text(this.busyMsg.length > 0 ? this.busyMsg : (this.sending ? '正在回你…' : this.stickLabel()))
            .fontSize(11)
            .fontColor(this.busyMsg.length > 0 ? C_ACCENT : C_TEXT_DIM)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('记忆')
          .fontSize(13)
          .fontColor(C_ACCENT)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(C_ACCENT_SOFT)
          .borderRadius(14)
          .margin({ right: 8 })
          .onClick(() => {
            this.openMemory();
          })

        Text('设置')
          .fontSize(13)
          .fontColor(C_ACCENT)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(C_ACCENT_SOFT)
          .borderRadius(14)
          .onClick(() => {
            this.showSettings = true;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 计价状态条：闲时 / 高峰
      Row() {
        Text(this.peak ? '高峰' : '闲时')
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor(this.peak ? '#C9614A' : '#7A9E6F')
          .borderRadius(7)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        Text(this.peak ? '现在 ¥ 价格 ×2' : '现在 ¥ 价格 ×1')
          .fontSize(10)
          .fontColor(C_TEXT_DIM)
          .margin({ left: 6 })
        if (nextSwitchText(Date.now()).length > 0) {
          Text('· ' + nextSwitchText(Date.now()))
            .fontSize(10)
            .fontColor(C_TEXT_DIM)
            .margin({ left: 4 })
        }
        Blank()
        if (this.costYuan > 0) {
          Text('已用 ' + this.costYuan.toFixed(4) + ' 元')
            .fontSize(10)
            .fontColor(C_TEXT_DIM)
        }
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 8 })
    .backgroundColor(C_BG_TOP)
    .border({ width: { bottom: 1 }, color: C_LINE })
  }

  @Builder
  richText(content: string, isUser: boolean) {
    Column() {
      ForEach(parseMarkdown(content), (ln: Line, li: number) => {
        if (ln.kind === 'k') {
          Column().height(5)
        } else if (ln.kind === 'h') {
          Text() {
            ForEach(ln.segs, (sg: Seg) => {
              Span(sg.text)
                .fontWeight(FontWeight.Bold)
                .fontColor(isUser ? C_TEXT_ME : C_TEXT)
            })
          }
          .fontSize(16)
          .lineHeight(24)
          .fontWeight(FontWeight.Bold)
          .wordBreak(WordBreak.BREAK_WORD)
          .margin({ top: 3, bottom: 1 })
        } else if (ln.kind === 'q') {
          Row() {
            Column()
              .width(3)
              .height('100%')
              .backgroundColor(C_ACCENT_SOFT)
              .borderRadius(2)
              .margin({ right: 8 })
            Text() {
              ForEach(ln.segs, (sg: Seg) => {
                Span(sg.text)
                  .fontColor(isUser ? C_TEXT_ME : C_TEXT_DIM)
              })
            }
            .fontSize(14.5)
            .lineHeight(22)
            .wordBreak(WordBreak.BREAK_WORD)
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else if (ln.kind === 'e') {
          Text() {
            ForEach(ln.segs, (sg: Seg) => {
              Span(sg.text)
                .fontColor(C_TEXT)
                .fontFamily('monospace')
            })
          }
          .fontSize(13.5)
          .lineHeight(21)
          .wordBreak(WordBreak.BREAK_WORD)
          .padding({ left: 9, right: 9, top: 7, bottom: 7 })
          .backgroundColor(isUser ? '#F7E8DC' : '#F7F2EB')
          .borderRadius(8)
          .margin({ top: 3, bottom: 3 })
        } else if (ln.kind === 'b' || ln.kind === 'o') {
          Row() {
            Text(ln.marker)
              .fontSize(15)
              .lineHeight(23)
              .fontColor(isUser ? C_TEXT_ME : C_TEXT_DIM)
              .width(ln.kind === 'o' ? 22 : 14)
            Text() {
              ForEach(ln.segs, (sg: Seg) => {
                Span(sg.text)
                  .fontWeight(sg.style === 'b' ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(isUser ? C_TEXT_ME : (sg.style === 'c' ? C_ACCENT : C_TEXT))
              })
            }
            .fontSize(15.5)
            .lineHeight(23)
            .wordBreak(WordBreak.BREAK_WORD)
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          Text() {
            ForEach(ln.segs, (sg: Seg) => {
              Span(sg.text)
                .fontWeight(sg.style === 'b' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(isUser ? C_TEXT_ME : (sg.style === 'c' ? C_ACCENT : C_TEXT))
            })
          }
          .fontSize(15.5)
          .lineHeight(23)
          .wordBreak(WordBreak.BREAK_WORD)
        }
      }, (ln: Line, li: number) => li.toString() + '_' + lineFingerprint(ln))
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  bubble(m: Message, i: number) {
    Column() {
      if (this.dayLabel(m.at).length > 0 && (i === 0 || this.dayLabel(this.messages[i - 1].at) !== this.dayLabel(m.at))) {
        Text(this.dayLabel(m.at))
          .fontSize(11)
          .fontColor(C_TEXT_DIM)
          .margin({ top: 14, bottom: 6 })
      }

      Row() {
        if (m.role === 'user') {
          Blank()
        }
        if (m.imagePath.length > 0) {
          Image('file://' + m.imagePath)
            .width(180)
            .height(180)
            .objectFit(ImageFit.Cover)
            .borderRadius(12)
            .onError(() => {
              this.errMsg = '图片显示不出来，可能是格式不支持，换张 jpg/png 试试';
            })
            .onClick(() => {
              this.previewImage = m.imagePath;
            })
            .gesture(
              LongPressGesture({ repeat: false })
                .onAction(() => {
                  this.copyText('[图片]');
                })
            )
        }
        if (m.sticker.length > 0) {
          Image('file://' + this.ctx().filesDir + '/stickers/' + m.sticker)
            .width(132)
            .objectFit(ImageFit.Contain)
            .borderRadius(10)
            .gesture(
              LongPressGesture({ repeat: false })
                .onAction(() => {
                  this.copyText('[表情包] ' + m.sticker);
                })
            )
        }
        if (m.sticker.length === 0 && m.imagePath.length === 0)
        Column() {
          if (this.isVoiceBubble(m)) {
            this.voiceBar(m)
          } else {
            this.richText(m.content, m.role === 'user')
          }
        }
        .padding({ left: 13, right: 13, top: 9, bottom: 9 })
        .backgroundColor(m.role === 'user' ? C_ME : C_HER)
        .borderRadius(m.role === 'user'
          ? { topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 5 }
          : { topLeft: 16, topRight: 16, bottomLeft: 5, bottomRight: 16 })
        .constraintSize({ maxWidth: '76%' })
        .alignItems(HorizontalAlign.Start)
        .gesture(
          LongPressGesture({ repeat: false })
            .onAction(() => {
              this.copyText(m.content);
            })
        )

        if (m.role !== 'user') {
          Blank()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (m.proactive) {
        Text('她主动找你的 · ' + this.clock(m.at))
          .fontSize(10)
          .fontColor(C_TEXT_DIM)
          .margin({ top: 4, left: 4 })
      }
      Row() {
        if (m.role === 'user') {
          Blank()
        }
        Text(this.clock(m.at))
          .fontSize(10)
          .fontColor('#B8AA9B')
          .margin({ top: 3 })
        if (m.role !== 'user') {
          Blank()
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(m.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  @Builder
  streamingBubble() {
    Row() {
      Column() {
        if (this.streaming.length > 0) {
          // 流式期间标记还没收完，先剥掉符号纯文本显示，收完再走富文本
          Text(stripMarkers(this.streaming))
            .fontSize(15.5)
            .lineHeight(23)
            .fontColor(C_TEXT)
            .wordBreak(WordBreak.BREAK_WORD)
        } else {
          Text('· · ·')
            .fontSize(18)
            .fontColor(C_TEXT_DIM)
        }
      }
      .padding({ left: 13, right: 13, top: 9, bottom: 9 })
      .backgroundColor(C_HER)
      .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 5, bottomRight: 16 })
      .constraintSize({ maxWidth: '76%' })
      .alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
  }

  /** 这条消息在时间线上是不是语音条形态：你的语音消息、她说的每一句 */
  private isVoiceBubble(m: Message): boolean {
    if (m.role === 'user') {
      return m.audioPath.length > 0;
    }
    return m.voice;
  }

  /** 微信式语音条：播放键 + 时长（她的合成前不知道时长，点开才知道） */
  @Builder
  voiceBar(m: Message) {
    Column() {
      Row() {
        Text(this.playingId === m.id ? '❚❚' : '▶')
          .fontSize(13)
          .fontColor(m.role === 'user' ? C_TEXT_ME : C_ACCENT)
          .width(20)
        Text(m.role === 'user' ? this.durationText(m.durationSec) : '语音')
          .fontSize(14)
          .fontColor(m.role === 'user' ? C_TEXT_ME : C_TEXT)
        Blank()
      }
      .width(116)
      .onClick(() => {
        this.toggleVoice(m);
      })

      if (m.content.length > 0) {
        Text(m.content)
          .fontSize(11)
          .lineHeight(16)
          .fontColor(m.role === 'user' ? '#FDF3E7' : C_TEXT_DIM)
          .wordBreak(WordBreak.BREAK_WORD)
          .maxLines(12)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      } else if (m.role === 'user') {
        // 语音条先上屏、转写还在路上
        Text('识别中…')
          .fontSize(11)
          .lineHeight(16)
          .fontColor('#FDF3E7')
          .opacity(0.65)
          .margin({ top: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.toggleVoice(m);
    })
  }

  private durationText(sec: number): string {
    if (sec <= 0) {
      return '0"';
    }
    return (Math.round(sec * 10) / 10).toFixed(1) + '"';
  }

  /** 点语音条：播着就停；没播就放你的录音 / 现场合她的声音 */
  private toggleVoice(m: Message): void {
    if (this.playingId === m.id) {
      this.playingId = -1;
      this.player.stop();
      return;
    }
    if (this.player.isPlaying()) {
      this.player.stop();
    }
    if (m.role === 'user') {
      this.playMine(m);
      return;
    }
    this.playHers(m);
  }

  private playMine(m: Message): void {
    if (m.audioPath.length === 0) {
      return;
    }
    this.playingId = m.id;
    this.player.playFile(m.audioPath, () => {
      this.playingId = -1;
    }).catch((e: Error) => {
      this.playingId = -1;
      this.errMsg = e.message;
    });
  }

  /**
   * 她的话：文字按句切开，逐句合成、边播边预取下一句。
   * PC 服务不在线时第一句就会失败，提示去设置里看。
   */
  private async playHers(m: Message): Promise<void> {
    // 纯表情的句子剥完就空了，跳过别让队列中断
    const sentences: string[] = VoiceService.splitSentences(m.content)
      .filter((sn: string): boolean => VoiceService.stripForTts(sn).length > 0);
    if (sentences.length === 0) {
      return;
    }
    this.playingId = m.id;
    console.info('[VOICE] playHers content=' + m.content + ' sentences=' + sentences.length);
    try {
      let pending: Promise<string> = VoiceService.synthToFile(sentences[0], this.voiceStyle);
      for (let i: number = 0; i < sentences.length; i++) {
        if (this.playingId !== m.id) {
          break; // 被手动停了
        }
        const path: string = await pending;
        if (i + 1 < sentences.length) {
          // 播这句的时候，后台先把下一句合成好
          pending = VoiceService.synthToFile(sentences[i + 1], this.voiceStyle);
        }
        const last: boolean = i === sentences.length - 1;
        await this.player.playFile(path, last ? () => {
          this.playingId = -1;
        } : () => {
        });
      }
    } catch (e) {
      const err: Error = e as Error;
      if (this.playingId === m.id) {
        this.errMsg = err.message;
      }
    } finally {
      if (this.playingId === m.id) {
        this.playingId = -1;
      }
    }
  }

  // ==================== 表情包 ====================

  private loadStickers(): void {
    // 表情包打进 HAP 的 rawfile 里，首次启动拷到沙箱（Image 从文件路径加载 GIF）
    this.stickerFiles = [];
    try {
      const dir: string = this.ctx().filesDir + '/stickers';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const marker: string = dir + '/' + STICKERS[0].file;
      if (!fileIo.accessSync(marker)) {
        for (let i: number = 0; i < STICKERS.length; i++) {
          const def: StickerDef = STICKERS[i];
          const raw: Uint8Array = this.ctx().resourceManager.getRawFileContentSync('stickers/' + def.file);
          const dst: string = dir + '/' + def.file;
          const file = fileIo.openSync(dst,
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            fileIo.writeSync(file.fd, raw.buffer);
          } finally {
            fileIo.closeSync(file);
          }
        }
      }
      for (let i: number = 0; i < STICKERS.length; i++) {
        this.stickerFiles.push(STICKERS[i].file);
      }
    } catch (e) {
      this.stickerFiles = [];
    }
  }

  /**
   * 她这条是语音：后台按句预热，点开时直接读缓存播，不用等。
   * 失败就静默——真点的时候会再试一次并给提示。
   */
  private async prewarmVoice(text: string): Promise<void> {
    try {
      if (!(await this.voiceServiceUp())) {
        return;
      }
      const sentences: string[] = VoiceService.splitSentences(text)
        .filter((sn: string): boolean => VoiceService.stripForTts(sn).length > 0);
      // 长回复先热前 8 句，剩下的点开再合成
      const limit: number = sentences.length > 8 ? 8 : sentences.length;
      for (let i: number = 0; i < limit; i++) {
        try {
          await VoiceService.synthToFile(sentences[i], this.voiceStyle);
        } catch (e) {
          return; // 一句失败就收手，免得刷一屏错误
        }
      }
    } catch (e) {
    }
  }

  private voiceUpCache: boolean = false;

  /** 上次清语音文件的时间，防止每说一句话就扫一遍目录 */
  private lastVoiceSweep: number = 0;

  /**
   * 清语音文件。录音只留消息还引用着的，合成缓存压到 30 MB 以内。
   * force=false 时限流，10 分钟最多扫一次。
   */
  private sweepVoice(force: boolean): void {
    const now: number = Date.now();
    if (!force && now - this.lastVoiceSweep < 10 * 60 * 1000) {
      return;
    }
    this.lastVoiceSweep = now;
    const keep: string[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      const p: string = this.messages[i].audioPath;
      if (p.length > 0) {
        keep.push(p);
      }
    }
    try {
      const dir: string = this.ctx().filesDir + '/voice';
      const freed: number = VoiceStorage.sweep(dir, keep);
      if (freed > 0) {
        console.info('[VOICE] 清理释放 ' + Math.round(freed / 1024) + ' KB');
      }
    } catch (e) {
    }
  }

  /**
   * 她的声音服务此刻在不在，顺便选好该走哪条路。
   * 选路结果在 VoiceService 里缓存 60 秒；请求失败会立刻重选并换路重试，
   * 所以出门/回家用户不会感觉到这 60 秒。
   * 不在线时回复一律落成文字气泡，免得给一个点开没声的语音气泡。
   */
  private async voiceServiceUp(): Promise<boolean> {
    const host: string = await VoiceService.activeHost();
    this.voiceUpCache = host.length > 0;
    this.voiceRouteText = VoiceService.routeLabel();
    this.absorbWanUrl();
    return this.voiceUpCache;
  }

  /**
   * 电脑在 /ping 里带回来的隧道地址，趁在家连着局域网时记到手机里。
   * quick tunnel 每次重启都换域名，这样就不用每次手动填、也不用重新打包 App。
   */
  private absorbWanUrl(): void {
    if (!this.voiceWanAuto) {
      return;
    }
    const url: string = VoiceService.syncedWanUrl;
    if (url.length === 0 || url === this.voiceWanHost) {
      return;
    }
    this.voiceWanHost = url;
    VoiceService.setWanHost(url);
    this.persistVoiceWan(url);
  }

  /** 只存这一个字段，别为了同步地址把「主动找你」的排期也重置一遍 */
  private async persistVoiceWan(url: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.ctx(), PREF_NAME);
      await store.put('voiceWanHost', url);
      await store.flush();
    } catch (e) {
    }
  }

  /** 页面每 30 秒 tick 一次：顺手刷新链路与隧道地址（内部有 60 秒缓存，很轻） */
  private async refreshVoiceRoute(): Promise<void> {
    const host: string = await VoiceService.activeHost();
    this.voiceUpCache = host.length > 0;
    this.voiceRouteText = VoiceService.routeLabel();
    this.absorbWanUrl();
  }

  /**
   * 自动配表情：回复文本里命中了哪个表情标签（提到「晚安」「哈哈哈」「饿了」…），
   * 就以 STICKER_RATE 概率从命中的里面随机挑一张；完全没沾边就不发。
   */
  private autoSticker(text: string, userText: string): string {
    // 她的回复里常常没有情绪词（“那别做饭了，早点歇”），
    // 但他那句里一定有（“累死了”），两边一起扫命中率高得多。
    const hay: string = text + ' ' + userText;
    const tags: string[] = [];
    for (let i: number = 0; i < STICKERS.length; i++) {
      if (hay.includes(STICKERS[i].tag)) {
        tags.push(STICKERS[i].tag);
      }
    }
    for (let i: number = 0; i < STICKER_CUES.length; i++) {
      if (hay.includes(STICKER_CUES[i][0])) {
        tags.push(STICKER_CUES[i][1]);
      }
    }
    if (tags.length === 0 || Math.random() >= STICKER_RATE) {
      return '';
    }
    const tag: string = tags[Math.floor(Math.random() * tags.length)];
    return this.pickSticker(tag);
  }

  /**
   * 按标签挑表情：文件名就是表情的名字，所以直接按名字筛，
   * 一个标签有多张（开心.gif、开心2.gif）就在里面随机一张。
   */
  private pickSticker(tag: string): string {
    if (this.stickerFiles.length === 0) {
      return '';
    }
    const want: string = tag.replace(/[!！。，,\s]/g, '');
    const cands: string[] = [];
    for (let i: number = 0; i < this.stickerFiles.length; i++) {
      const f: string = this.stickerFiles[i];
      const name: string = f.substring(0, f.lastIndexOf('.'));
      const n: string = name.replace(/[!！。，,\s]/g, '');
      if (n === want) {
        cands.push(f);
      }
    }
    if (cands.length === 0) {
      // 精确名没有就退一步：名字里含这个标签也算
      for (let i: number = 0; i < this.stickerFiles.length; i++) {
        const f: string = this.stickerFiles[i];
        if (want.length > 0 && f.includes(want)) {
          cands.push(f);
        }
      }
    }
    const pool: string[] = cands.length > 0 ? cands : this.stickerFiles;
    return pool[Math.floor(Math.random() * pool.length)];
  }

  /** 从她的回复里取出 [表情:标签]，返回（去掉标记的正文，表情文件名） */
  private extractSticker(reply: string): [string, string] {
    const re: RegExp = /\[表情[:：][^\]]{1,12}\]/g;
    const found = reply.match(re);
    let file: string = '';
    if (found !== null && found.length > 0) {
      const tag: string = found[0].replace(/\[表情[:：]/, '').replace(/\]/, '').trim();
      file = this.pickSticker(tag);
    }
    const text: string = reply.replace(re, '').replace(/\s{2,}/g, ' ').trim();
    return [text, file];
  }

  /** 设置页：家里 / 隧道各测一遍，直接采用这次的结果 */
  private async testVoiceHost(): Promise<void> {
    this.voiceCheckMsg = '正在检测…';
    VoiceService.configure(this.voiceHost, this.voiceWanHost, this.voiceWanAuto);
    const lan: string = VoiceService.normalizeHost(this.voiceHost);
    const wan: string = VoiceService.normalizeHost(this.voiceWanHost);
    if (lan.length === 0 && wan.length === 0) {
      this.voiceCheckMsg = '先填家里地址或隧道地址';
      this.voiceRouteText = '语音服务没连上';
      return;
    }
    let msg: string = '';
    let lanOk: boolean = false;
    let wanOk: boolean = false;
    if (lan.length > 0) {
      lanOk = (await VoiceService.checkHealth(lan)) === '';
      msg += '家里 ' + (lanOk ? '通' : '不通');
    }
    if (wan.length > 0) {
      wanOk = (await VoiceService.checkHealth(wan)) === '';
      if (msg.length > 0) {
        msg += '，';
      }
      msg += '隧道 ' + (wanOk ? '通' : '不通');
    }
    VoiceService.applyProbeResult(lanOk, wanOk);
    this.voiceRouteText = VoiceService.routeLabel();
    this.absorbWanUrl();
    this.voiceCheckMsg = msg + '｜现在走 ' + VoiceService.routeShort();
  }

  // ==================== 加号：发图片 ====================

  /** 系统相册选一张，存进 filesDir/images/，再当一条消息发出去 */
  private async pickImage(): Promise<void> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      const uri: string = result.photoUris[0];
      const dir: string = this.ctx().filesDir + '/images';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      let ext: string = '.jpg';
      const lower: string = uri.toLowerCase();
      if (lower.indexOf('.png') >= 0) {
        ext = '.png';
      } else if (lower.indexOf('.webp') >= 0) {
        ext = '.webp';
      }
      const path: string = dir + '/i_' + Date.now().toString(36) + ext;
      const src: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const dst: fileIo.File = fileIo.openSync(path,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          const size: number = fileIo.statSync(src.fd).size;
          const buf: ArrayBuffer = new ArrayBuffer(size);
          fileIo.readSync(src.fd, buf);
          fileIo.writeSync(dst.fd, buf);
        } finally {
          fileIo.closeSync(dst.fd);
        }
      } finally {
        fileIo.closeSync(src.fd);
      }
      // 有些相册 URI 用 stat 拿不到大小，会写出 0 字节文件 —— 那样气泡会是空白，不如直接报错
      if (!fileIo.accessSync(path) || fileIo.statSync(path).size <= 0) {
        throw new Error('图片没写进沙箱，换张 jpg/png 试试');
      }
      // 先让智谱「看」一眼，识别失败也不能挡住发图 —— 退化成「没看清」的回复，
      // 她会自然问一句拍的什么，而不是卡住或装作看见了。
      let desc: string = '';
      try {
        desc = await VisionService.describe(path, this.visionKey);
      } catch (e) {
        this.errMsg = '这张图没看清：' + (e as Error).message;
      }
      const msg: Message = new Message('user', '[图片]', '', Date.now(), false,
        '', 0, false, '', path, desc);
      this.pushMessage(msg);
      this.persistNow();
      if (this.apiKey.trim().length > 0) {
        await this.runModelTurn('[图片]', msg);
      }
    } catch (e) {
      this.errMsg = '选图片没成功：' + (e as Error).message;
    }
  }

  // ==================== 加号：语音通话 ====================

  /** 把 VAD 顺手算出的 RMS 接到通话页动效上（切后台回来也要重接） */
  private attachCallLevel(): void {
    this.voice.onLevel = (rms: number): void => {
      if (rms > this.micPeak) {
        this.micPeak = rms;
      }
    };
  }

  /**
   * 息屏保活：一次申请「录音 + 播放」两个长时任务类型。
   * 通话是「听的时候录、说的时候放」交替，两个都声明才不会被判业务不符。
   * 系统会在通知栏显示常驻提示（合规要求，去不掉），点通知回到 App。
   */
  private async startCallKeepAlive(): Promise<void> {
    if (this.keepAliveOn) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'com.example.deepseekharmony', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.ctx(),
        ['audioRecording', 'audioPlayback'], agent);
      this.keepAliveOn = true;
      console.info('[CALL] 长时任务已申请：录音+播放，息屏可继续通话');
    } catch (e) {
      // 没申请下来照样能打电话，只是息屏后可能被系统挂起
      console.warn('[CALL] 长时任务没申请下来：' + (e as Error).message);
    }
  }

  private async stopCallKeepAlive(): Promise<void> {
    if (!this.keepAliveOn) {
      return;
    }
    this.keepAliveOn = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx());
    } catch (e) {
    }
  }

  private async startCall(): Promise<void> {
    if (this.inCall) {
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.errMsg = '还没填 API Key，先点右上角设置一下吧。';
      this.showSettings = true;
      return;
    }
    if (!(await this.voiceServiceUp())) {
      this.errMsg = '语音服务没连上（电脑没开，或家里/隧道两条路都不通），先去设置里看看。';
      this.showSettings = true;
      return;
    }
    const granted: boolean = await VoiceInputService.ensureMicPermission(this.ctx());
    if (!granted) {
      this.errMsg = '要开麦克风权限才能语音通话。';
      return;
    }
    this.player.stop(); // 别和正在播的语音条抢播放器
    this.errMsg = '';
    this.inCall = true;
    this.callStartedAt = Date.now();
    this.callState = 'listening';
    this.callLine = '';
    this.callSeconds = 0;
    this.callAvatarFailed = false;
    // 每通电话开一次随机，整通保持不变，别说到一半突然变脸
    this.callAvatarUseAlt = Math.random() < 0.5;
    console.info('[CALL] 本通头像：' + (this.callAvatarUseAlt ? '光影圆底版' : '平涂扩图版'));
    this.callAutoBarge = VoiceInputService.aecSupported();
    console.info('[CALL] 系统回声消除 ' + (this.callAutoBarge ? '可用，播放期间自动插话已开启' : '不可用，降级为按钮插话'));
    this.attachCallLevel();
    this.startCallAnim();
    // 息屏保活：申请「录音 + 播放」两个长时任务；失败也不阻断通话
    await this.startCallKeepAlive();
    if (this.callSession === null) {
      this.callSession = new CallSession(this.voice, this.player, this.service);
    }
    const cfg: CallConfig = {
      apiKey: this.apiKey,
      model: this.activeModel(),
      voiceStyle: this.voiceStyle,
      // 通话里这一句还没进时间线（要等她回完才一起落），所以手动补在请求末尾
      makeRequest: (t: string): ChatMessage[] => {
        const req: ChatMessage[] = this.buildRequest(t, true);
        req.push({ role: 'user', content: t });
        return req;
      }
    };
    const cb: CallCallbacks = {
      onState: (s: string): void => {
        this.callState = s;
      },
      onLine: (t: string): void => {
        this.callLine = t;
      },
      onTurn: (u: string, r: string): void => {
        this.pushMessage(new Message('user', u));
        this.pushMessage(new Message('assistant', VoiceService.stripEmoji(r)));
        this.persistNow();
      },
      onError: (m: string): void => {
        this.callLine = m;
      },
      onTick: (s: number): void => {
        this.callSeconds = s;
      }
    };
    await this.callSession.start(cfg, cb);
  }

  private async endCall(): Promise<void> {
    // 先停动效，别等 stop() 的异步链条，挂断瞬间就该安静下来
    this.stopCallAnim();
    this.voice.onLevel = null;
    await this.stopCallKeepAlive();
    const s: CallSession | null = this.callSession;
    if (s !== null) {
      await s.stop();
    }
    if (!this.inCall) {
      return;
    }
    this.inCall = false;
    this.showPlus = false;
    const sec: number = Math.max(0, Math.floor((Date.now() - this.callStartedAt) / 1000));
    const mm: number = Math.floor(sec / 60);
    const ss: number = sec % 60;
    const label: string = '📞 通话 ' + (mm > 0 ? mm + ' 分 ' : '') + ss + ' 秒';
    this.pushMessage(new Message('call', label));
    this.persistNow();
    this.sweepVoice(true); // 通话录音没被任何消息引用，顺手清掉
    this.reschedule();
  }

  private interruptCall(): void {
    // 已经在听了就别打断，不然会把下一句回复吞掉
    if (this.callState === 'listening') {
      return;
    }
    const s: CallSession | null = this.callSession;
    if (s !== null) {
      s.interrupt();
    }
  }

  private callStateText(): string {
    if (this.callState === 'listening') {
      return '她在听你说…';
    }
    if (this.callState === 'thinking') {
      return '她在想…';
    }
    if (this.callState === 'speaking') {
      return '她在说…';
    }
    return '通话结束';
  }

  private callTimerText(): string {
    const m: string = Math.floor(this.callSeconds / 60).toString().padStart(2, '0');
    const s: string = (this.callSeconds % 60).toString().padStart(2, '0');
    return m + ':' + s;
  }

  // ==================== 通话页动效 ====================
  // 参考豆包通话页：头像周围一圈会随声音起伏的发光涟漪 + 中央声波条。
  // 音量不是假的：VoiceInputService 的 VAD 本来就算 RMS，通过 onLevel 递出来。

  /** 30fps 推一帧：涟漪相位 + 把麦克风峰值平滑成 0~1 的音量 */
  private startCallAnim(): void {
    this.stopCallAnim();
    this.callPulse = 0;
    this.callLevel = 0;
    this.micPeak = 0;
    this.callAnimLastAt = Date.now();
    this.callAnimTimer = setInterval(() => {
      const now: number = Date.now();
      // 掉帧/后台恢复时别让动画一下跳一大截
      const dt: number = Math.min(200, Math.max(1, now - this.callAnimLastAt));
      this.callAnimLastAt = now;
      // 按毫秒推进（等价于原来 70ms 走 0.045 / 0.022 / 0.062），帧率随便改速度不变
      const perMs: number = this.callState === 'speaking' ? 0.000886
        : (this.callState === 'thinking' ? 0.000314 : 0.000643);
      this.callPulse = (this.callPulse + perMs * dt) % 1;
      const target: number = Math.min(1, this.micPeak / 2600);
      // 起来快、落下慢；平滑系数按 70ms 基准归一化，改帧率不影响手感
      const base: number = target > this.callLevel ? 0.55 : 0.18;
      const k: number = 1 - Math.pow(1 - base, dt / 70);
      this.callLevel = this.callLevel + (target - this.callLevel) * k;
      this.micPeak = 0;
    }, 33);
  }

  private stopCallAnim(): void {
    if (this.callAnimTimer !== -1) {
      clearInterval(this.callAnimTimer);
      this.callAnimTimer = -1;
    }
    this.callAnimLastAt = 0;
    this.callLevel = 0;
    this.micPeak = 0;
  }

  /** 三层涟漪错开 1/3 相位，形成一圈圈向外扩散 */
  private ringPhase(i: number): number {
    return (this.callPulse + i / 3) % 1;
  }

  private ringScale(i: number): number {
    return 1 + this.ringPhase(i) * 0.42 + this.callLevel * 0.18;
  }

  private ringOpacity(i: number): number {
    const base: number = this.callState === 'thinking' ? 0.20 : 0.34;
    return (1 - this.ringPhase(i)) * base + this.callLevel * 0.12;
  }

  /** 听的时候跟着音量跳；想的时候轻起伏；说的时候均匀摆动 */
  private waveHeight(i: number): number {
    const w: number = (Math.sin(this.callPulse * Math.PI * 2 + i * 0.8) + 1) / 2;
    const amp: number = this.callState === 'thinking' ? 0.28
      : (this.callState === 'speaking' ? 0.8 : 0.4 + this.callLevel * 0.9);
    return 5 + w * 22 * amp;
  }

  private callGlowColor(): string {
    if (this.callState === 'thinking') {
      return '#B9AFA4';
    }
    if (this.callState === 'speaking') {
      return '#F0B27A';
    }
    return '#E8A87C';
  }

  @Builder
  callRipple(i: number) {
    Column()
      .width(168)
      .height(168)
      .borderRadius(84)
      .border({ width: 2, color: this.callGlowColor() })
      .opacity(this.ringOpacity(i))
      .scale({ x: this.ringScale(i), y: this.ringScale(i) })
  }

  @Builder
  callWaveform() {
    Row() {
      ForEach([0, 1, 2, 3, 4, 5, 6], (i: number) => {
        Column()
          .width(4)
          .height(this.waveHeight(i))
          .borderRadius(2)
          .backgroundColor(this.callGlowColor())
          .opacity(0.5 + this.callLevel * 0.5)
          .margin({ left: 3, right: 3 })
      }, (i: number) => i.toString())
    }
    .height(36)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  /** 时间线里的一条通话记录（居中灰字，不进模型上下文） */
  @Builder
  callNote(m: Message) {
    Row() {
      Text(m.content)
        .fontSize(11)
        .fontColor(C_TEXT_DIM)
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .backgroundColor('#EFE7DC')
        .borderRadius(12)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 8, bottom: 8 })
  }

  /** 点开图片后的全屏预览，点任意处关闭 */
  @Builder
  imagePreview() {
    Stack() {
      Image('file://' + this.previewImage)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .onError(() => {
          this.errMsg = '大图加载失败';
        })
      Text('点击关闭')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#80000000')
        .borderRadius(18)
        .margin({ top: 44 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0000000')
    .alignContent(Alignment.Top)
    .onClick(() => {
      this.previewImage = '';
    })
  }

  /** 全屏通话页：不用按住，说完自动收尾，她念完自动接着听 */
  @Builder
  callPage() {
    Column() {
      Text(this.profile.herName)
        .fontSize(22)
        .fontColor('#F6F0E8')
        .margin({ top: 70 })
      Text(this.callTimerText())
        .fontSize(13)
        .fontColor('#B9AFA4')
        .margin({ top: 6 })

      Blank()

      Stack() {
        // 三层向外扩散的涟漪，说话声音越大扩散得越开
        ForEach([0, 1, 2], (i: number) => {
          this.callRipple(i)
        }, (i: number) => i.toString())

        // 贴着头像的一层柔光，跟着音量呼吸
        Column()
          .width(190)
          .height(190)
          .borderRadius(95)
          .backgroundColor(this.callGlowColor())
          .opacity(0.08 + this.callLevel * 0.20)
          .scale({ x: 1 + this.callLevel * 0.16, y: 1 + this.callLevel * 0.16 })

        Column()
          .width(158)
          .height(158)
          .borderRadius(79)
          .backgroundColor('#4A3E36')

        // 通话头像每通随机一张：平涂扩图版 / 光影圆底版（startCall 里抽签，整通不变）
        if (this.callAvatarFailed) {
          Text('☺')
            .fontSize(54)
            .fontColor('#E8A87C')
        } else if (this.callAvatarUseAlt) {
          Image($r('app.media.call_avatar_alt'))
            .width(150)
            .height(150)
            .borderRadius(75)
            .objectFit(ImageFit.Cover)
            .scale({ x: 1 + this.callLevel * 0.06, y: 1 + this.callLevel * 0.06 })
            .onError(() => {
              this.callAvatarFailed = true;
            })
        } else {
          Image($r('app.media.call_avatar'))
            .width(150)
            .height(150)
            .borderRadius(75)
            .objectFit(ImageFit.Cover)
            .scale({ x: 1 + this.callLevel * 0.06, y: 1 + this.callLevel * 0.06 })
            .onError(() => {
              this.callAvatarFailed = true;
            })
        }
      }
      .width(280)
      .height(280)

      this.callWaveform()

      Text(this.callStateText())
        .fontSize(16)
        .fontColor('#E8D9C8')
        .margin({ top: 26 })
      Text(this.callAutoBarge ? '随时开口就能插话' : '这台设备没开回声消除，插话请点按钮')
        .fontSize(10)
        .fontColor('#8C7F70')
        .margin({ top: 5 })
      Text(this.callLine)
        .fontSize(13)
        .fontColor('#AFA295')
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 30, right: 30 })
        .margin({ top: 12 })

      Blank()

      Row() {
        Column() {
          Text('🎙')
            .fontSize(24)
            .fontColor('#FFFFFF')
          Text('插话')
            .fontSize(12)
            .fontColor('#D9CFC3')
            .margin({ top: 4 })
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor('#4A3E36')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.interruptCall();
        })

        Column() {
          Text('✕')
            .fontSize(26)
            .fontColor('#FFFFFF')
          Text('挂断')
            .fontSize(12)
            .fontColor('#E8D9C8')
            .margin({ top: 4 })
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor('#C9614A')
        .justifyContent(FlexAlign.Center)
        .margin({ left: 60 })
        .onClick(() => {
          this.endCall();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 70 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#2B2622')
  }

  @Builder
  inputBar() {
    Column() {
      if (this.errMsg.length > 0) {
        Text(this.errMsg)
          .fontSize(12)
          .fontColor('#C9614A')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
      }
      if (this.recording) {
        this.recordOverlay()
      }
      Row() {
        Text(this.showPlus ? '×' : '＋')
          .fontSize(22)
          .fontColor(this.showPlus ? C_ACCENT : C_TEXT_DIM)
          .width(32)
          .height(40)
          .textAlign(TextAlign.Center)
          .margin({ right: 2 })
          .onClick(() => {
            this.showPlus = !this.showPlus;
          })

        if (this.voiceMode) {
          Text('⌨')
            .fontSize(17)
            .fontColor(C_TEXT_DIM)
            .width(36)
            .height(40)
            .textAlign(TextAlign.Center)
            .margin({ right: 4 })
            .onClick(() => {
              this.voiceMode = false;
            })

          Text(this.recording ? (this.cancelArmed ? '松开 取消' : '松开 转文字') : '按住 说话')
            .fontSize(15)
            .fontColor(this.recording && this.cancelArmed ? '#FFFFFF' : C_TEXT)
            .width(44)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.recording ? (this.cancelArmed ? '#C9614A' : C_ME) : C_INPUT_BG)
            .borderRadius(18)
            .border({ width: 1, color: this.recording ? Color.Transparent : C_LINE })
            .layoutWeight(1)
            .onTouch((e: TouchEvent) => {
              this.voiceTouch(e);
            })
        } else {
          Text('🎤')
            .fontSize(17)
            .fontColor(C_TEXT_DIM)
            .width(36)
            .height(40)
            .textAlign(TextAlign.Center)
            .margin({ right: 4 })
            .onClick(() => {
              this.voiceMode = true;
            })

          TextArea({ text: this.input, placeholder: '想我了吗❤' })
            .placeholderColor('#B8AA9B')
            .fontColor(C_TEXT)
            .fontSize(15)
            .backgroundColor(C_INPUT_BG)
            .borderRadius(18)
            .border({ width: 1, color: C_LINE })
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .constraintSize({ minHeight: 40, maxHeight: 120 })
            .layoutWeight(1)
            .onChange((v: string) => {
              this.input = v;
            })
        }

        if (this.sending) {
          Text('停')
            .fontSize(14)
            .fontColor(C_ACCENT)
            .width(44)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(C_ACCENT_SOFT)
            .borderRadius(18)
            .margin({ left: 8 })
            .onClick(() => {
              this.stop();
            })
        } else if (!this.voiceMode) {
          Text('发')
            .fontSize(14)
            .fontColor(this.input.trim().length > 0 ? '#FFFFFF' : '#C4B6A6')
            .width(44)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.input.trim().length > 0 ? C_ACCENT : C_ACCENT_SOFT)
            .borderRadius(18)
            .margin({ left: 8 })
            .onClick(() => {
              this.send();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Bottom)

      if (this.showPlus) {
        Row() {
          this.plusItem('📞', '语音通话', () => {
            this.showPlus = false;
            this.startCall();
          })
          this.plusItem('🖼', '发图片', () => {
            this.showPlus = false;
            this.pickImage();
          })
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 18 })
        .alignItems(VerticalAlign.Top)
      }
    }
    .backgroundColor(C_BG_TOP)
  }

  /** 加号面板里的一个入口 */
  @Builder
  plusItem(icon: string, label: string, act: () => void) {
    Column() {
      Text(icon)
        .fontSize(26)
        .width(56)
        .height(56)
        .textAlign(TextAlign.Center)
        .padding({ top: 11 })
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
      Text(label)
        .fontSize(11)
        .fontColor(C_TEXT_DIM)
        .margin({ top: 6 })
    }
    .margin({ right: 24 })
    .onClick(act)
  }

  /** 录音时悬在输入栏上方的反馈面板 */
  @Builder
  recordOverlay() {
    Row() {
      Blank()
      Column() {
        if (this.cancelArmed) {
          Text('松开取消')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#C9614A')
        } else {
          Text('我在听，你说…')
            .fontSize(14)
            .fontColor(C_TEXT_DIM)
        }
        Text(this.cancelArmed ? '滑回去就继续说' : '上滑取消 · 松开发送')
          .fontSize(11)
          .fontColor(C_TEXT_DIM)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .backgroundColor(C_CARD)
      .borderRadius(14)
      .border({ width: 1, color: this.cancelArmed ? '#C9614A' : C_LINE })
      .constraintSize({ maxWidth: '80%' })
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 2 })
  }

  /**
   * 某个选项组当前选中哪个值。
   * 关键：chip 的选中态必须在 @Builder 内部用 this 读，
   * 不能当参数传进去 —— @Builder 的值参数不会随状态刷新。
   * 之前「80% 不变」「选项不高亮」都是这个原因。
   */
  private selectedOf(group: string): string {
    if (group === 'source') {
      return this.apiSource;
    }
    if (group === 'model') {
      return this.model;
    }
    if (group === 'effort') {
      return this.effort;
    }
    if (group === 'context') {
      return this.contextLimit.toString();
    }
    if (group === 'stick') {
      return this.stickiness;
    }
    if (group === 'notify') {
      return this.notifyMode;
    }
    if (group === 'voice') {
      return this.voiceStyle;
    }
    if (group === 'wanAuto') {
      return this.voiceWanAuto ? 'on' : 'off';
    }
    return '';
  }

  @Builder
  chip(label: string, group: string, value: string, act: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.selectedOf(group) === value ? '#FFFFFF' : C_TEXT)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.selectedOf(group) === value ? C_ACCENT : '#FFFFFF')
      .border({
        width: 1,
        color: this.selectedOf(group) === value ? C_ACCENT : C_LINE
      })
      .borderRadius(15)
      .margin({ right: 8, bottom: 8 })
      .onClick(act)
  }

  @Builder
  sectionTitle(t: string) {
    Text(t)
      .fontSize(12)
      .fontColor(C_TEXT_DIM)
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  @Builder
  settingsPanel() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
        Text('完成')
          .fontSize(14)
          .fontColor(C_ACCENT)
          .fontWeight(FontWeight.Medium)
          .onClick(() => {
            this.showSettings = false;
            this.saveSettings();
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      Scroll() {
        Column() {
          this.sectionTitle('接口来源')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('DeepSeek 官方', 'source', SRC_OFFICIAL, () => {
              this.apiSource = SRC_OFFICIAL;
              this.applyHost();
              this.hostCheckMsg = '';
            })
            this.chip('三方兼容接口', 'source', SRC_THIRD, () => {
              this.apiSource = SRC_THIRD;
              this.applyHost();
              this.hostCheckMsg = '';
            })
          }
          Text(this.apiSource === SRC_OFFICIAL
            ? 'api.deepseek.com，官方价目，闲时 / 高峰都按官方算。'
            : '任何 OpenAI 格式的中转或自建服务。填到 /v1 就行，后面的路径会自动补。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 8 })

          if (this.apiSource === SRC_THIRD) {
            this.sectionTitle('接口地址')
            TextInput({ text: this.apiHost, placeholder: 'https://api.example.com/v1' })
              .fontColor(C_TEXT)
              .placeholderColor('#B8AA9B')
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: C_LINE })
              .fontSize(13)
              .borderRadius(12)
              .onChange((v: string) => {
                this.apiHost = v;
                this.hostCheckMsg = '';
              })
            this.sectionTitle('模型名（留空则用下面的）')
            TextInput({ text: this.thirdModel, placeholder: 'gpt-4o / deepseek-chat / …' })
              .fontColor(C_TEXT)
              .placeholderColor('#B8AA9B')
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: C_LINE })
              .fontSize(13)
              .borderRadius(12)
              .onChange((v: string) => {
                this.thirdModel = v;
              })
            Row() {
              Text('测试连接')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .backgroundColor(C_ACCENT)
                .borderRadius(14)
                .onClick(() => {
                  this.testHost();
                })
              Text(this.hostCheckMsg)
                .fontSize(11)
                .fontColor(C_TEXT_DIM)
                .layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%')
            .margin({ top: 10, bottom: 4 })
            .alignItems(VerticalAlign.Center)
          }

          this.sectionTitle('API Key')
          TextInput({ text: this.apiKey, placeholder: 'sk-...' })
            .type(InputType.Password)
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: C_LINE })
            .fontSize(13)
            .borderRadius(12)
            .onChange((v: string) => {
              this.apiKey = v;
            })

          this.sectionTitle('图片识别 Key（发图时先看懂画面，智谱免费额度即可）')
          TextInput({ text: this.visionKey, placeholder: '智谱 open.bigmodel.cn 的 Key' })
            .type(InputType.Password)
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: C_LINE })
            .fontSize(13)
            .borderRadius(12)
            .onChange((v: string) => {
              this.visionKey = v;
            })
          Text('留空则每次发图都识别不了，她会问你拍的什么；已预填一个可用的免费 Key。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 6 })

          this.sectionTitle('模型')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('deepseek-flash', 'model', 'deepseek-flash', () => {
              this.model = 'deepseek-flash';
            })
            this.chip('deepseek-v4-pro', 'model', 'deepseek-v4-pro', () => {
              this.model = 'deepseek-v4-pro';
            })
          }

          this.sectionTitle('思考强度（日常聊天建议关闭）')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('关', 'effort', 'off', () => {
              this.effort = 'off';
            })
            this.chip('低', 'effort', 'low', () => {
              this.effort = 'low';
            })
            this.chip('高', 'effort', 'high', () => {
              this.effort = 'high';
            })
          }

          // 计价状态
          Row() {
            Text(this.peak ? '高峰' : '闲时')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .backgroundColor(this.peak ? '#C9614A' : '#7A9E6F')
              .borderRadius(7)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            Text(this.peak ? '现在价格 ×2' : '现在价格 ×1')
              .fontSize(12)
              .fontColor(C_TEXT)
              .margin({ left: 8 })
            Blank()
            Text('本次 ' + this.costYuan.toFixed(4) + ' 元')
              .fontSize(12)
              .fontColor(C_TEXT_DIM)
          }
          .width('100%')
          .padding({ top: 10, bottom: 4 })
          .alignItems(VerticalAlign.Center)
          Text('累计：输入 ' + this.tokensIn + ' / 输出 ' + this.tokensOut
            + '，缓存命中 ' + this.tokensHit)
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 4 })

          this.sectionTitle('上下文上限')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('32K', 'context', '32000', () => {
              this.contextLimit = LIMIT_32K;
            })
            this.chip('64K', 'context', '64000', () => {
              this.contextLimit = LIMIT_64K;
            })
            this.chip('128K', 'context', '128000', () => {
              this.contextLimit = LIMIT_128K;
            })
          }

          // 标题里的百分比不能拼成参数传进去 —— @Builder 的值参数不会刷新
          Row() {
            Text('用掉多少就开始写记忆（')
              .fontSize(12)
              .fontColor(C_TEXT_DIM)
            Text(this.triggerPercent.toString() + '%')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_ACCENT)
            Text('）')
              .fontSize(12)
              .fontColor(C_TEXT_DIM)
          }
          .width('100%')
          .margin({ top: 18, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          Slider({
            value: this.triggerPercent,
            min: 60,
            max: 95,
            step: 5,
            style: SliderStyle.OutSet
          })
            .selectedColor(C_ACCENT)
            .trackColor(C_ACCENT_SOFT)
            .blockColor('#FFFFFF')
            .width('100%')
            .onChange((v: number) => {
              this.triggerPercent = Math.round(v);
            })
          Text('现在：上下文用到 ' + this.triggerPercent + '% 就开始整理记忆，'
            + '超过这条线老对话会被压成记忆卡。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 2 })

          this.sectionTitle('她多久主动找你一次')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('黏人（2 小时）', 'stick', STICK_CLUNGY, () => {
              this.stickiness = STICK_CLUNGY;
              this.reschedule();
            })
            this.chip('自然（4 小时）', 'stick', STICK_NATURAL, () => {
              this.stickiness = STICK_NATURAL;
              this.reschedule();
            })
            this.chip('克制（不联系）', 'stick', STICK_QUIET, () => {
              this.stickiness = STICK_QUIET;
              this.reschedule();
            })
          }
          Text(this.stickDetail())
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 2 })

          this.sectionTitle('安静时段')
          Text('这段时间她绝不主动找你，消息会等到结束之后。默认 00:30 — 08:00。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 6 })
          Row() {
            Text('从 ' + this.minuteText(this.quietStart))
              .fontSize(13)
              .fontColor(C_TEXT)
              .width(86)
            Slider({
              value: this.quietStart,
              min: 0,
              max: 1435,
              step: 30,
              style: SliderStyle.OutSet
            })
              .selectedColor(C_ACCENT)
              .trackColor(C_ACCENT_SOFT)
              .blockColor('#FFFFFF')
              .layoutWeight(1)
              .onChange((v: number) => {
                this.quietStart = Math.round(v / 30) * 30 % 1440;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('到 ' + this.minuteText(this.quietEnd))
              .fontSize(13)
              .fontColor(C_TEXT)
              .width(86)
            Slider({
              value: this.quietEnd,
              min: 0,
              max: 1435,
              step: 30,
              style: SliderStyle.OutSet
            })
              .selectedColor(C_ACCENT)
              .trackColor(C_ACCENT_SOFT)
              .blockColor('#FFFFFF')
              .layoutWeight(1)
              .onChange((v: number) => {
                this.quietEnd = Math.round(v / 30) * 30 % 1440;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.quietHint())
            .fontSize(11)
            .fontColor(this.quietStart === this.quietEnd ? '#C9614A' : C_TEXT_DIM)
            .width('100%')
            .margin({ top: 2 })

          this.sectionTitle('通知里显示什么')
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('TA 想你了', 'notify', NOTIFY_HINT, () => {
              this.notifyMode = NOTIFY_HINT;
            })
            this.chip('显示原话', 'notify', NOTIFY_TEXT, () => {
              this.notifyMode = NOTIFY_TEXT;
            })
            this.chip('只显示名字', 'notify', NOTIFY_HIDDEN, () => {
              this.notifyMode = NOTIFY_HIDDEN;
            })
          }
          Text(this.notifyEnabled ? '通知权限已开启' : '通知权限没开，她主动找你的时候你看不到')
            .fontSize(11)
            .fontColor(this.notifyEnabled ? '#5E8A5E' : C_ACCENT)
            .width('100%')
            .margin({ top: 6 })
          if (!this.notifyEnabled) {
            Text('去开启通知')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(C_ACCENT)
              .borderRadius(14)
              .margin({ top: 8 })
              .onClick(() => {
                this.askNotification();
              })
          }

          this.sectionTitle('她的声音')
          Text('她的声音和听你说话的两个模型都跑在这台电脑上。电脑不开，语音就不可用（打字聊天不受影响）。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 8 })
          Text('当前：' + this.voiceRouteText)
            .fontSize(12)
            .fontColor(this.voiceRouteText === '语音服务没连上' ? '#C9614A' : '#5E8A5E')
            .width('100%')
            .margin({ bottom: 10 })
          Text('语音口令（要跟电脑上 config.json 的 token 一模一样）')
            .fontSize(12)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 6 })
          TextInput({ text: this.voiceToken, placeholder: '比如 dsv-xxxxxxxx' })
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.voiceToken = v.trim();
              // 立刻生效，不用等下一次冷启动
              VoiceService.tokenValue = this.voiceToken;
              this.saveSettings();
            })
          Text('家里地址（局域网直连）')
            .fontSize(12)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ bottom: 6 })
          TextInput({ text: this.voiceHost, placeholder: '比如 192.168.1.5:9880' })
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.voiceHost = v;
              this.saveSettings();
            })
          Text('外网地址（隧道，出门自动用）')
            .fontSize(12)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 12, bottom: 6 })
          TextInput({ text: this.voiceWanHost, placeholder: 'https://xxxx.trycloudflare.com' })
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.voiceWanHost = v;
              this.saveSettings();
            })
          Text('在家走局域网，出门自动切隧道，不用手动换地址。临时隧道每次重启都会换网址：开着自动同步时，在家连上局域网，电脑会把最新网址悄悄告诉手机。用固定域名就选「我用手填的」。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 8, bottom: 6 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('自动同步隧道地址', 'wanAuto', 'on', () => {
              this.voiceWanAuto = true;
              this.saveSettings();
            })
            this.chip('我用手填的', 'wanAuto', 'off', () => {
              this.voiceWanAuto = false;
              this.saveSettings();
            })
          }
          Row() {
            Text('重新检测')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(C_ACCENT)
              .borderRadius(14)
              .onClick(() => {
                this.testVoiceHost();
              })
            Text(this.voiceCheckMsg)
              .fontSize(11)
              .fontColor(this.voiceCheckMsg.indexOf('不通') >= 0 || this.voiceCheckMsg.indexOf('先填') >= 0
                ? '#C9614A' : '#5E8A5E')
              .layoutWeight(1)
              .margin({ left: 12 })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)

          Text('音色')
            .fontSize(12)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .margin({ top: 14, bottom: 6 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.chip('甜妹', 'voice', 'sweet', () => {
              this.voiceStyle = 'sweet';
              this.saveSettings();
            })
            this.chip('御姐', 'voice', 'queen', () => {
              this.voiceStyle = 'queen';
              this.saveSettings();
            })
          }

          this.sectionTitle('关于记忆')
          Text('已记下 ' + this.cards.length + ' 条，整理过 ' + this.archives.length + ' 段。')
            .fontSize(12)
            .fontColor(C_TEXT_DIM)
            .width('100%')
          Text(this.compacting ? '正在整理…' : '整理记忆（清掉重复、流水账和矛盾）')
            .fontSize(13)
            .fontColor(this.compacting ? C_TEXT_DIM : C_ACCENT)
            .width('100%')
            .padding({ top: 12, bottom: 4 })
            .onClick(() => {
              if (!this.compacting) {
                this.compactMemory();
              }
            })
          Text('把攒下来的记忆交给模型重排一遍，重复的合并、一次性的删掉。会调一次接口。')
            .fontSize(11)
            .fontColor(C_TEXT_DIM)
            .width('100%')
            .padding({ bottom: 10 })
          Text('重新认识她（清空全部记忆和对话）')
            .fontSize(13)
            .fontColor('#C9614A')
            .width('100%')
            .padding({ top: 14, bottom: 24 })
            .onClick(() => {
              this.resetAll();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: 10 })
    .backgroundColor(C_BG_TOP)
  }

  @Builder
  memoryPanel() {
    Column() {
      Row() {
        Text('她记得的')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
        Text('完成')
          .fontSize(14)
          .fontColor(C_ACCENT)
          .onClick(() => {
            this.saveProfileEdits();
            this.showMemory = false;
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      Scroll() {
        Column() {
          this.sectionTitle('她的名字')
          TextInput({ text: this.editHerName })
            .fontColor(C_TEXT)
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.editHerName = v;
            })

          this.sectionTitle('她怎么叫你')
          TextInput({ text: this.editUserName, placeholder: '比如：爸爸 / 哥哥 / 名字' })
            .fontColor(C_TEXT)
            .placeholderColor(C_TEXT_DIM)
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.editUserName = v;
            })

          this.sectionTitle('她的性格')
          TextArea({ text: this.editPersona })
            .fontColor(C_TEXT)
            .backgroundColor('#FFFFFF')
            .fontSize(13)
            .borderRadius(12)
            .constraintSize({ minHeight: 60 })
            .onChange((v: string) => {
              this.editPersona = v;
            })

          this.sectionTitle('关于你的事实')
          TextArea({ text: this.editFacts, placeholder: '她记下来的，也可以自己改' })
            .fontColor(C_TEXT)
            .placeholderColor(C_TEXT_DIM)
            .backgroundColor('#FFFFFF')
            .fontSize(13)
            .borderRadius(12)
            .constraintSize({ minHeight: 60 })
            .onChange((v: string) => {
              this.editFacts = v;
            })

          this.sectionTitle('你的习惯')
          TextArea({ text: this.editHabits })
            .fontColor(C_TEXT)
            .backgroundColor('#FFFFFF')
            .fontSize(13)
            .borderRadius(12)
            .constraintSize({ minHeight: 60 })
            .onChange((v: string) => {
              this.editHabits = v;
            })

          Row() {
            Text('零散的记忆 · ' + this.cards.length + ' 条')
              .fontSize(12)
              .fontColor(C_TEXT_DIM)
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 20, bottom: 8 })

          if (this.cards.length === 0) {
            Text('还没攒下什么。聊着聊着，她就会记住你。')
              .fontSize(12)
              .fontColor(C_TEXT_DIM)
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          }

          ForEach(this.cards, (c: MemoryCard) => {
            Row() {
              Column() {
                Text(c.text)
                  .fontSize(13.5)
                  .fontColor(C_TEXT)
                  .lineHeight(20)
                Text((c.source === 'observed' ? '她猜的 · ' : '') + c.kind)
                  .fontSize(10)
                  .fontColor(C_TEXT_DIM)
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(c.pinned ? '★' : '☆')
                .fontSize(16)
                .fontColor(c.pinned ? C_ACCENT : C_TEXT_DIM)
                .padding(6)
                .onClick(() => {
                  this.togglePin(c.id);
                })
              Text('×')
                .fontSize(16)
                .fontColor(C_TEXT_DIM)
                .padding(6)
                .onClick(() => {
                  this.deleteCard(c.id);
                })
            }
            .width('100%')
            .padding({ top: 9, bottom: 9, left: 12, right: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .margin({ bottom: 7 })
            .alignItems(VerticalAlign.Top)
          }, (c: MemoryCard) => c.id + (c.pinned ? 'p' : ''))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: 10 })
    .backgroundColor(C_BG_TOP)
  }

  build() {
    Stack() {
      Column() {
        this.topBar()

        List({ space: 4, scroller: this.scroller }) {
          ListItem() {
            Column()
              .height(6)
          }
          ForEach(this.messages, (m: Message, i: number) => {
            ListItem() {
              if (m.role === 'call') {
                this.callNote(m)
              } else {
                this.bubble(m, i)
              }
            }
          }, (m: Message) => m.id.toString() + '_' + m.content.length.toString())

          if (this.sending) {
            ListItem() {
              this.streamingBubble()
            }
          }

          ListItem() {
            Column()
              .height(10)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        this.inputBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C_BG)

      if (this.showSettings) {
        Column() {
          this.settingsPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(C_BG_TOP)
      }

      if (this.showMemory) {
        Column() {
          this.memoryPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(C_BG_TOP)
      }

      if (this.inCall) {
        this.callPage()
      }

      if (this.previewImage.length > 0) {
        this.imagePreview()
      }
    }
    .width('100%')
    .height('100%')
  }
}

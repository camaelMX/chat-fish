import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { DeepSeekService, ChatMessage } from '../service/DeepSeekService';
import { CompanionStore } from '../service/ChatStore';
import { VoiceStorage } from '../service/VoiceStorage';
import { MemoryService, Extracted, ExtractedCard } from '../service/MemoryService';
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
import { Line, Seg, parseMarkdown, stripMarkers } from '../common/Markdown';
import { isPeakNow, estimateCost, nextSwitchText } from '../common/Pricing';
import { VoiceInputService, VoiceInputEvents, VoiceClip } from '../service/VoiceInputService';
import { VoiceService } from '../service/VoiceService';
import { STICKERS, StickerDef, migrateStickerName } from '../common/Stickers';
import { PlayerService } from '../service/PlayerService';

/** 排队等她说完再发的语音 */
interface QueuedTurn {
  text: string;
  msg: Message;
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

  // ==================== 她的声音（GPT-SoVITS） ====================
  /** 局域网里那台跑 TTS 的电脑地址（host:port） */
  @State voiceHost: string = '';
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
    this.persistNow();
  }

  onPageShow(): void {
    // 回到前台就不用系统提醒了，改用页面里的计时器
    this.clearReminder();
    this.checkProactive();
  }

  onPageHide(): void {
    // 切后台时如果还按着说话，直接作废这一次
    if (this.recording) {
      this.recording = false;
      this.cancelArmed = false;
      this.voice.cancel();
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

  async loadSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.ctx(), PREF_NAME);
      this.apiKey = await store.get('apiKey', '') as string;
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
    VoiceService.hostValue = VoiceService.normalizeHost(this.voiceHost);
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
      await store.flush();
    } catch (e) {
      // 保存失败不影响聊天
    }
    this.applyHost();
    VoiceService.hostValue = VoiceService.normalizeHost(this.voiceHost);
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
    const req: ChatMessage[] = this.buildRequest(userText, userMsg.audioPath.length > 0);

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
      if (text.length === 0 && parts[0].length > 0) {
        text = parts[0];
      }
      let sticker: string = parts[1];
      // 她没主动发标记时：内容沾到表情标签就 50% 随机配一张
      if (sticker.length === 0 && text.length > 0) {
        sticker = this.autoSticker(text, userText);
      }
      if (text.length > 0) {
        this.pushMessage(new Message('assistant', text, '', Date.now(), false,
          '', 0, voiceReply));
        if (voiceReply) {
          // 这条是语音：立刻在后台合成，别等他点了才开始
          this.prewarmVoice(text);
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
      this.errMsg = '没有麦克风权限，在系统设置里给小满打开麦克风，才能按住说话。';
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
      old.audioPath, old.durationSec, old.voice, old.sticker);
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

  private buildRequest(userText: string, fromVoice: boolean): ChatMessage[] {
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
      if (m.content.trim().length === 0) {
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
      // 历史里的 emoji 会把她带回去照着发，喂之前先剥掉
      const cm: ChatMessage = { role: m.role, content: VoiceService.stripEmoji(m.content) };
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

  private mergeText(oldText: string, addText: string): string {
    const a: string = oldText.trim();
    const b: string = addText.trim();
    if (b.length === 0) {
      return a;
    }
    if (a.length === 0) {
      return b;
    }
    if (a.indexOf(b) >= 0) {
      return a;
    }
    return a + '；' + b;
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
      this.profile.herName.length > 0 ? this.profile.herName : '小满',
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
          Text(this.profile.herName.length > 0 ? this.profile.herName : '小满')
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
        }
      }, (ln: Line, li: number) => li.toString() + ln.kind)
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
        if (m.sticker.length === 0)
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
          .maxLines(12)
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
  private voiceUpAt: number = 0;

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
   * 她的声音服务此刻在不在（60 秒缓存，别每句话都去敲门）。
   * 不在线时回复一律落成文字气泡，免得给一个点开没声的语音气泡。
   */
  private async voiceServiceUp(): Promise<boolean> {
    if (VoiceService.hostValue.length === 0) {
      return false;
    }
    const now: number = Date.now();
    if (now - this.voiceUpAt < 60000) {
      return this.voiceUpCache;
    }
    this.voiceUpAt = now;
    this.voiceUpCache = (await VoiceService.checkHealth(VoiceService.hostValue)) === '';
    return this.voiceUpCache;
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

  /** 设置页测电脑上她声音服务的连通性 */
  private async testVoiceHost(): Promise<void> {
    this.voiceCheckMsg = '正在试…';
    const host: string = VoiceService.normalizeHost(this.voiceHost);
    if (host.length === 0) {
      this.voiceCheckMsg = '先填电脑地址';
      return;
    }
    const err: string = await VoiceService.checkHealth(host);
    this.voiceCheckMsg = err.length === 0 ? '通了，她的声音在线' : err;
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
    }
    .backgroundColor(C_BG_TOP)
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
          TextInput({ text: this.voiceHost, placeholder: '电脑地址，比如 192.168.1.5:9880' })
            .fontColor(C_TEXT)
            .placeholderColor('#B8AA9B')
            .backgroundColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onChange((v: string) => {
              this.voiceHost = v;
              VoiceService.hostValue = VoiceService.normalizeHost(v);
              this.saveSettings();
            })
          Row() {
            Text('测试连接')
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
              .fontColor(this.voiceCheckMsg === '通了，她的声音在线' ? '#5E8A5E' : '#C9614A')
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
              this.bubble(m, i)
            }
          }, (m: Message) => m.id.toString())

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
    }
    .width('100%')
    .height('100%')
  }
}

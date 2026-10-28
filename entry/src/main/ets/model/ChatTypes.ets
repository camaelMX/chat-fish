/** 落盘用的消息结构（字段可缺省，兼容旧版本数据） */
export interface SavedMessage {
  role: string;
  content: string;
  reasoning?: string;
  at?: number;
  proactive?: boolean;
  /** 语音消息：相对 filesDir 的录音文件路径（voice/v_xxx.wav） */
  audioPath?: string;
  /** 语音时长（秒，一位小数） */
  durationSec?: number;
  /** 她这条回复是否以语音条形态出现（随机决定） */
  voice?: boolean;
  /** 表情包消息：文件名（stickers/ 目录下） */
  sticker?: string;
}

/** 关系档案：她记得的“你是谁” */
export interface Profile {
  herName: string;
  userName: string;
  persona: string;
  facts: string;
  habits: string;
  tone: string;
  updatedAt: number;
}

/** 一条长期记忆 */
export interface MemoryCard {
  id: string;
  kind: string;
  text: string;
  tags: string;
  /** stated=TA 明确说过；observed=她观察到的，待确认 */
  source: string;
  createdAt: number;
  updatedAt: number;
  pinned: boolean;
  hits: number;
}

/** 一次记忆整理留下的摘要 */
export interface ArchiveChunk {
  id: string;
  at: number;
  count: number;
  summary: string;
}

/** 主动消息 / 提醒相关的运行状态 */
export interface StoreMeta {
  lastActiveAt: number;
  lastProactiveAt: number;
  proactiveDay: string;
  proactiveCount: number;
  /** 已排期的主动消息时间，0 表示没有 */
  proactiveDueAt: number;
  /** 已经生成好、到点要发的那句话 */
  proactiveText: string;
  /** 系统提醒 id，用于取消 */
  reminderId: number;
  /** 前多少条消息已经被整理进长期记忆 */
  memoryUpTo: number;
  lastConsolidatedAt: number;
}

/** companion.json 的顶层结构 */
export interface StoreData {
  version: number;
  messages: SavedMessage[];
  profile: Profile;
  cards: MemoryCard[];
  archives: ArchiveChunk[];
  meta: StoreMeta;
}

export function defaultProfile(): Profile {
  const p: Profile = {
    herName: '小满',
    userName: '',
    persona: '开朗活泼、有点黏人、会撒娇但懂分寸',
    facts: '',
    habits: '',
    tone: '口语、短句、像家人一样说话',
    updatedAt: 0
  };
  return p;
}

export function defaultMeta(): StoreMeta {
  const m: StoreMeta = {
    lastActiveAt: Date.now(),
    lastProactiveAt: 0,
    proactiveDay: '',
    proactiveCount: 0,
    proactiveDueAt: 0,
    proactiveText: '',
    reminderId: 0,
    memoryUpTo: 0,
    lastConsolidatedAt: 0
  };
  return m;
}

/** 生成唯一 id（本地足够） */
export function newId(prefix: string): string {
  return prefix + '-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 1000000).toString(36);
}

let msgSeq: number = 0;

/** 界面上的一条消息（id 只用于列表 diff） */
export class Message {
  id: number;
  role: string;
  content: string;
  reasoning: string;
  at: number;
  /** 她主动发来的消息，样式不一样 */
  proactive: boolean;
  /** 语音消息：录音文件的绝对路径；空串 = 纯文字消息 */
  audioPath: string;
  /** 语音时长（秒） */
  durationSec: number;
  /** 她的回复是否以语音条形态出现 */
  voice: boolean;
  /** 表情包消息：文件名 */
  sticker: string;

  constructor(role: string, content: string, reasoning: string = '',
    at: number = Date.now(), proactive: boolean = false,
    audioPath: string = '', durationSec: number = 0, voice: boolean = false,
    sticker: string = '') {
    msgSeq += 1;
    this.id = msgSeq;
    this.role = role;
    this.content = content;
    this.reasoning = reasoning;
    this.at = at;
    this.proactive = proactive;
    this.audioPath = audioPath;
    this.durationSec = durationSec;
    this.voice = voice;
    this.sticker = sticker;
  }
}

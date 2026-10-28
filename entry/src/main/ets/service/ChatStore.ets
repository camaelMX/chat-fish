import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  StoreData,
  SavedMessage,
  Message,
  Profile,
  MemoryCard,
  ArchiveChunk,
  StoreMeta,
  defaultProfile,
  defaultMeta,
  newId
} from '../model/ChatTypes';

const FILE_NAME: string = 'companion.json';
const LEGACY_FILE: string = 'deepseek_chats.json';
const MAX_MESSAGES: number = 400;

/** 旧版多会话文件的最小结构，只用来迁移 */
interface LegacySession {
  id?: string;
  title?: string;
  createdAt?: number;
  updatedAt?: number;
  messages?: SavedMessage[];
}

interface LegacyStore {
  version?: number;
  activeId?: string;
  sessions?: LegacySession[];
}

/**
 * 伴侣数据持久化：单条时间线 + 关系档案 + 记忆卡 + 归档。
 * preferences 单值只有 8KB，长对话会超限，所以正文全部走沙箱文件。
 */
export class CompanionStore {
  private static filePath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/' + FILE_NAME;
  }

  static empty(): StoreData {
    const data: StoreData = {
      version: 2,
      messages: [],
      profile: defaultProfile(),
      cards: [],
      archives: [],
      meta: defaultMeta()
    };
    return data;
  }

  static load(ctx: common.UIAbilityContext): StoreData {
    const path: string = CompanionStore.filePath(ctx);
    try {
      if (fileIo.accessSync(path)) {
        const raw: string = fileIo.readTextSync(path);
        if (raw.length > 0) {
          const data: StoreData = JSON.parse(raw) as StoreData;
          return CompanionStore.normalize(data);
        }
      }
    } catch (e) {
      // 文件坏了就走迁移/空数据，不让 App 起不来
    }
    return CompanionStore.migrateLegacy(ctx);
  }

  /** 补齐旧版本缺的字段，避免 undefined 到处炸 */
  static normalize(data: StoreData): StoreData {
    const out: StoreData = CompanionStore.empty();
    if (data === null) {
      return out;
    }
    if (data.messages !== undefined && data.messages !== null) {
      out.messages = data.messages;
    }
    if (data.profile !== undefined && data.profile !== null) {
      const p: Profile = data.profile;
      out.profile = {
        herName: p.herName !== undefined ? p.herName : '小满',
        userName: p.userName !== undefined ? p.userName : '',
        persona: p.persona !== undefined ? p.persona : defaultProfile().persona,
        facts: p.facts !== undefined ? p.facts : '',
        habits: p.habits !== undefined ? p.habits : '',
        tone: p.tone !== undefined ? p.tone : defaultProfile().tone,
        updatedAt: p.updatedAt !== undefined ? p.updatedAt : 0
      };
    }
    if (data.cards !== undefined && data.cards !== null) {
      out.cards = data.cards;
    }
    if (data.archives !== undefined && data.archives !== null) {
      out.archives = data.archives;
    }
    if (data.meta !== undefined && data.meta !== null) {
      const m: StoreMeta = data.meta;
      const base: StoreMeta = defaultMeta();
      out.meta = {
        lastActiveAt: m.lastActiveAt !== undefined ? m.lastActiveAt : base.lastActiveAt,
        lastProactiveAt: m.lastProactiveAt !== undefined ? m.lastProactiveAt : 0,
        proactiveDay: m.proactiveDay !== undefined ? m.proactiveDay : '',
        proactiveCount: m.proactiveCount !== undefined ? m.proactiveCount : 0,
        proactiveDueAt: m.proactiveDueAt !== undefined ? m.proactiveDueAt : 0,
        proactiveText: m.proactiveText !== undefined ? m.proactiveText : '',
        reminderId: m.reminderId !== undefined ? m.reminderId : 0,
        memoryUpTo: m.memoryUpTo !== undefined ? m.memoryUpTo : 0,
        lastConsolidatedAt: m.lastConsolidatedAt !== undefined ? m.lastConsolidatedAt : 0
      };
    }
    return out;
  }

  /** 把旧版“多会话”合并成一条时间线，只保留最近的若干条 */
  private static migrateLegacy(ctx: common.UIAbilityContext): StoreData {
    const out: StoreData = CompanionStore.empty();
    try {
      const path: string = ctx.filesDir + '/' + LEGACY_FILE;
      if (!fileIo.accessSync(path)) {
        return out;
      }
      const raw: string = fileIo.readTextSync(path);
      const old: LegacyStore = JSON.parse(raw) as LegacyStore;
      if (old === null || old.sessions === undefined) {
        return out;
      }
      const all: SavedMessage[] = [];
      for (let i: number = 0; i < old.sessions.length; i++) {
        const s: LegacySession = old.sessions[i];
        const msgs: SavedMessage[] = s.messages !== undefined ? s.messages : [];
        for (let j: number = 0; j < msgs.length; j++) {
          all.push(msgs[j]);
        }
      }
      const start: number = all.length > MAX_MESSAGES ? all.length - MAX_MESSAGES : 0;
      for (let i: number = start; i < all.length; i++) {
        const m: SavedMessage = all[i];
        const saved: SavedMessage = {
          role: m.role,
          content: m.content,
          reasoning: m.reasoning !== undefined ? m.reasoning : '',
          at: m.at !== undefined ? m.at : Date.now(),
          proactive: false
        };
        out.messages.push(saved);
      }
      // 旧数据没有时间戳时，按顺序补一个递增的近似时间
      let last: number = Date.now() - out.messages.length * 60000;
      for (let i: number = 0; i < out.messages.length; i++) {
        if (out.messages[i].at === undefined || out.messages[i].at === 0) {
          out.messages[i].at = last;
        }
        last = out.messages[i].at as number;
      }
      const now: number = Date.now();
      out.profile.updatedAt = now;
      out.meta.memoryUpTo = out.messages.length;
      out.meta.lastConsolidatedAt = now;
    } catch (e) {
      return CompanionStore.empty();
    }
    return out;
  }

  static save(ctx: common.UIAbilityContext, data: StoreData): boolean {
    try {
      const path: string = CompanionStore.filePath(ctx);
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 把会话数据转成消息数组（供页面加载） */
  static toMessages(ctx: common.UIAbilityContext, data: StoreData): Message[] {
    const out: Message[] = [];
    for (let i: number = 0; i < data.messages.length; i++) {
      const m: SavedMessage = data.messages[i];
      // 语音文件存相对路径（voice/v_x.wav），加载时拼回绝对路径
      let audio: string = '';
      if (m.audioPath !== undefined && m.audioPath.length > 0) {
        audio = m.audioPath.startsWith('/') ? m.audioPath : ctx.filesDir + '/' + m.audioPath;
      }
      out.push(new Message(m.role, m.content,
        m.reasoning !== undefined ? m.reasoning : '',
        m.at !== undefined ? m.at : Date.now(),
        m.proactive === true,
        audio,
        m.durationSec !== undefined ? m.durationSec : 0,
        m.voice === true,
        m.sticker !== undefined ? m.sticker : ''));
    }
    return out;
  }

  /** 把消息数组写回存储结构 */
  static fromMessages(ctx: common.UIAbilityContext, messages: Message[]): SavedMessage[] {
    const out: SavedMessage[] = [];
    for (let i: number = 0; i < messages.length; i++) {
      const m: Message = messages[i];
      const s: SavedMessage = {
        role: m.role,
        content: m.content,
        reasoning: m.reasoning,
        at: m.at,
        proactive: m.proactive
      };
      if (m.audioPath.length > 0) {
        const p: string = m.audioPath;
        s.audioPath = p.startsWith(ctx.filesDir) ? p.substring(ctx.filesDir.length + 1) : p;
        s.durationSec = m.durationSec;
      }
      if (m.voice) {
        s.voice = true;
      }
      if (m.sticker !== undefined && m.sticker.length > 0) {
        s.sticker = m.sticker;
      }
      out.push(s);
    }
    return out;
  }

  static newCard(kind: string, text: string, tags: string, source: string): MemoryCard {
    const now: number = Date.now();
    const c: MemoryCard = {
      id: newId('m'),
      kind: kind,
      text: text,
      tags: tags,
      source: source,
      createdAt: now,
      updatedAt: now,
      pinned: false,
      hits: 0
    };
    return c;
  }

  static newArchive(count: number, summary: string): ArchiveChunk {
    const a: ArchiveChunk = {
      id: newId('a'),
      at: Date.now(),
      count: count,
      summary: summary
    };
    return a;
  }
}

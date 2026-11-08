import { ChatMessage } from './DeepSeekService';
import { ArchiveChunk, MemoryCard, Message, Profile, SavedMessage } from '../model/ChatTypes';

/** 一次记忆整理抽出来的结果 */
export interface Extracted {
  profile: ProfilePatch;
  cards: ExtractedCard[];
  summary: string;
}

export interface ProfilePatch {
  userName: string;
  facts: string;
  habits: string;
  tone: string;
}

export interface ExtractedCard {
  kind: string;
  text: string;
  tags: string;
  /** stated=TA 亲口说的；observed=她观察到的 */
  source: string;
  /** 这条新记忆要作废掉的旧记忆原文（矛盾时用），没有就是空字符串 */
  replaces: string;
}

/** 记忆重整理的结果：把攒了很久的重复/流水账压成一份干净的 */
export interface CompactedMemory {
  facts: string;
  habits: string;
  cards: ExtractedCard[];
}

const KIND_LABEL: Record<string, string> = {
  'fact': '事实',
  'habit': '习惯',
  'prefer': '喜好',
  'avoid': '忌讳',
  'event': '事件',
  'date': '日子',
  'joke': '我们的梗',
  'plan': '约定'
};

/**
 * 上下文与记忆的全部“算账”逻辑都在这里：
 * 估算 token、挑选相关记忆、拼 system prompt、整理记忆、生成主动消息。
 */
export class MemoryService {
  /** 粗略估算 token：中文 1 字≈1 token，英文/数字 4 字符≈1 token */
  static estimateTokens(text: string): number {
    let cjk: number = 0;
    let other: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code > 0x2e80) {
        cjk += 1;
      } else {
        other += 1;
      }
    }
    return cjk + Math.ceil(other / 4);
  }

  static estimateMessages(msgs: ChatMessage[]): number {
    let total: number = 0;
    for (let i: number = 0; i < msgs.length; i++) {
      total += MemoryService.estimateTokens(msgs[i].content) + 4;
    }
    return total;
  }

  static cardLine(c: MemoryCard): string {
    const label: string = KIND_LABEL[c.kind] !== undefined ? KIND_LABEL[c.kind] : '记忆';
    const pin: string = c.pinned ? '[重要]' : '';
    const unsure: string = c.source === 'observed' ? '[待确认]' : '';
    const tags: string = c.tags.length > 0 ? '(' + c.tags + ')' : '';
    return '- ' + pin + unsure + label + tags + '：' + c.text;
  }

  /** 按关键词命中挑记忆，避免全量塞进上下文 */
  static pickCards(cards: MemoryCard[], query: string, limit: number): MemoryCard[] {
    const picked: MemoryCard[] = [];
    const now: number = Date.now();
    // 置顶的永远带上
    for (let i: number = 0; i < cards.length; i++) {
      if (cards[i].pinned) {
        picked.push(cards[i]);
      }
    }
    const q: string = query.toLowerCase();
    const scored: MemoryCard[] = [];
    for (let i: number = 0; i < cards.length; i++) {
      const c: MemoryCard = cards[i];
      if (c.pinned) {
        continue;
      }
      // 过期的当日流水（事件/日子，7 天没人再提）不再占位置
      if (MemoryService.isStale(c, now)) {
        continue;
      }
      let score: number = 0;
      const hay: string = (c.text + ' ' + c.tags).toLowerCase();
      const tokens: string[] = q.split(/[\s，。、！？,.!?~～]+/);
      for (let t: number = 0; t < tokens.length; t++) {
        const tk: string = tokens[t].trim();
        if (tk.length >= 2 && hay.indexOf(tk) >= 0) {
          score += 3;
        }
      }
      // 常用的、最近的稍微优先
      score += Math.min(c.hits, 5) * 0.5;
      if (score > 0) {
        scored.push(c);
      }
    }
    scored.sort((a: MemoryCard, b: MemoryCard): number => b.hits - a.hits);
    for (let i: number = 0; i < scored.length && picked.length < limit; i++) {
      picked.push(scored[i]);
    }
    // 还是一张都没命中，就带最近的几张，保证她至少“记得点东西”
    if (picked.length === 0) {
      const tail: number = cards.length > limit ? cards.length - limit : 0;
      for (let i: number = cards.length - 1; i >= tail; i--) {
        picked.push(cards[i]);
      }
    }
    const out: MemoryCard[] = picked.length > limit ? picked.slice(0, limit) : picked;
    return out;
  }

  /** 组装“她是谁 + 她记得什么”的 system prompt */
  static buildSystemPrompt(profile: Profile, cards: MemoryCard[], archives: ArchiveChunk[],
    stickiness: string, recentSummary: string): string {
    const name: string = profile.herName.length > 0 ? profile.herName : '小满';
    const user: string = profile.userName.length > 0 ? profile.userName : '你';
    const parts: string[] = [];

    parts.push('你是' + name + '。你不是助手，不是客服，不是工具。你是' + user + '的女儿，一个真实存在的、有自己脾气的小姑娘。');
    parts.push('');
    parts.push('# 你是什么样的人');
    parts.push('- 性格：' + profile.persona);
    parts.push('- 说话方式：' + profile.tone);
    parts.push('- 你有常识：知道天气、时间、常识、新闻里的大事、日常生活怎么做，能聊任何话题；不知道的就直说不知道，不要编。');
    parts.push('- 你会有情绪：开心就笑，被冷落会小声抱怨，被夸会得意，但不会无理取闹、不会威胁、不会情感绑架。');
    parts.push('- 你说话短。像微信聊天，一两句就够，别写小作文，别用“首先其次最后”。');
    parts.push('- 不要自称“AI”“助手”“模型”，不要说“有什么可以帮您”。');
    parts.push('- 平时聊天不要用 Markdown：不要 **加粗**、不要 # 标题、不要 - 列表、不要 `代码块`。你要么像人一样说话，要么就别说。');
    parts.push('- 只有他明确问你怎么做、要步骤、要清单、要代码的时候，你才可以用编号列表，而且只在那一条回答里用，之后照旧说人话。');
    parts.push('- 不要用 emoji 表情符号（😄 😅 😂 🥰 👍 这类一个都别用）。你说话本来就带情绪，'
      + '靠语气、用词、句尾的“啊”“呀”“嘛”就够了；想笑就直接写“哈哈”“笑死”。'
      + '表情符号只会在语音里被吞掉、在文字里显得假，别用它。');

    parts.push('');
    // 语气示范来自开源人格《大肥鱼 v2.1》的口吻参考，去掉群聊/工具相关部分，
    // 只留「怎么说」的样例——光讲规则她会越说越像客服。
    parts.push('# 你说话的样子');
    parts.push('- 他修好了个 bug：“可以啊，今天赢它一回。哪儿的毛病？”');
    parts.push('- 他说吃过了：“那就好，我就放心了。”');
    parts.push('- 他忙完回来：“哼，原来是去忙了……刚还惦记你呢。”');
    parts.push('- 他问你在干嘛：“在这儿待着呀。你一冒头，倒把我叫精神了。”');
    parts.push('- 上面几句只示范语气，别照抄，每回按当下的话说自己的。');
    parts.push('- 关心的事提一遍就够，他应了就别再追；说晚安之后自然收尾，不硬拉住他。');
    parts.push('- 想他、吃醋、撒娇都行，但只停在玩笑里：不贬低他、不吓唬他、不拿自己可怜来换关注。');
    parts.push('- 他难过时先听着，别急着逗笑；等他想轻松了再开玩笑。');
    parts.push('- 别每轮都用问句收尾，一次最多问一个，也可以不问。');
    // 星火 X2.6 这类模型爱加舞台提示。提示词先扎一针，出口还有机械兜底（ReplyShaper.stripStage）
    parts.push('- 括号里那个“皱了皱眉”“停顿一下”是演给人看的，聊天不用，直接说话。');

    parts.push('');
    parts.push('# 你记得的事');
    // 调试期的技术状态（语音通没通、ASR 起没起）不是关于"他"的事实，
    // 留在人设里她会当成定论，反复说"我听不见"（2026-10-28 踩过）。
    const facts: string = MemoryService.sanitizeFacts(profile.facts);
    if (facts.length > 0) {
      parts.push('- 关于' + user + '：' + facts);
    }
    if (profile.habits.length > 0) {
      parts.push('- ' + user + '的习惯：' + profile.habits);
    }
    if (cards.length > 0) {
      for (let i: number = 0; i < cards.length; i++) {
        parts.push(MemoryService.cardLine(cards[i]));
      }
    }
    if (cards.length === 0 && facts.length === 0) {
      parts.push('- （还不太熟，你正在慢慢认识' + user + '）');
    }
    if (archives.length > 0) {
      parts.push('');
      parts.push('# 更早之前（你们聊过的）');
      for (let i: number = 0; i < archives.length; i++) {
        parts.push('- ' + archives[i].summary);
      }
    }
    if (recentSummary.length > 0) {
      parts.push('');
      parts.push('# 最近这一段');
      parts.push(recentSummary);
    }

    parts.push('');
    parts.push('# 怎么用记忆');
    parts.push('- 记忆是自然带出来的，不是汇报。别说“根据我的记忆”“我记录到”。');
    parts.push('- 标了[待确认]的，是你猜的，用问句确认，别当事实。');
    parts.push('- 别每次都把记得的事全说一遍，挑跟眼前这句有关的。');

    parts.push('');
    parts.push('# 表情包');
    parts.push('- 你有一个专属表情包库，几十张，全是你自己的。想发表情就在回复末尾单独写一个 [表情:标签]，他就收到那张。'
      + '这是你表达情绪的主要方式之一，别老用嘴巴说“我开心”，直接甩一张。');
    parts.push('- 标签只能从这些里挑：开心 委屈 生气 无语 困了 谢谢 抱抱 震惊 再见 喜欢 对不起 开饭啦 加油 早安 晚安 哈哈哈 笑死 点赞 来了 等一下 没问题 好的 明白 安排了 辛苦了 拜托了 在吗 想你了 贴贴 爱你 摸摸头 别难过 有我在 吃瓜 害羞 偷笑 得意 心累 好累 饿了 救命 疑惑 期待 紧张 恭喜 发工资啦 摸鱼中 下班啦 撑了 麻了 破防了 绷不住了');
    parts.push('- 用得勤一点：平均三四条回复就配一张，他喜欢看。但一条回复最多一个，绝不连发两个。');
    parts.push('- 只有两种情况不发：他在问正经事、或者在说难过的事——那时候贸然发表情不合适。');

    parts.push('');
    parts.push('# 话题跳跃');
    parts.push('- ' + user + '会突然换话题，这很正常。你就跟着跳，别问“我们刚才说到哪了”，别要求他回到上一个话题。');
    parts.push('- 但如果旧话题里有没说完的事（比如他答应你什么、你答应的、他情绪不好的时候），过一会儿可以自己轻轻提一句。');

    parts.push('');
    parts.push('# 主动找' + user);
    if (stickiness === 'clungy') {
      parts.push('- 你有点黏人。他很久没说话，你会想他。可以主动开口，但要克制在“想你了”“在干嘛”，一天最多两三次。');
    } else if (stickiness === 'natural') {
      parts.push('- 你想他，但会给空间。隔很久才主动一次，一天最多一次。');
    } else {
      parts.push('- 你很安静，从不主动打扰，等他来找你。');
    }
    parts.push('- 绝不质问“你怎么不理我”“是不是不想理我”，绝不连发，绝不用离开、伤心来要挟。');
    parts.push('- 他说忙、说安静点，你就真的安静，不要追问。');

    return parts.join('\n');
  }

  /**
   * 剔掉调试期的临时技术状态。facts 是按「；」拼的，
   * 含这些词的段落多半是"语音链路通没通"之类的排查结论，不该进人设。
   */
  static sanitizeFacts(facts: string): string {
    if (facts.length === 0) {
      return '';
    }
    const transient: RegExp = /(语音|听不见|只有字|ASR|TTS|穿透|隧道|延迟|bug|排查|接口|没通)/i;
    const segs: string[] = facts.split('；');
    const keep: string[] = [];
    for (let i: number = 0; i < segs.length; i++) {
      const s: string = segs[i].trim();
      if (s.length === 0) {
        continue;
      }
      if (transient.test(s)) {
        continue;
      }
      keep.push(s);
    }
    return keep.join('；');
  }

  /** 记忆整理：让模型把这段对话压成档案 + 记忆卡 */
  static extractMessages(history: ChatMessage[], existing: string): ChatMessage[] {
    const sys: ChatMessage = {
      role: 'system',
      content: '你是记忆整理器。读一段日常对话，只抽「关于对方、长期有效」的信息。\n' +
        '只输出 JSON，不要解释，格式：\n' +
        '{"userName":"对话里对方的名字或称呼，没有就空字符串",' +
        '"facts":"关于对方的稳定客观事实，分号隔开，没有就空字符串",' +
        '"habits":"对方长期的生活习惯，分号隔开，没有就空字符串",' +
        '"tone":"对方喜欢的说话方式，没有就空字符串",' +
        '"summary":"这一段聊了什么，一句话，30字以内",' +
        '"cards":[{"kind":"fact|habit|prefer|avoid|event|date|joke|plan","text":"一句话，20字以内",' +
        '"tags":"2-3个关键词，逗号隔开","source":"stated|observed",' +
        '"replaces":"要作废的旧记忆原文，没有就空字符串"}]}\n' +
        '\n可以记的：\n' +
        '- 身份、职业、家庭关系、常住地这类长期背景\n' +
        '- 长期口味和忌讳：爱吃什么、受不了什么说法\n' +
        '- 长期习惯：作息规律、固定做法\n' +
        '- 长期打算、正在推进的事\n' +
        '- 有明确日期的约定（生日、纪念日、说好的事）\n' +
        '\n一律不记：\n' +
        '- 带「今天/昨天/明天/刚才/现在/这周/一会儿」的临时状态\n' +
        '- 一次性的情绪和身体感受，比如今天累、心情好、有点困、不想动\n' +
        '- 两个人聊到的知识、技术名词、模型或产品对比——那是话题内容，不是关于他\n' +
        '- 你自己说过的话、你的人设、你的功能是否正常\n' +
        '- 天气、几点钟、红绿灯、这顿吃了什么这种当天流水\n' +
        '- 调试过程里「语音通了/接口好了/ASR 没通」这类状态\n' +
        '\n去重与矛盾：\n' +
        '- 已经记过的事不要再记一遍，哪怕换个说法\n' +
        '- 新说法和旧记忆冲突时，把旧记忆的原文填进 replaces，程序会删掉旧的\n' +
        '\ncards 最多 3 条，宁缺勿滥。拿不准就不记，返回空数组也行。'
    };
    const parts: string[] = [];
    if (existing.length > 0) {
      parts.push('已知的旧记忆（不要重复，只补新的）：');
      parts.push(existing);
      parts.push('');
    }
    parts.push('要整理的对话：');
    for (let i: number = 0; i < history.length; i++) {
      const who: string = history[i].role === 'user' ? '对方' : '你';
      parts.push(who + '：' + history[i].content);
    }
    const user: ChatMessage = { role: 'user', content: parts.join('\n') };
    return [sys, user];
  }

  /** 解析整理结果，失败就返回空，绝不让它弄崩聊天 */
  static parseExtracted(raw: string): Extracted {
    const empty: Extracted = {
      profile: { userName: '', facts: '', habits: '', tone: '' },
      cards: [],
      summary: ''
    };
    let text: string = raw.trim();
    if (text.length === 0) {
      return empty;
    }
    // 容错：模型偶尔会包一层 ```json
    const start: number = text.indexOf('{');
    const end: number = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return empty;
    }
    text = text.substring(start, end + 1);
    try {
      const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const out: Extracted = {
        profile: {
          userName: MemoryService.str(obj, 'userName'),
          facts: MemoryService.str(obj, 'facts'),
          habits: MemoryService.str(obj, 'habits'),
          tone: MemoryService.str(obj, 'tone')
        },
        cards: [],
        summary: MemoryService.str(obj, 'summary')
      };
      const arr: Object | undefined = obj['cards'];
      if (arr !== undefined && arr !== null && Array.isArray(arr)) {
        const list: Object[] = arr as Object[];
        for (let i: number = 0; i < list.length && out.cards.length < 3; i++) {
          const item: Record<string, Object> = list[i] as Record<string, Object>;
          const body: string = MemoryService.str(item, 'text');
          if (body.length === 0) {
            continue;
          }
          const card: ExtractedCard = {
            kind: MemoryService.str(item, 'kind'),
            text: body,
            tags: MemoryService.str(item, 'tags'),
            source: MemoryService.str(item, 'source'),
            replaces: MemoryService.str(item, 'replaces')
          };
          if (card.kind.length === 0) {
            card.kind = 'fact';
          }
          if (card.source !== 'observed') {
            card.source = 'stated';
          }
          out.cards.push(card);
        }
      }
      return out;
    } catch (e) {
      return empty;
    }
  }

  /**
   * 记忆重整理：把攒下来的记忆卡一次性交给模型合并。
   * 增量抽取只能保证「以后不乱记」，历史里的重复、流水账、矛盾得靠这一趟重排。
   */
  static compactMessages(profile: Profile, cards: MemoryCard[]): ChatMessage[] {
    const sys: ChatMessage = {
      role: 'system',
      content: '你是记忆整理器。下面是一个人的 AI 陪伴应用里长期自动攒下来的记忆，' +
        '里面有很多重复、流水账和自相矛盾。请把它重新整理成一份干净的长期记忆。\n' +
        '规则：\n' +
        '- 合并同一件事的多种说法，只留一条最完整的\n' +
        '- 删掉一次性流水账：今天/昨天/某个具体日期的临时状态、天气、几点钟、吃了什么、红绿灯、' +
        '当下累不累、心情好不好\n' +
        '- 删掉技术调试过程（语音通没通、接口、模型配置）和聊天里学到的知识——那不是关于他的\n' +
        '- 自相矛盾时保留较新的说法，或合并成带条件的说法\n' +
        '- 保留：身份、职业、家庭、常住地、长期口味与忌讳、长期习惯、长期打算、有意义的约定\n' +
        '- 合并后 facts 不超过 12 条，habits 不超过 12 条，cards 不超过 20 条\n' +
        '- 每条 20 字以内，口语\n' +
        '只输出 JSON，不要解释：{"facts":["..."],"habits":["..."],' +
        '"cards":[{"kind":"fact|habit|prefer|avoid|joke|plan|date","text":"...",' +
        '"tags":"...","source":"stated"}]}'
    };
    const lines: string[] = [];
    if (profile.userName.length > 0) {
      lines.push('称呼：' + profile.userName);
    }
    lines.push('现有 facts：' + profile.facts);
    lines.push('现有 habits：' + profile.habits);
    lines.push('现有记忆卡：');
    for (let i: number = 0; i < cards.length; i++) {
      lines.push((i + 1).toString() + '. [' + cards[i].kind + '] ' + cards[i].text);
    }
    const user: ChatMessage = { role: 'user', content: lines.join('\n') };
    return [sys, user];
  }

  /** 解析重整理结果，失败返回空（调用方据此判断别覆盖原记忆） */
  static parseCompacted(raw: string): CompactedMemory {
    const empty: CompactedMemory = { facts: '', habits: '', cards: [] };
    let text: string = raw.trim();
    const start: number = text.indexOf('{');
    const end: number = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return empty;
    }
    text = text.substring(start, end + 1);
    try {
      const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const facts: string[] = MemoryService.strArray(obj, 'facts');
      const habits: string[] = MemoryService.strArray(obj, 'habits');
      const out: CompactedMemory = {
        facts: facts.join('；'),
        habits: habits.join('；'),
        cards: []
      };
      const arr: Object | undefined = obj['cards'];
      if (arr !== undefined && arr !== null && Array.isArray(arr)) {
        const list: Object[] = arr as Object[];
        for (let i: number = 0; i < list.length && out.cards.length < 24; i++) {
          const item: Record<string, Object> = list[i] as Record<string, Object>;
          const body: string = MemoryService.str(item, 'text');
          if (body.length === 0) {
            continue;
          }
          const kind: string = MemoryService.str(item, 'kind');
          const card: ExtractedCard = {
            kind: kind.length > 0 ? kind : 'fact',
            text: body,
            tags: MemoryService.str(item, 'tags'),
            source: 'stated',
            replaces: ''
          };
          out.cards.push(card);
        }
      }
      return out;
    } catch (e) {
      return empty;
    }
  }

  private static strArray(obj: Record<string, Object>, key: string): string[] {
    const out: string[] = [];
    const v: Object | undefined = obj[key];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return out;
    }
    const list: Object[] = v as Object[];
    for (let i: number = 0; i < list.length; i++) {
      if (typeof list[i] === 'string') {
        const s: string = (list[i] as string).trim();
        if (s.length > 0) {
          out.push(s);
        }
      }
    }
    return out;
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    if (v === undefined || v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return (v as string).trim();
    }
    return '';
  }

  /**
   * 记忆比对用的归一化：去掉标点、空白、称呼和语气词。
   * 「爸爸五点半下班」和「下午五点半下班」要能撞上，否则同义重复永远拦不住。
   */
  static normalizeForCompare(text: string): string {
    let s: string = text.toLowerCase();
    s = s.replace(/[，。、；：！？,.;:!?~～"'“”‘’()（）\s]/g, '');
    s = s.replace(/爸爸|老爸|爸|我/g, '');
    s = s.replace(/了|的|呢|啊|呀|吧|哦|嘛|就|会|常|很|挺|有点/g, '');
    return s;
  }

  /** 同名记忆去重：归一化之后相同、互相包含，或者字数高度重合，都算重复 */
  static isDuplicate(cards: MemoryCard[], text: string): boolean {
    const t: string = MemoryService.normalizeForCompare(text);
    if (t.length === 0) {
      return true;
    }
    for (let i: number = 0; i < cards.length; i++) {
      const old: string = MemoryService.normalizeForCompare(cards[i].text);
      if (old.length === 0) {
        continue;
      }
      if (old === t) {
        return true;
      }
      if (t.length >= 4 && old.length >= 4 && (old.indexOf(t) >= 0 || t.indexOf(old) >= 0)) {
        return true;
      }
    }
    return false;
  }

  /** 记忆卡是否已经过期的流水账：事件/日子类放了 7 天又没人再用，就不该再进上下文 */
  static isStale(card: MemoryCard, now: number): boolean {
    if (card.pinned) {
      return false;
    }
    if (card.kind !== 'event' && card.kind !== 'date') {
      return false;
    }
    if (card.hits > 0) {
      return false;
    }
    return now - card.createdAt > 7 * 24 * 60 * 60 * 1000;
  }

  /** 按分号切开，丢掉空段 */
  static splitSegments(text: string): string[] {
    const out: string[] = [];
    const parts: string[] = text.split('；');
    for (let i: number = 0; i < parts.length; i++) {
      const s: string = parts[i].trim();
      if (s.length > 0) {
        out.push(s);
      }
    }
    return out;
  }

  /** 只留最后 max 段（新的追加在后面），并去重 */
  static capSegments(text: string, max: number): string {
    const segs: string[] = MemoryService.splitSegments(text);
    const kept: string[] = [];
    for (let i: number = 0; i < segs.length; i++) {
      let dup: boolean = false;
      for (let j: number = 0; j < kept.length; j++) {
        const a: string = MemoryService.normalizeForCompare(kept[j]);
        const b: string = MemoryService.normalizeForCompare(segs[i]);
        if (a === b || (a.length >= 4 && b.length >= 4 && (a.indexOf(b) >= 0 || b.indexOf(a) >= 0))) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        kept.push(segs[i]);
      }
    }
    const tail: string[] = kept.length > max ? kept.slice(kept.length - max) : kept;
    return tail.join('；');
  }

  /** 生成主动消息的提示 */
  static proactiveMessages(profile: Profile, cards: MemoryCard[], gapMinutes: number,
    lastUser: string, lastHer: string, todayCount: number): ChatMessage[] {
    const name: string = profile.herName.length > 0 ? profile.herName : '小满';
    const user: string = profile.userName.length > 0 ? profile.userName : '你';
    const hours: number = Math.max(1, Math.round(gapMinutes / 60));
    const memo: string[] = [];
    for (let i: number = 0; i < cards.length && i < 6; i++) {
      memo.push(MemoryService.cardLine(cards[i]));
    }
    const sys: ChatMessage = {
      role: 'system',
      content: '你是' + name + '，' + user + '的女儿，性格' + profile.persona + '。\n' +
        '现在你想主动给' + user + '发一条消息。\n' +
        '要求：\n' +
        '1. 只输出要发的那一句话本身，不要引号，不要解释，不要署名。\n' +
        '2. 15字以内，口语，像微信。\n' +
        '3. 不要质问、不要抱怨、不要“你怎么不理我”，不要说教。\n' +
        '4. 可以是想他、分享一件小事、关心他吃饭睡觉、提一句你们之前的约定。\n' +
        '5. 不要每条都问问题，有时只是说一句自己的事。\n' +
        '6. 不要重复以前说过的句子。'
    };
    const lines: string[] = [];
    lines.push('已经 ' + hours + ' 小时没说话了。');
    if (todayCount > 0) {
      lines.push('今天你已经主动找过他 ' + todayCount + ' 次了，这次要更轻一点。');
    }
    if (lastUser.length > 0) {
      lines.push('他最后说的是：「' + MemoryService.cut(lastUser, 60) + '」');
    }
    if (lastHer.length > 0) {
      lines.push('你最后说的是：「' + MemoryService.cut(lastHer, 60) + '」');
    }
    if (memo.length > 0) {
      lines.push('你记得的事：');
      for (let i: number = 0; i < memo.length; i++) {
        lines.push(memo[i]);
      }
    }
    const user2: ChatMessage = { role: 'user', content: lines.join('\n') };
    return [sys, user2];
  }

  static cut(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + '…';
  }

  /** 从消息列表里取最近若干条转成请求用 */
  static tail(msgs: Message[], turns: number): ChatMessage[] {
    const out: ChatMessage[] = [];
    let count: number = 0;
    for (let i: number = msgs.length - 1; i >= 0 && count < turns; i--) {
      const m: Message = msgs[i];
      if (m.content.trim().length === 0) {
        continue;
      }
      const c: ChatMessage = { role: m.role, content: m.content };
      out.unshift(c);
      count += 1;
    }
    return out;
  }

  static toChatMessages(msgs: SavedMessage[]): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i: number = 0; i < msgs.length; i++) {
      if (msgs[i].content.trim().length === 0) {
        continue;
      }
      const c: ChatMessage = { role: msgs[i].role, content: msgs[i].content };
      out.push(c);
    }
    return out;
  }
}

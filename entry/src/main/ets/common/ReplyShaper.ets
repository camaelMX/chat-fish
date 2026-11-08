/**
 * 出站整形：把她要说的话在显示前过一遍「机械橡皮擦」。
 *
 * 来自 whyever77/dafeiyu-astrbot 的踩坑合集：
 * - 「回声病」：LLM 会模仿自己最近说过的话，系统提示压不住聊天记录里的自己。
 *   解法是人格针（提示词）+ 机械层（发送前按句删掉重复片段）双保险。
 * - 橡皮擦纪律：关键词要收窄，宁可漏抓，不可错杀。
 *
 * 这里只做四件确定性的事，不改语义、不猜意图：
 * 1. 拆掉模型偶尔返回的数组壳  ["你好", "呀"]
 * 2. 标点归一：『』「」→ “”，顿号接分句 → 逗号
 * 3. 开头复读：跟上一条自己说过的开头一模一样时，删掉这个开头
 * 4. 收尾空白
 */
export class ReplyShaper {
  /** 开场白最长认这么多个字，超出的不算「同一句开头」 */
  private static readonly OPENER_MAX: number = 14;
  /** 短于这个字数就不拆，一句话能说完的事拆开反而不像人 */
  private static readonly SPLIT_MIN_TOTAL: number = 26;
  /** 一个气泡最短多少字，太短就并到上一条 */
  private static readonly PART_MIN: number = 7;
  /** 最多拆成几条，多了会刷屏 */
  private static readonly PART_MAX: number = 3;

  /**
   * 把一整段回复拆成真人那样的几条。
   * 真人聊天是一句一条，不是一口气说完还带完整标点。
   */
  static split(text: string): string[] {
    const t: string = text.trim();
    if (t.length <= ReplyShaper.SPLIT_MIN_TOTAL) {
      return [t];
    }
    const marks: string = '。！？!?…\n';
    const raw: string[] = [];
    let cur: string = '';
    for (let i: number = 0; i < t.length; i++) {
      const ch: string = t.charAt(i);
      cur += ch;
      if (marks.indexOf(ch) >= 0) {
        raw.push(cur);
        cur = '';
      }
    }
    if (cur.trim().length > 0) {
      raw.push(cur);
    }
    // 太短的碎句并到上一条，别让「嗯。」单独成一条
    const merged: string[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const s: string = raw[i].trim();
      if (s.length === 0) {
        continue;
      }
      if (merged.length > 0 && (s.length < ReplyShaper.PART_MIN
        || merged[merged.length - 1].length < ReplyShaper.PART_MIN)) {
        merged[merged.length - 1] = merged[merged.length - 1] + s;
      } else {
        merged.push(s);
      }
    }
    if (merged.length <= 1) {
      return [t];
    }
    // 超过上限，把尾巴全部并进最后一条
    if (merged.length > ReplyShaper.PART_MAX) {
      const head: string[] = merged.slice(0, ReplyShaper.PART_MAX - 1);
      head.push(merged.slice(ReplyShaper.PART_MAX - 1).join(''));
      return head;
    }
    return merged;
  }

  static shape(text: string, recentOpeners: string[]): string {
    let s: string = ReplyShaper.unwrapArray(text);
    // 星火这类模型爱写（皱了皱眉）（停顿一下）这种舞台提示，真人聊天不发这个
    const stripped: string = ReplyShaper.stripStage(s);
    if (stripped.trim().length > 0) {
      s = stripped;
    }
    s = ReplyShaper.normalizePunct(s);
    s = ReplyShaper.dropEchoOpener(s, recentOpeners);
    s = s.trim();
    return s;
  }

  /** 括号里的舞台提示最长这么多字；再长、或者带字母数字的，当成正经内容留着 */
  private static readonly STAGE_MAX: number = 14;

  /**
   * 认得出来的「动作/语气」词。只删含这些词的括号，
   * 否则（微信）（淘宝）这种正常括号也会被误杀——宁可漏抓，不可错杀。
   */
  private static readonly STAGE_WORDS: string[] = [
    '笑', '皱', '眉', '叹', '停顿', '沉默', '低头', '抬头', '点头', '摇头',
    '愣', '怔', '咬', '捏', '咳', '语气', '声音', '轻声', '小声', '大声',
    '缓缓', '突然', '无奈', '耸肩', '摊', '眨', '摸', '捂', '哼', '哽',
    '脸红', '发呆', '歪头', '抿', '咧', '嘀咕', '嘟囔', '顿了顿', '顿了顿'
  ];

  private static looksLikeStage(inner: string): boolean {
    if (inner.length === 0 || inner.length > ReplyShaper.STAGE_MAX) {
      return false;
    }
    if (/[0-9A-Za-z]/.test(inner)) {
      return false;
    }
    for (let i: number = 0; i < ReplyShaper.STAGE_WORDS.length; i++) {
      if (inner.indexOf(ReplyShaper.STAGE_WORDS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 去掉（皱了皱眉）（停顿一下）(sigh) 这类动作/语气旁白。
   */
  static stripStage(text: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const ch: string = text.charAt(i);
      const isFull: boolean = ch === '（';
      const isHalf: boolean = ch === '(';
      if (isFull || isHalf) {
        const closer: string = isFull ? '）' : ')';
        const close: number = text.indexOf(closer, i + 1);
        if (close > i) {
          const inner: string = text.substring(i + 1, close);
          if (ReplyShaper.looksLikeStage(inner)) {
            i = close + 1;
            continue;
          }
        }
      }
      out += ch;
      i++;
    }
    return out;
  }

  /** 从一条消息里取出「开头一句」，用于和下一轮比对 */
  static openerOf(text: string): string {
    const t: string = text.trim();
    if (t.length === 0) {
      return '';
    }
    let end: number = t.length;
    const marks: string = '。！？!?…\n';
    for (let i: number = 0; i < t.length; i++) {
      if (marks.indexOf(t.charAt(i)) >= 0) {
        end = i + 1;
        break;
      }
    }
    const head: string = t.substring(0, end).trim();
    return head.length > ReplyShaper.OPENER_MAX ? '' : head;
  }

  /** 模型偶尔把回复写成 ["…","…"] 或 ['…','…']，拆回正常句子 */
  private static unwrapArray(text: string): string {
    const t: string = text.trim();
    if (t.length < 4 || t.charAt(0) !== '[' || t.charAt(t.length - 1) !== ']') {
      return text;
    }
    try {
      const parsed: string[] = JSON.parse(t) as string[];
      if (Array.isArray(parsed) && parsed.length > 0) {
        let joined: string = '';
        for (let i: number = 0; i < parsed.length; i++) {
          const v: string = parsed[i];
          if (typeof v === 'string') {
            joined += v;
          }
        }
        if (joined.length > 0) {
          return joined;
        }
      }
    } catch (e) {
      // 单引号写的伪 JSON，退一步手动拆
      const inner: string = t.substring(1, t.length - 1);
      if (inner.indexOf('",') >= 0 || inner.indexOf("',") >= 0) {
        const rough: string = inner.replace(/["'\s,]/g, '');
        if (rough.length > 0) {
          return rough;
        }
      }
    }
    return text;
  }

  /** 标点按简体中文习惯：引号统一成 “”，顿号只连词不接分句 */
  private static normalizePunct(text: string): string {
    let s: string = text;
    s = s.replace(/「/g, '“').replace(/」/g, '”');
    s = s.replace(/『/g, '“').replace(/』/g, '”');
    // 顿号后面跟分句连接词/代词，说明这里该断句了
    s = s.replace(/、([也就但所或而且然我你他她它这那])/g, '，$1');
    // 连续标点收敛
    s = s.replace(/，{2,}/g, '，');
    s = s.replace(/。{2,}/g, '。');
    s = s.replace(/[ \t]{2,}/g, ' ');
    return s;
  }

  /**
   * 回声橡皮擦：这条的开头如果和最近她说过的开头一字不差，就把这个开头删掉。
   * 删完剩得太少就不删了——宁可留着重复，也不要把话删没。
   */
  private static dropEchoOpener(text: string, recentOpeners: string[]): string {
    const head: string = ReplyShaper.openerOf(text);
    if (head.length < 3) {
      return text;
    }
    let echoed: boolean = false;
    for (let i: number = 0; i < recentOpeners.length; i++) {
      if (recentOpeners[i] === head) {
        echoed = true;
        break;
      }
    }
    if (!echoed) {
      return text;
    }
    const rest: string = text.substring(text.indexOf(head) + head.length).trim();
    // 剩下的至少还得是一句话，否则保留原文
    if (rest.length < 6) {
      return text;
    }
    return rest;
  }
}

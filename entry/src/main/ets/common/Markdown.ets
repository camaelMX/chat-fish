/**
 * 极简 Markdown 渲染。
 * 不用第三方库：模型偶尔会吐出 **加粗**、- 列表、### 标题，
 * 直接丢给 ArkUI 的 Text 会把这些符号原样显示出来（之前就是这个问题）。
 * 这里只认聊天里会出现的几种：加粗、行内代码、标题、无序/有序列表、引用、代码块。
 */

/** 一段同样式文字 */
export class Seg {
  text: string;
  /** n=普通 b=加粗 c=行内代码 */
  style: string;

  constructor(text: string, style: string) {
    this.text = text;
    this.style = style;
  }
}

/** 一行 */
export class Line {
  /** p=正文 h=标题 b=无序 o=有序 q=引用 e=代码 k=空行 */
  kind: string;
  /** 列表符号，正文为空串 */
  marker: string;
  segs: Seg[];

  constructor(kind: string, marker: string, segs: Seg[]) {
    this.kind = kind;
    this.marker = marker;
    this.segs = segs;
  }
}

/** 剥掉标记只留文字，给流式输出用（还没稳定，不做富文本） */
export function stripMarkers(src: string): string {
  let s: string = src;
  s = s.replace(/\*\*([^*]+)\*\*/g, '$1');
  s = s.replace(/__([^_]+)__/g, '$1');
  s = s.replace(/`([^`]+)`/g, '$1');
  s = s.replace(/^#{1,6}\s+/gm, '');
  s = s.replace(/^```.*$/gm, '');
  // 流式期间还没收完的标记：末尾悬着的 ** ` # 直接藏掉，
  // 否则会先露出“**很”再突然变成“**很重要**”，一闪一闪很难看
  s = s.replace(/(\*\*|__|`|#{1,6}\s?)+$/, '');
  // 剩下的落单标记（只开没闭）也一并清掉
  s = s.replace(/\*\*/g, '');
  s = s.replace(/__/g, '');
  s = s.replace(/`/g, '');
  // 行首还没写完的列表符号也先不显示
  s = s.replace(/(^|\n)\s*[-*+]\s*$/, '$1');
  return s;
}

/** 行内：**加粗**、`代码`、[文字](链接) 只留文字 */
function parseInline(s: string): Seg[] {
  const out: Seg[] = [];
  let buf: string = '';
  let i: number = 0;
  const push = (t: string, st: string): void => {
    if (t.length > 0) {
      out.push(new Seg(t, st));
    }
  };
  while (i < s.length) {
    const ch: string = s.charAt(i);
    // **加粗**
    if (ch === '*' && i + 1 < s.length && s.charAt(i + 1) === '*') {
      const end: number = s.indexOf('**', i + 2);
      if (end > i + 2) {
        push(buf, 'n');
        buf = '';
        push(s.substring(i + 2, end), 'b');
        i = end + 2;
        continue;
      }
    }
    // `代码`
    if (ch === '`') {
      const end: number = s.indexOf('`', i + 1);
      if (end > i + 1) {
        push(buf, 'n');
        buf = '';
        push(s.substring(i + 1, end), 'c');
        i = end + 1;
        continue;
      }
    }
    // *斜体* 当普通文字，只去掉星号
    if (ch === '*' && (i + 1 >= s.length || s.charAt(i + 1) !== '*')) {
      const end: number = s.indexOf('*', i + 1);
      if (end > i + 1) {
        push(buf, 'n');
        buf = '';
        push(s.substring(i + 1, end), 'n');
        i = end + 1;
        continue;
      }
    }
    // [文字](链接) 只留文字
    if (ch === '[') {
      const close: number = s.indexOf(']', i + 1);
      if (close > i + 1 && close + 1 < s.length && s.charAt(close + 1) === '(') {
        const paren: number = s.indexOf(')', close + 2);
        if (paren > close) {
          push(buf, 'n');
          buf = '';
          push(s.substring(i + 1, close), 'n');
          i = paren + 1;
          continue;
        }
      }
    }
    buf += ch;
    i += 1;
  }
  push(buf, 'n');
  return out;
}

/** 把整段回答切成行 */
export function parseMarkdown(src: string): Line[] {
  const out: Line[] = [];
  const raw: string[] = src.replace(/\r\n/g, '\n').split('\n');
  let inCode: boolean = false;
  for (let i: number = 0; i < raw.length; i++) {
    const line: string = raw[i];
    const trimmed: string = line.trim();

    // 代码围栏
    if (trimmed.startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      out.push(new Line('e', '', [new Seg(line, 'c')]));
      continue;
    }
    if (trimmed.length === 0) {
      out.push(new Line('k', '', []));
      continue;
    }
    // 分隔线
    if (/^([-*_])\1{2,}$/.test(trimmed)) {
      out.push(new Line('k', '', []));
      continue;
    }
    // 标题
    const head: RegExpMatchArray | null = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (head !== null) {
      out.push(new Line('h', '', parseInline(head[2])));
      continue;
    }
    // 引用
    const quote: RegExpMatchArray | null = trimmed.match(/^>\s?(.*)$/);
    if (quote !== null) {
      out.push(new Line('q', '', parseInline(quote[1])));
      continue;
    }
    // 无序列表
    const bullet: RegExpMatchArray | null = trimmed.match(/^[-*+]\s+(.*)$/);
    if (bullet !== null) {
      out.push(new Line('b', '·', parseInline(bullet[1])));
      continue;
    }
    // 有序列表
    const ordered: RegExpMatchArray | null = trimmed.match(/^(\d{1,2})[.)]\s+(.*)$/);
    if (ordered !== null) {
      out.push(new Line('o', ordered[1] + '.', parseInline(ordered[2])));
      continue;
    }
    out.push(new Line('p', '', parseInline(trimmed)));
  }
  // 去掉末尾空行
  while (out.length > 0 && out[out.length - 1].kind === 'k') {
    out.pop();
  }
  return out;
}

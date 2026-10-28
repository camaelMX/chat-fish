import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 她的声音 + 听懂你：两个模型都在局域网那台 3050 电脑上。
 * PC 侧约定：
 *   POST /tts   { "text": "...", "voice": "sweet | queen" }  →  audio/wav（GPT-SoVITS）
 *   POST /asr   body = wav 音频字节流（16k/mono/16bit）       →  { "text": "..." }（FunASR）
 *   GET  /health                                             →  200 即在线
 * TTS 结果按「文本+音色」缓存在 filesDir/voice/，同一句第二次点不再等 GPU。
 */
export class VoiceService {
  private static cacheDir: string = '';
  /** 规范化后的电脑地址（http://192.168.x.x:9880），页面设置里同步进来 */
  static hostValue: string = '';
  /**
   * 共享密钥：隧道把 9880 暴露到公网后，/tts 和 /asr 必须带这个 header。
   * 必须和电脑侧 D:\voice-server\config.json 的 token 完全一致；两边都留空则不校验。
   */
  static tokenValue: string = 'dsv-3f9a71c4e28b5d06';

  static attach(filesDir: string): void {
    VoiceService.cacheDir = filesDir + '/voice';
  }

  /** 用户随手填的地址规范化：补 http://、去尾斜杠 */
  static normalizeHost(raw: string): string {
    let h: string = raw.trim();
    if (h.length === 0) {
      return '';
    }
    if (!h.startsWith('http://') && !h.startsWith('https://')) {
      h = 'http://' + h;
    }
    while (h.length > 0 && h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  /** 探活，返回空串表示在线，否则是能直接给人看的错误 */
  static async checkHealth(host: string): Promise<string> {
    if (host.length === 0) {
      return '还没填电脑地址';
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(host + '/health', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000,
        readTimeout: 5000
      });
      if (resp.responseCode === 200) {
        return '';
      }
      return '电脑回了状态码 ' + resp.responseCode;
    } catch (e) {
      return '连不上，检查电脑服务开没开、地址对不对';
    } finally {
      req.destroy();
    }
  }

  /**
   * 中文按句切：。！？!?；;\n 都算断点；小数点（数字夹着的 .）不算。
   * 用于按句流式合成 —— 第一句合成完就开播，播的时候后台合下一句。
   */
  static splitSentences(text: string): string[] {
    const out: string[] = [];
    let cur: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      cur += ch;
      const isBreak: boolean = '。！？!?；;\n'.indexOf(ch) >= 0;
      const isDot: boolean = ch === '.' || ch === '…';
      if (isBreak) {
        out.push(cur);
        cur = '';
      } else if (isDot) {
        // 数字夹着的小数点不切；连续省略号当断句
        const prev: string = i > 0 ? text.charAt(i - 1) : '';
        const next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
        const decimal: boolean = ch === '.' && prev >= '0' && prev <= '9' && next >= '0' && next <= '9';
        if (!decimal) {
          out.push(cur);
          cur = '';
        }
      }
    }
    if (cur.trim().length > 0) {
      out.push(cur);
    }
    // 太碎的合并进前一句，避免一个「嗯」就请求一次 GPU
    const merged: string[] = [];
    for (let i: number = 0; i < out.length; i++) {
      const s: string = out[i];
      if (merged.length > 0 && (s.trim().length < 2 || merged[merged.length - 1].trim().length < 2)) {
        merged[merged.length - 1] = merged[merged.length - 1] + s;
      } else {
        merged.push(s);
      }
    }
    return merged;
  }

  /**
   * 只剥 emoji 和变体选择符，标点语气词都留着。
   * 用在文字气泡上：提示词说了别用 emoji，模型未必听，代码兜一层底。
   */
  static stripEmoji(text: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const low: number = text.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          i += 2;   // 代理对：😄 😅 🥰 这些全在这一区
          continue;
        }
      }
      const drop: boolean =
        (code >= 0x2600 && code <= 0x27BF)    // ☺ ✌ ❤ ✅ 这类 BMP 内的符号
        || (code >= 0x2B00 && code <= 0x2BFF) // ⭐ ⬆ 等
        || (code >= 0xFE00 && code <= 0xFE0F) // 变体选择符
        || code === 0x200D;                   // ZWJ
      if (!drop) {
        out += text.charAt(i);
      }
      i += 1;
    }
    return out.replace(/[ \t]{2,}/g, ' ').replace(/\s+\n/g, '\n').trim();
  }

  /**
   * 念之前清稿：emoji / 各类符号 / 零宽字符全部剥掉。
   * TTS 引擎不认识 emoji，会念成「比比」的怪声；文字气泡不受影响，只是不念。
   */
  static stripForTts(text: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        // 代理对（emoji 主力区 U+1F300-1FAFF、U+1F900 区等都在这里）
        i += 2;
        continue;
      }
      const isNoise: boolean =
        (code >= 0x2190 && code <= 0x2BFF)   // 箭头/符号/杂项图形、dingbats
        || (code >= 0xFE00 && code <= 0xFE0F) // 变体选择符
        || (code >= 0x200D && code <= 0x200F) // ZWJ / 不可见字符
        || (code >= 0x2028 && code <= 0x202F)
        || code === 0xFF0F || code === 0xFF5C  // ／ ｜
        || code === 0x00A9 || code === 0x00AE || code === 0x2122; // © ® ™
      if (!isNoise && code >= 0x20) {
        out += text.charAt(i);
      }
      i += 1;
    }
    // 常见标记符号也剥掉，防止被念出来
    out = out.replace(/[\*#\`~|\[\]{}<>_]+/g, '');
    return out.replace(/\s{2,}/g, ' ').trim();
  }

  /**
   * 合成一句话到 wav 文件（带缓存），返回文件绝对路径。
   * 抛错时消息已可直接给人看。
   */
  static async synthToFile(text: string, voice: string): Promise<string> {
    const clean: string = VoiceService.stripForTts(text);
    if (clean.length === 0) {
      throw new Error('没有要念的内容');
    }
    if (VoiceService.cacheDir.length === 0) {
      throw new Error('语音服务还没初始化');
    }
    if (VoiceService.hostValue.length === 0) {
      throw new Error('还没填电脑地址，去设置里填一下');
    }
    const path: string = VoiceService.cacheDir + '/t_' +
      VoiceService.hash(clean + '|' + voice).toString(36) + '.wav';
    if (fileIo.accessSync(path)) {
      return path;
    }
    const req = http.createHttp();
    try {
      const body: Record<string, string> = {
        'text': clean,
        'voice': voice
      };
      const resp = await req.request(VoiceService.hostValue + '/tts', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'X-Voice-Token': VoiceService.tokenValue
        } as Record<string, string>,
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 60000
      });
      if (resp.responseCode === 401) {
        throw new Error('密钥不对：App 的 token 和电脑 config.json 里的对不上');
      }
      if (resp.responseCode !== 200) {
        throw new Error('电脑那边合成失败（状态码 ' + resp.responseCode + '）');
      }
      const wav = resp.result as ArrayBuffer;
      if (wav.byteLength < 100) {
        throw new Error('电脑回来的音频是空的');
      }
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, wav);
      } finally {
        fileIo.closeSync(file);
      }
      return path;
    } catch (e) {
      const err: Error = e as Error;
      if (err.message.indexOf('电脑') >= 0) {
        throw err;
      }
      throw new Error('连不上电脑，她的声音服务好像没开');
    } finally {
      req.destroy();
    }
  }

  /**
   * 把一段 wav 录音发到电脑转成文字（ASR 在电脑上）。
   * 返回空串表示没听清；抛错时消息可直接给人看。
   */
  static async transcribeFile(wavPath: string): Promise<string> {
    if (VoiceService.hostValue.length === 0) {
      throw new Error('还没填电脑地址，去设置里填一下');
    }
    const file = fileIo.openSync(wavPath, fileIo.OpenMode.READ_ONLY);
    let data: ArrayBuffer;
    try {
      const len: number = fileIo.statSync(file.fd).size;
      data = new ArrayBuffer(len);
      fileIo.readSync(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(VoiceService.hostValue + '/asr', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/octet-stream',
          'X-Voice-Token': VoiceService.tokenValue
        } as Record<string, string>,
        extraData: data,
        expectDataType: http.HttpDataType.OBJECT,
        connectTimeout: 8000,
        readTimeout: 60000
      });
      if (resp.responseCode === 401) {
        throw new Error('密钥不对：App 的 token 和电脑 config.json 里的对不上');
      }
      if (resp.responseCode !== 200) {
        throw new Error('电脑那边转写失败（状态码 ' + resp.responseCode + '）');
      }
      const r = resp.result as Record<string, string>;
      if (r !== null && r !== undefined && typeof r.text === 'string') {
        return r.text as string;
      }
      return '';
    } catch (e) {
      const err: Error = e as Error;
      if (err.message.indexOf('电脑') >= 0) {
        throw err;
      }
      throw new Error('连不上电脑，听你说话的服务好像没开');
    } finally {
      req.destroy();
    }
  }

  /** djb2，够用来生成缓存文件名 */
  private static hash(s: string): number {
    let h: number = 5381;
    for (let i: number = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.charCodeAt(i)) & 0x7FFFFFFF;
    }
    return h;
  }
}

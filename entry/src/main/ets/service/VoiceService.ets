import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 她的声音 + 听懂你：两个模型都在家里那台电脑上。
 * 手机只跟 adapter 说话，但有两条路可以走：
 *
 *   在家  ── 局域网直连 ──▶ http://192.168.x.x:9880   （快，不绕公网）
 *   出门  ── 隧道 ───────▶ https://xxx.trycloudflare.com
 *
 * 选路靠 /ping 探活，不靠判断 Wi-Fi 名字（拿 SSID 要系统级权限，也不可靠）：
 * 局域网通就走局域网；不通就走隧道；单次请求失败还会当场换另一条重试。
 * 隧道地址会变：电脑把最新地址放在 /ping 里，App 在家连上时顺手记下来，
 * 出门直接用，不用每次手动填、也不用重新打包。
 *
 * PC 侧约定：
 *   GET  /ping                                       → 200 {"ok":true,"tunnel_url":"..."}（极轻量，不选路也能用旧版 /health）
 *   GET  /health                                     → 200 即在线
 *   POST /tts   { "text": "...", "voice": "sweet | queen" }  →  audio/wav（GPT-SoVITS）
 *   POST /asr   body = wav 音频字节流（16k/mono/16bit）       →  { "text": "..." }（FunASR）
 * TTS 结果按「文本+音色」缓存在 filesDir/voice/，同一句第二次点不再等 GPU。
 */

/** 选路缓存：成功 60 秒；两条都不通时 30 秒后重试（探活本身要几秒，别一直挂在后台） */
const ROUTE_TTL_MS: number = 60 * 1000;
const ROUTE_RETRY_MS: number = 30 * 1000;
/** 局域网探活要快：出门时不能让每句话都等它超时 */
const LAN_PROBE_MS: number = 1200;
/** 隧道要绕到 Cloudflare 边缘，偶尔冷启动很慢 */
const WAN_PROBE_MS: number = 6000;

interface ProbeResult {
  ok: boolean;
  status: number;
  tunnelUrl: string;
}

interface PingBody {
  ok?: boolean;
  tunnel_url?: string;
}

export class VoiceService {
  private static cacheDir: string = '';
  /** 兼容旧代码：主地址（有局域网地址就优先用它） */
  static hostValue: string = '';
  /** 家里：局域网直连地址，例如 http://192.168.1.5:9880 */
  static lanHostValue: string = '';
  /** 出门：隧道地址，例如 https://xxxx.trycloudflare.com */
  static wanHostValue: string = '';
  /** 是否允许从电脑 /ping 带回最新隧道地址（关掉就只用手填的） */
  static autoSyncWan: boolean = true;
  /** 当前选中的路：'lan' | 'wan' | ''（空 = 两条都没通） */
  static routeValue: string = '';
  static routeAt: number = 0;
  /** 最近一次从电脑带回的隧道地址，页面拿去落盘 */
  static syncedWanUrl: string = '';
  /** 合并并发探活，别让三句预热同时去敲 /ping */
  private static probing: Promise<string> | null = null;
  /**
   * 共享密钥：隧道把 9880 暴露到公网后，/tts 和 /asr 必须带这个 header。
   * 必须和电脑侧 D:\voice-server\config.json 的 token 完全一致；两边都留空则不校验。
   */
  /**
   * 语音服务口令（电脑端 config.json 的 token，请求头 X-Voice-Token）。
   * 源码里不留明文：由 Index.loadSettings() 从 preferences 或本地密钥文件注入，
   * 用户也能在「设置 → 她的声音 → 语音口令」里改，改完立即生效。
   */
  static tokenValue: string = '';

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

  /** 页面把两条地址同步进来。地址变了就作废选路缓存，立刻重新探 */
  static configure(lanRaw: string, wanRaw: string, autoSyncWan: boolean): void {
    const lan: string = VoiceService.normalizeHost(lanRaw);
    const wan: string = VoiceService.normalizeHost(wanRaw);
    const changed: boolean = lan !== VoiceService.lanHostValue
      || wan !== VoiceService.wanHostValue
      || autoSyncWan !== VoiceService.autoSyncWan;
    VoiceService.lanHostValue = lan;
    VoiceService.wanHostValue = wan;
    VoiceService.autoSyncWan = autoSyncWan;
    VoiceService.hostValue = lan.length > 0 ? lan : wan;
    if (changed) {
      VoiceService.forceReselect();
    }
  }

  /** 只更新外网地址（自动同步时用），不动已经选好的路 */
  static setWanHost(raw: string): void {
    VoiceService.wanHostValue = VoiceService.normalizeHost(raw);
    if (VoiceService.lanHostValue.length === 0) {
      VoiceService.hostValue = VoiceService.wanHostValue;
    }
  }

  /** 手动重选（设置页「重新检测」用） */
  static forceReselect(): void {
    VoiceService.routeValue = '';
    VoiceService.routeAt = 0;
  }

  /** 设置页已经把两条路各测过一遍，直接采用结果，别再重复探活 */
  static applyProbeResult(lanOk: boolean, wanOk: boolean): void {
    VoiceService.routeValue = lanOk ? 'lan' : (wanOk ? 'wan' : '');
    VoiceService.routeAt = Date.now();
  }

  static routeLabel(): string {
    if (VoiceService.routeValue === 'lan') {
      return '家里直连（局域网）';
    }
    if (VoiceService.routeValue === 'wan') {
      return '外网隧道';
    }
    return '语音服务没连上';
  }

  static routeShort(): string {
    if (VoiceService.routeValue === 'lan') {
      return '家里';
    }
    if (VoiceService.routeValue === 'wan') {
      return '隧道';
    }
    return '没连上';
  }

  private static routeHost(route: string): string {
    if (route === 'lan') {
      return VoiceService.lanHostValue;
    }
    if (route === 'wan') {
      return VoiceService.wanHostValue;
    }
    return '';
  }

  /**
   * 当前该用哪个地址。
   * 成功结果缓存 60 秒；出门时最多 60 秒自动跟上，期间请求失败会立刻换路重试，
   * 所以用户不会感觉到这 60 秒。两条都不通时 10 秒后重新探。
   */
  static async activeHost(): Promise<string> {
    if (VoiceService.lanHostValue.length === 0 && VoiceService.wanHostValue.length === 0) {
      return '';
    }
    const now: number = Date.now();
    const ttl: number = VoiceService.routeValue.length > 0 ? ROUTE_TTL_MS : ROUTE_RETRY_MS;
    if (VoiceService.routeAt > 0 && now - VoiceService.routeAt < ttl) {
      return VoiceService.routeHost(VoiceService.routeValue);
    }
    return await VoiceService.selectRoute();
  }

  /** 本次请求要尝试的地址：先当前选路，失败再试另一条 */
  static async hostCandidates(): Promise<string[]> {
    const primary: string = await VoiceService.activeHost();
    const out: string[] = [];
    if (primary.length === 0) {
      // 刚才两条 /ping 都没通，就别再逐个发真实请求干等超时了
      return out;
    }
    out.push(primary);
    const all: string[] = [VoiceService.lanHostValue, VoiceService.wanHostValue];
    for (let i: number = 0; i < all.length; i++) {
      const h: string = all[i];
      if (h.length > 0 && out.indexOf(h) < 0) {
        out.push(h);
      }
    }
    return out;
  }

  /** 某条路请求失败：作废选路缓存，下次（以及本次重试）走另一条 */
  static noteFailure(host: string): void {
    if (host === VoiceService.routeHost(VoiceService.routeValue) || VoiceService.routeValue.length === 0) {
      VoiceService.forceReselect();
    }
  }

  /** 备用路请求成功：把选路结果记下来，别让后面每句话都重新探 */
  static noteSuccess(host: string): void {
    if (host === VoiceService.lanHostValue) {
      VoiceService.routeValue = 'lan';
    } else if (host === VoiceService.wanHostValue) {
      VoiceService.routeValue = 'wan';
    }
    VoiceService.routeAt = Date.now();
  }

  private static async selectRoute(): Promise<string> {
    if (VoiceService.probing !== null) {
      return VoiceService.probing;
    }
    const task: Promise<string> = VoiceService.probeBoth();
    VoiceService.probing = task;
    const clear = (): void => {
      VoiceService.probing = null;
    };
    task.then(clear, clear);
    return task;
  }

  private static async probeBoth(): Promise<string> {
    let chosen: string = '';
    const lan: string = VoiceService.lanHostValue;
    const wan: string = VoiceService.wanHostValue;
    if (lan.length > 0) {
      const r: ProbeResult = await VoiceService.probe(lan, LAN_PROBE_MS);
      if (r.ok) {
        chosen = 'lan';
        VoiceService.absorbTunnelUrl(r.tunnelUrl);
      }
    }
    if (chosen.length === 0 && wan.length > 0) {
      const r2: ProbeResult = await VoiceService.probe(wan, WAN_PROBE_MS);
      if (r2.ok) {
        chosen = 'wan';
      }
    }
    VoiceService.routeValue = chosen;
    VoiceService.routeAt = Date.now();
    return VoiceService.routeHost(chosen);
  }

  /**
   * 探活优先打 /ping：adapter 里这个接口不查 GPT-SoVITS，局域网几十毫秒就回。
   * 只有 /ping 是 404（旧版 adapter 没这个接口）时才退回 /health 确认一次；
   * 隧道地址过期时 Cloudflare 也会回 404，这次回退正好把它挡在外面。
   */
  private static async probe(host: string, timeoutMs: number): Promise<ProbeResult> {
    const ping: ProbeResult = await VoiceService.fetchPing(host + '/ping', timeoutMs);
    if (ping.ok || ping.status !== 404) {
      return ping;
    }
    return await VoiceService.fetchPing(host + '/health', timeoutMs);
  }

  private static async fetchPing(url: string, timeoutMs: number): Promise<ProbeResult> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      if (resp.responseCode !== 200) {
        const bad: ProbeResult = { ok: false, status: resp.responseCode, tunnelUrl: '' };
        return bad;
      }
      let tunnelUrl: string = '';
      try {
        const body: PingBody = JSON.parse(resp.result as string) as PingBody;
        if (body.tunnel_url !== undefined && typeof body.tunnel_url === 'string') {
          tunnelUrl = body.tunnel_url.trim();
        }
      } catch (e) {
      }
      const good: ProbeResult = { ok: true, status: 200, tunnelUrl: tunnelUrl };
      return good;
    } catch (e) {
      const bad: ProbeResult = { ok: false, status: 0, tunnelUrl: '' };
      return bad;
    } finally {
      req.destroy();
    }
  }

  /** 电脑把当前隧道地址放在 /ping 里；只在「允许自动同步」时接管外网地址 */
  private static absorbTunnelUrl(url: string): void {
    if (url.length === 0 || !VoiceService.autoSyncWan) {
      return;
    }
    const clean: string = VoiceService.normalizeHost(url);
    if (!clean.startsWith('https://')) {
      return;
    }
    VoiceService.syncedWanUrl = clean;
    VoiceService.setWanHost(clean);
  }

  /** 设置页手动测试某一条路，返回空串表示在线，否则是能直接给人看的错误 */
  static async checkHealth(host: string): Promise<string> {
    if (host.length === 0) {
      return '还没填地址';
    }
    const r: ProbeResult = await VoiceService.probe(host, 5000);
    if (r.ok) {
      VoiceService.absorbTunnelUrl(r.tunnelUrl);
      return '';
    }
    if (r.status === 0) {
      return '连不上，检查电脑服务开没开、地址对不对';
    }
    return '电脑回了状态码 ' + r.status;
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
  /**
   * 同一句话正在合成时，别发第二次请求。
   * 后台预热和用户点播放可能同时要同一句，并发写同一个文件会写坏。
   */
  private static inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  static synthToFile(text: string, voice: string): Promise<string> {
    const clean: string = VoiceService.stripForTts(text);
    if (clean.length === 0) {
      return Promise.reject(new Error('没有要念的内容'));
    }
    if (VoiceService.cacheDir.length === 0) {
      return Promise.reject(new Error('语音服务还没初始化'));
    }
    if (VoiceService.lanHostValue.length === 0 && VoiceService.wanHostValue.length === 0) {
      return Promise.reject(new Error('还没填电脑地址，去设置里填一下'));
    }
    const path: string = VoiceService.cacheDir + '/t_' +
      VoiceService.hash(clean + '|' + voice).toString(36) + '.wav';
    if (fileIo.accessSync(path)) {
      return Promise.resolve(path);
    }
    const running: Promise<string> | undefined = VoiceService.inflight.get(path);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = VoiceService.synthInner(path, clean, voice);
    VoiceService.inflight.set(path, task);
    const clear = (): void => {
      VoiceService.inflight.delete(path);
    };
    task.then(clear, clear);
    return task;
  }

  /** 先走选好的路，连不上就当场换另一条重试一次 */
  private static async synthInner(path: string, clean: string, voice: string): Promise<string> {
    const hosts: string[] = await VoiceService.hostCandidates();
    if (hosts.length === 0) {
      throw new Error('连不上电脑，她的声音服务好像没开');
    }
    let last: Error = new Error('连不上电脑，她的声音服务好像没开');
    for (let i: number = 0; i < hosts.length; i++) {
      try {
        const result: string = await VoiceService.synthOnce(hosts[i], path, clean, voice);
        VoiceService.noteSuccess(hosts[i]);
        return result;
      } catch (e) {
        const err: Error = e as Error;
        VoiceService.noteFailure(hosts[i]);
        last = err;
        if (err.message.indexOf('密钥不对') >= 0) {
          break; // 换条路也一样 401，别白等
        }
      }
    }
    throw last;
  }

  /** 真正去电脑要音频，写进 path */
  private static async synthOnce(host: string, path: string, clean: string, voice: string): Promise<string> {
    const req = http.createHttp();
    try {
      const body: Record<string, string> = {
        'text': clean,
        'voice': voice
      };
      const resp = await req.request(host + '/tts', {
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
      if (err.message.indexOf('密钥不对') >= 0 || err.message.indexOf('电脑') >= 0) {
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
    if (VoiceService.lanHostValue.length === 0 && VoiceService.wanHostValue.length === 0) {
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
    const hosts: string[] = await VoiceService.hostCandidates();
    if (hosts.length === 0) {
      throw new Error('连不上电脑，听你说话的服务好像没开');
    }
    let last: Error = new Error('连不上电脑，听你说话的服务好像没开');
    for (let i: number = 0; i < hosts.length; i++) {
      try {
        const text: string = await VoiceService.transcribeOnce(hosts[i], data);
        VoiceService.noteSuccess(hosts[i]);
        return text;
      } catch (e) {
        const err: Error = e as Error;
        VoiceService.noteFailure(hosts[i]);
        last = err;
        if (err.message.indexOf('密钥不对') >= 0) {
          break;
        }
      }
    }
    throw last;
  }

  private static async transcribeOnce(host: string, data: ArrayBuffer): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(host + '/asr', {
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
      if (err.message.indexOf('密钥不对') >= 0 || err.message.indexOf('电脑') >= 0) {
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

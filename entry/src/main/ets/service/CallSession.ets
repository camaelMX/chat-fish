import { VoiceService } from './VoiceService';
import { VoiceInputService, VoiceInputEvents, VoiceClip } from './VoiceInputService';
import { PlayerService } from './PlayerService';
import { DeepSeekService, ChatMessage } from './DeepSeekService';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 语音通话状态机：像打电话一样连续说话，不用按住、不用点气泡。
 *
 *   开麦听 ──(静音自动收尾)──▶ 电脑 ASR ──▶ DeepSeek ──▶ 按句 TTS 播放 ──▶ 再开麦听 …
 *
 * 关键点：
 * - 用能量 VAD 判断「说完了」，纯静音不发请求，也不打扰电脑；
 * - 自动插话：录音/播放都标成 VoIP 通话流让系统开 3A（回声消除），
 *   她说话时旁边一直开着麦，检测到你连续出声就立刻停播、把这句接回 ASR；
 *   设备不支持 AEC 时自动降级，保留「插话」按钮；
 * - 每轮结束通过 onTurn 把对话交给页面写进时间线，挂断后能回看；
 * - 全程复用已有的 VoiceService（在家/隧道自动选路）、记忆和播放器。
 */
export interface CallConfig {
  apiKey: string;
  model: string;
  voiceStyle: string;
  /** 复用页面的记忆 / system prompt 组装，通话内容也进上下文 */
  makeRequest: (userText: string) => ChatMessage[];
}

export interface CallCallbacks {
  /** 'listening' | 'thinking' | 'speaking' | 'ended' */
  onState: (state: string) => void;
  /** 通话页上的字幕（最近一句） */
  onLine: (text: string) => void;
  /** 一轮完成：页面把这两句写进时间线 */
  onTurn: (userText: string, reply: string) => void;
  onError: (msg: string) => void;
  onTick: (seconds: number) => void;
}

export class CallSession {
  private input: VoiceInputService;
  private player: PlayerService;
  private ds: DeepSeekService;
  private cfg: CallConfig | null = null;
  private cb: CallCallbacks | null = null;
  private running: boolean = false;
  /** 用户点了「打断」 */
  private interrupted: boolean = false;
  /** 每轮循环一个序号，挂断后旧循环回来立刻作废 */
  private seq: number = 0;
  private startedAt: number = 0;
  private timer: number = -1;
  /** 这台设备支持系统回声消除，才敢在她说话时开麦 */
  private bargeEnabled: boolean = false;
  /** 本轮播放期间检测到你插话 */
  private bargeHit: boolean = false;
  /** 插话后继续录完的那段音频，下一轮 loop 优先处理，不丢字 */
  private pendingClip: VoiceClip | null = null;
  /** 播放期间监听的收尾（正常关掉返回 null，插话则返回那段 wav） */
  private bargeDone: Promise<VoiceClip | null> | null = null;
  /** 连续开麦失败次数：息屏切换时系统会重配音频通路，偶发一次能自愈 */
  private micFailStreak: number = 0;

  constructor(input: VoiceInputService, player: PlayerService, ds: DeepSeekService) {
    this.input = input;
    this.player = player;
    this.ds = ds;
  }

  isRunning(): boolean {
    return this.running;
  }

  async start(cfg: CallConfig, cb: CallCallbacks): Promise<void> {
    if (this.running) {
      return;
    }
    this.cfg = cfg;
    this.cb = cb;
    this.running = true;
    this.interrupted = false;
    this.bargeHit = false;
    this.pendingClip = null;
    this.micFailStreak = 0;
    this.bargeEnabled = VoiceInputService.aecSupported();
    this.startedAt = Date.now();
    this.seq += 1;
    this.timer = setInterval(() => {
      const callback: CallCallbacks | null = this.cb;
      if (callback !== null) {
        callback.onTick(Math.floor((Date.now() - this.startedAt) / 1000));
      }
    }, 1000);
    await this.loop(this.seq);
  }

  /** 挂断：停播、停录、停计时，旧循环立刻作废 */
  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.seq += 1;
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.player.stop();
    try {
      await this.input.cancel();
    } catch (e) {
    }
    this.emitState('ended');
  }

  /** 她在说 / 在想时点一下：停播，马上回到听 */
  interrupt(): void {
    if (!this.running) {
      return;
    }
    this.interrupted = true;
    this.player.stop();
  }

  private emitState(s: string): void {
    const callback: CallCallbacks | null = this.cb;
    if (callback !== null) {
      callback.onState(s);
    }
  }

  private emitError(msg: string): void {
    const callback: CallCallbacks | null = this.cb;
    if (callback !== null) {
      callback.onError(msg);
    }
  }

  private emitLine(text: string): void {
    const callback: CallCallbacks | null = this.cb;
    if (callback !== null) {
      callback.onLine(text);
    }
  }

  private async loop(seq: number): Promise<void> {
    while (this.running && seq === this.seq) {
      this.emitState('listening');
      // 上一轮被插话打断时，那段话已经录好了，直接送去转写，别让人重说一遍
      let clip: VoiceClip | null = this.pendingClip;
      this.pendingClip = null;
      if (clip === null) {
        clip = await this.recordOnce();
      }
      if (!this.running || seq !== this.seq) {
        this.dropClip(clip);
        break;
      }
      if (clip === null) {
        await this.wait(400); // 麦克风出错等一下再试，别空转
        continue;
      }
      await this.handleClip(clip, seq);
      // 时间线里存的是文字，录音文件不引用它；每轮用完就删，
      // 否则一小时通话能在手机上堆出上百 MB 的 wav
      this.dropClip(clip);
    }
    // 只有「本轮」异常掉出循环才收尾；挂断后旧循环回来时别误停新通话
    if (this.running && seq === this.seq) {
      this.running = false;
      this.emitState('ended');
    }
  }

  /** 处理一段录到的人声：转写 → 想 → 说 */
  private async handleClip(clip: VoiceClip, seq: number): Promise<void> {
    if (!clip.voiced || clip.durationMs < 500) {
      return; // 纯静音，不打扰电脑，继续听
    }
    let text: string = '';
    try {
      text = (await VoiceService.transcribeFile(clip.wavPath)).trim();
    } catch (e) {
      this.emitError('没听清：' + (e as Error).message);
      return;
    }
    if (text.length === 0) {
      return;
    }
    this.emitLine('你：' + text);
    this.emitState('thinking');

    const cfg: CallConfig | null = this.cfg;
    if (cfg === null) {
      return;
    }
    let reply: string = '';
    try {
      const req: ChatMessage[] = cfg.makeRequest(text);
      reply = await this.ds.chatOnce(cfg.apiKey, cfg.model, req, 0.8, 400, false);
    } catch (e) {
      this.emitError('她没接上：' + (e as Error).message);
      return;
    }
    reply = VoiceService.stripEmoji(reply.trim());
    if (reply.length === 0) {
      reply = '嗯，我在。';
    }
    this.emitLine('她：' + reply);
    const callback: CallCallbacks | null = this.cb;
    if (callback !== null) {
      callback.onTurn(text, reply);
    }
    if (!this.running || seq !== this.seq || this.interrupted) {
      this.interrupted = false;
      return;
    }
    await this.speak(reply, seq);
    this.interrupted = false;
  }

  private dropClip(clip: VoiceClip | null): void {
    if (clip === null) {
      return;
    }
    try {
      fileIo.unlinkSync(clip.wavPath);
    } catch (e) {
    }
  }

  private async speak(reply: string, seq: number): Promise<void> {
    const cfg: CallConfig | null = this.cfg;
    if (cfg === null) {
      return;
    }
    this.emitState('speaking');
    this.bargeHit = false;
    const sentences: string[] = VoiceService.splitSentences(reply)
      .filter((s: string): boolean => VoiceService.stripForTts(s).length > 0);

    // AEC 可用就整个播放阶段都开着麦；不可用时按钮仍是兜底，
    // 绝不硬开麦 —— 那样她自己的声音会被当成你插话，无限自我打断
    let listening: boolean = false;
    if (this.bargeEnabled) {
      listening = await this.startBargeListener(seq);
    }

    for (let i: number = 0; i < sentences.length; i++) {
      if (!this.running || seq !== this.seq || this.interrupted || this.bargeHit) {
        break;
      }
      try {
        const path: string = await VoiceService.synthToFile(sentences[i], cfg.voiceStyle);
        if (!this.running || seq !== this.seq || this.interrupted || this.bargeHit) {
          break;
        }
        await this.player.playFile(path, () => {
        }, true);
      } catch (e) {
        if (this.running && !this.interrupted && !this.bargeHit) {
          this.emitError('没声音：' + (e as Error).message);
        }
        break;
      }
    }
    await this.finishBargeListener(listening, seq);
  }

  /** 播放期间开一路监听；检测到你出声就停播，并原地转成 VAD 把这句录完 */
  private async startBargeListener(seq: number): Promise<boolean> {
    let settle: (clip: VoiceClip | null) => void = (_c: VoiceClip | null): void => {
    };
    this.bargeDone = new Promise<VoiceClip | null>((resolve: (c: VoiceClip | null) => void) => {
      settle = resolve;
    });
    const events: VoiceInputEvents = {
      onCancel: (): void => {
        settle(null);
      },
      onError: (): void => {
        settle(null);
      },
      onAutoStop: (): void => {
        this.input.release().then((clip: VoiceClip | null) => {
          settle(clip);
        });
      }
    };
    let ok: boolean = false;
    try {
      ok = await this.input.startBargeIn(events, () => {
        if (!this.running || seq !== this.seq) {
          return;
        }
        this.bargeHit = true;
        this.interrupted = true;
        this.player.stop();
        this.input.armVadFromBarge();
      });
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      settle(null);
    }
    return ok;
  }

  private async finishBargeListener(listening: boolean, seq: number): Promise<void> {
    if (!listening || this.bargeDone === null) {
      this.bargeDone = null;
      return;
    }
    if (this.bargeHit) {
      // 等你把这句说完（静音 900ms 自动收尾），下一轮 loop 直接拿去转写
      const clip: VoiceClip | null = await this.bargeDone;
      if (this.running && seq === this.seq && clip !== null) {
        this.pendingClip = clip;
      } else {
        this.dropClip(clip);
      }
    } else {
      // 没插话：把监听关掉，麦克风还给下一轮。
      // 若监听是被 60s 上限自动收尾的，会带回一个用不上的 wav，顺手删掉
      await this.input.cancel();
      const leftover: VoiceClip | null = await this.bargeDone;
      this.dropClip(leftover);
    }
    this.bargeDone = null;
  }

  /** 开一次麦，等 VAD 通知收尾，把 wav 交回来 */
  private async recordOnce(): Promise<VoiceClip | null> {
    return new Promise<VoiceClip | null>((resolve: (v: VoiceClip | null) => void) => {
      let settled: boolean = false;
      const done = (v: VoiceClip | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(v);
      };
      const events: VoiceInputEvents = {
        onCancel: (): void => {
          done(null);
        },
        onError: (msg: string): void => {
          // 息屏/亮屏切换时系统会重配音频通路，偶发一次「麦克风被占用」能自愈。
          // loop 400ms 后就会重试，连续失败 3 次才提示，别拿瞬态错误刷字幕。
          this.micFailStreak += 1;
          if (this.micFailStreak >= 3) {
            this.emitError(msg);
          }
          done(null);
        },
        onAutoStop: (): void => {
          this.input.release().then((clip: VoiceClip | null) => {
            done(clip);
          });
        }
      };
      this.input.startWithVad(events, 900, 15000, 20000).then((ok: boolean) => {
        if (ok) {
          this.micFailStreak = 0; // 开麦成功了，之前的瞬态失败一笔勾销
        } else {
          done(null);
        }
      });
    });
  }

  private async wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
  }
}

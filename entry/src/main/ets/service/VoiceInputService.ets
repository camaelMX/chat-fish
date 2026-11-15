import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';

/** 录音期间给界面的回调 */
export interface VoiceInputEvents {
  /** 上滑取消 / 会话被丢弃 */
  onCancel: () => void;
  /** 出错（没权限、麦克风起不来等），带一句能直接给人看的话 */
  onError: (msg: string) => void;
  /** 按满 60 秒被自动收尾，页面按正常松开处理 */
  onAutoStop: () => void;
}

/** 一次按住说话的产物：wav 文件 + 时长（转写由电脑上的 ASR 做，见 VoiceService） */
export interface VoiceClip {
  /** 录音文件的绝对路径 */
  wavPath: string;
  durationMs: number;
  /** 这一段里检测到过人声；免提通话里用来跳过纯静音 */
  voiced: boolean;
}

const SAMPLE_RATE: number = 16000;
const BYTES_PER_SEC: number = SAMPLE_RATE * 2;
/** 单条语音上限 60 秒，到点自动收尾 */
const MAX_MS: number = 60000;
/** 插话检测：连续这么久超过门限才算你在说话，避免一声咳嗽就停播 */
const BARGE_HOLD_MS: number = 260;
/** 插话门限：比 VAD 的 400 高一点，给 AEC 残留留余量 */
const BARGE_RMS: number = 620;

/** 16k/16bit 单声道 PCM 的能量，VAD 和插话检测共用 */
function rmsOf(bytes: Uint8Array): number {
  const samples: number = Math.floor(bytes.length / 2);
  let sum: number = 0;
  for (let i: number = 0; i < samples; i++) {
    let v: number = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
    if (v >= 32768) {
      v -= 65536;
    }
    sum += v * v;
  }
  return samples > 0 ? Math.sqrt(sum / samples) : 0;
}

/**
 * 按住说话：只负责把麦克风的声音录成 wav（16k / 单声道 / 16bit）。
 * 语音转文字、文字转语音都在电脑上，手机这条线只有录音和播放。
 */
export class VoiceInputService {
  private capturer: audio.AudioCapturer | null = null;
  /** 正在录音 */
  private running: boolean = false;
  /** 这一次作废（上滑取消） */
  private discard: boolean = false;
  private stopTimer: number = -1;
  private events: VoiceInputEvents | null = null;
  /** 本次录音攒下的全部 PCM，松开后一次性封装 wav */
  private pcmChunks: Uint8Array[] = [];
  private pcmTotal: number = 0;
  private filesDir: string = '';
  /**
   * 通话页做声波动画用的实时音量回调（只在免提 VAD 录音时触发）。
   * VAD 本来就要逐块算 RMS，顺手递出去，不额外读麦克风、不影响录音逻辑。
   */
  onLevel: ((rms: number) => void) | null = null;
  /** normal=按住说话 / vad=通话听 / barge=她说话时在旁边听你有没有插话 */
  private mode: string = 'normal';
  /** 本次录音是否真的用上了通话音源（系统 3A 才会生效） */
  private callSource: boolean = false;
  /** 播放期间检测到人声，只触发一次 */
  private onBargeIn: (() => void) | null = null;
  private bargeLoudMs: number = 0;

  // ---- 免提通话用的简单端点检测（VAD）----
  private vadOn: boolean = false;
  private vadFired: boolean = false;
  private vadStarted: boolean = false;
  private vadSilenceMs: number = 900;
  private vadMaxMs: number = 15000;
  private vadWaitMs: number = 20000;
  private vadSilenceAcc: number = 0;
  private vadElapsed: number = 0;
  /** 这一段录音里到底有没有人声，buildClip 时写进 VoiceClip */
  private lastClipVoiced: boolean = true;

  /** 页面启动时把沙箱目录告诉它 */
  attach(filesDir: string): void {
    this.filesDir = filesDir;
  }

  /**
   * 系统 3A（含回声消除）在这台设备/当前通路上是否可用。
   * 只有它为 true 才敢在她播放声音时开麦，否则会把她自己的声音当成你插话。
   */
  static aecSupported(): boolean {
    try {
      return audio.getAudioManager().getStreamManager()
        .isAcousticEchoCancelerSupported(audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
    } catch (e) {
      return false;
    }
  }

  /** 本次录音是否真的落在通话音源上（失败会回退普通麦克风） */
  usingCallSource(): boolean {
    return this.callSource;
  }

  /** 申请麦克风权限，返回是否已授权 */
  static async ensureMicPermission(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      if (result.authResults.length === 0) {
        return false;
      }
      for (const r of result.authResults) {
        if (r !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 轻触感反馈，失败就当没有 */
  static buzz(durationMs: number): void {
    try {
      vibrator.startVibration(
        { type: 'time', duration: durationMs },
        { usage: 'touch' },
        (err: BusinessError) => {
        }
      );
    } catch (e) {
      // 没有振动器就算了
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 按下：开麦录音。callMode=true 时走通话音源（启用系统 3A）。成功返回 true。 */
  async start(events: VoiceInputEvents, callMode: boolean = false): Promise<boolean> {
    if (this.running) {
      return false;
    }
    this.events = events;
    this.discard = false;
    this.pcmChunks = [];
    this.pcmTotal = 0;
    this.mode = 'normal';
    this.onBargeIn = null;
    this.bargeLoudMs = 0;
    const capOk = await this.startCapturer(callMode);
    if (!capOk) {
      events.onError('麦克风被占用了，关掉别的录音再试。');
      return false;
    }
    this.running = true;
    // 60 秒上限自动收尾，别让人按出一条超长语音
    if (this.stopTimer !== -1) {
      clearTimeout(this.stopTimer);
    }
    this.stopTimer = setTimeout(() => {
      this.stopTimer = -1;
      if (this.running) {
        VoiceInputService.buzz(60);
        if (this.events !== null) {
          this.events.onAutoStop();
        }
      }
    }, MAX_MS);
    return true;
  }

  /**
   * 免提通话：开麦后不用按住，检测到「说了话 + 停下来」就自动收尾，
   * 通过 events.onAutoStop 通知页面来 release()。原来的按住说话完全不受影响。
   */
  async startWithVad(events: VoiceInputEvents, silenceMs: number = 900,
    maxMs: number = 15000, waitMs: number = 20000): Promise<boolean> {
    const ok: boolean = await this.start(events, true);
    if (!ok) {
      return false;
    }
    this.mode = 'vad';
    this.vadOn = true;
    this.vadFired = false;
    this.vadStarted = false;
    this.vadSilenceAcc = 0;
    this.vadElapsed = 0;
    this.vadSilenceMs = silenceMs;
    this.vadMaxMs = maxMs;
    this.vadWaitMs = waitMs;
    return true;
  }

  /**
   * 她说话时在旁边听着：播放期间开麦，检测到你插话就回调一次。
   * 只有系统 AEC 真的可用、且本次录音确实起了通话音源时才允许，
   * 否则扬声器里的她会被当成「你在说话」，不停地自我打断。
   */
  async startBargeIn(events: VoiceInputEvents, onDetect: () => void): Promise<boolean> {
    const ok: boolean = await this.start(events, true);
    if (!ok || !this.callSource) {
      // 关键：start 已经把 capturer 起起来了，失败时必须自己关掉，
      // 否则麦克风一直被占着，下一轮 recordOnce 会开不了麦、整通电话卡死
      await this.cancel();
      return false;
    }
    this.mode = 'barge';
    this.bargeLoudMs = 0;
    this.onBargeIn = onDetect;
    return true;
  }

  /** 检测到插话、播放已停：原地转成 VAD 收尾，把你说的话接着录完 */
  armVadFromBarge(): void {
    if (this.mode !== 'barge') {
      return;
    }
    this.mode = 'vad';
    this.onBargeIn = null;
    this.vadOn = true;
    this.vadFired = false;
    this.vadStarted = true; // 已经听到人声，直接进「等你停下来」阶段
    this.vadSilenceAcc = 0;
    this.vadElapsed = 700;  // 跳过「至少录 700ms」的下限，短促一句「等下」也能收尾
    this.vadSilenceMs = 900;
    this.vadMaxMs = 15000;
    this.vadWaitMs = 20000;
  }

  /** 正常松开：停麦、封装 wav。没录到东西返回 null。 */
  async release(): Promise<VoiceClip | null> {
    if (!this.running) {
      return null;
    }
    this.lastClipVoiced = this.vadOn ? this.vadStarted : true;
    this.vadOn = false;
    this.vadFired = true;
    this.mode = 'normal';
    this.onBargeIn = null;
    this.running = false;
    if (this.stopTimer !== -1) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    // 留 250ms 让缓冲区里最后一点音频送到，不然句尾会被削掉半个字
    await new Promise<void>((r: () => void) => setTimeout(r, 250));
    await this.stopCapturer();
    if (this.discard) {
      if (this.events !== null) {
        this.events.onCancel();
      }
      return null;
    }
    return this.buildClip();
  }

  /** 上滑取消：作废这一次，不留文件 */
  async cancel(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.vadOn = false;
    this.vadFired = true;
    this.mode = 'normal';
    this.onBargeIn = null;
    this.discard = true;
    this.running = false;
    if (this.stopTimer !== -1) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    await this.stopCapturer();
    if (this.events !== null) {
      this.events.onCancel();
    }
  }

  // ==================== 内部 ====================

  /**
   * 通话走 SOURCE_TYPE_VOICE_COMMUNICATION（系统才认这是 VoIP、才会开 3A），
   * 按住说话仍用 SOURCE_TYPE_MIC，避免改变原来的音色/增益表现。
   * 部分设备起不来通话音源，自动退回普通麦克风，此时不启用播放期间插话。
   */
  private async startCapturer(callMode: boolean): Promise<boolean> {
    this.callSource = false;
    if (callMode) {
      const ok: boolean = await this.createCapturer(audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
      if (ok) {
        this.callSource = true;
        return true;
      }
    }
    return await this.createCapturer(audio.SourceType.SOURCE_TYPE_MIC);
  }

  private async createCapturer(source: audio.SourceType): Promise<boolean> {
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const capturerInfo: audio.AudioCapturerInfo = {
        source: source,
        capturerFlags: 0
      };
      const options: audio.AudioCapturerOptions = {
        streamInfo: streamInfo,
        capturerInfo: capturerInfo
      };
      const capturer = await audio.createAudioCapturer(options);
      capturer.on('readData', (buf: ArrayBuffer) => {
        this.feedPcm(buf);
      });
      await capturer.start();
      this.capturer = capturer;
      return true;
    } catch (e) {
      return false;
    }
  }

  private async stopCapturer(): Promise<void> {
    const cap = this.capturer;
    this.capturer = null;
    if (cap === null) {
      return;
    }
    try {
      cap.off('readData');
    } catch (e) {
      // 忽略
    }
    try {
      await cap.stop();
    } catch (e) {
      // 忽略
    }
    try {
      await cap.release();
    } catch (e) {
      // 忽略
    }
  }

  private feedPcm(buf: ArrayBuffer): void {
    // 收尾缓冲期的数据也要（running 已 false），只有取消才真的不要
    if (this.discard) {
      return;
    }
    const incoming = new Uint8Array(buf);
    if (incoming.length > 0) {
      this.pcmChunks.push(new Uint8Array(incoming)); // 拷贝一份，buf 会被复用
      this.pcmTotal += incoming.length;
    }
    if (this.mode === 'barge') {
      this.bargeStep(incoming);
      return;
    }
    if (this.vadOn && !this.vadFired) {
      this.vadStep(incoming);
    }
  }

  /**
   * 播放期间的插话检测：连续 260ms 明显有人声才算，
   * 免得一声咳嗽 / 椅子响就把她的话掐了。PCM 照常攒着，触发后能接着录完送 ASR。
   */
  private bargeStep(bytes: Uint8Array): void {
    const rms: number = rmsOf(bytes);
    if (this.onLevel !== null) {
      this.onLevel(rms);
    }
    if (rms > BARGE_RMS) {
      this.bargeLoudMs += bytes.length * 1000 / BYTES_PER_SEC;
    } else {
      this.bargeLoudMs = 0;
    }
    if (this.bargeLoudMs >= BARGE_HOLD_MS && this.onBargeIn !== null) {
      const cb: () => void = this.onBargeIn;
      this.onBargeIn = null;
      cb();
    }
  }

  /**
   * 极简能量 VAD：16k/16bit 单声道，逐块算 RMS。
   * 有人说话之后连续静音 900ms 收尾；最长 15 秒；一直没人说话等 20 秒重开一轮。
   */
  private vadStep(bytes: Uint8Array): void {
    const rms: number = rmsOf(bytes);
    if (this.onLevel !== null) {
      this.onLevel(rms);
    }
    const frameMs: number = bytes.length * 1000 / BYTES_PER_SEC;
    this.vadElapsed += frameMs;
    // 安静房间底噪一般几十，正常说话上千；400 是实测比较稳妥的分界
    if (rms > 400) {
      this.vadStarted = true;
      this.vadSilenceAcc = 0;
    } else if (this.vadStarted) {
      this.vadSilenceAcc += frameMs;
    }
    const spokeAndPaused: boolean = this.vadStarted && this.vadSilenceAcc >= this.vadSilenceMs
      && this.vadElapsed >= 700;
    // 15 秒上限只管「一直在说」；没人说话时交给 20 秒的等待，
    // 否则每 15 秒就会空转一次重新开麦（冒烟测试抓到过）
    const tooLong: boolean = this.vadStarted && this.vadElapsed >= this.vadMaxMs;
    const nobody: boolean = !this.vadStarted && this.vadElapsed >= this.vadWaitMs;
    if (spokeAndPaused || tooLong || nobody) {
      this.vadFired = true;
      VoiceInputService.buzz(20);
      if (this.events !== null) {
        this.events.onAutoStop();
      }
    }
  }

  /** 攒下的 PCM 封装成 wav 文件；没录到东西或没目录就返回 null */
  private buildClip(): VoiceClip | null {
    if (this.pcmTotal === 0 || this.filesDir.length === 0) {
      return null;
    }
    try {
      const dir: string = this.filesDir + '/voice';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const path: string = dir + '/v_' + Date.now().toString(36) + '.wav';
      const pcm = new Uint8Array(this.pcmTotal);
      let off: number = 0;
      for (let i: number = 0; i < this.pcmChunks.length; i++) {
        pcm.set(this.pcmChunks[i], off);
        off += this.pcmChunks[i].length;
      }
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, VoiceInputService.wavHeader(this.pcmTotal));
        fileIo.writeSync(file.fd, pcm.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      const clip: VoiceClip = {
        wavPath: path,
        durationMs: Math.round(this.pcmTotal / BYTES_PER_SEC * 1000),
        voiced: this.lastClipVoiced
      };
      return clip;
    } catch (e) {
      return null;
    } finally {
      this.pcmChunks = [];
      this.pcmTotal = 0;
    }
  }

  /** 44 字节标准 PCM wav 头（16k / 单声道 / 16bit） */
  private static wavHeader(dataLen: number): ArrayBuffer {
    const buf = new ArrayBuffer(44);
    const v = new DataView(buf);
    const ascii = (offset: number, s: string): void => {
      for (let i: number = 0; i < s.length; i++) {
        v.setUint8(offset + i, s.charCodeAt(i));
      }
    };
    ascii(0, 'RIFF');
    v.setUint32(4, 36 + dataLen, true);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    v.setUint32(16, 16, true);
    v.setUint16(20, 1, true);
    v.setUint16(22, 1, true);
    v.setUint32(24, SAMPLE_RATE, true);
    v.setUint32(28, BYTES_PER_SEC, true);
    v.setUint16(32, 2, true);
    v.setUint16(34, 16, true);
    ascii(36, 'data');
    v.setUint32(40, dataLen, true);
    return buf;
  }
}

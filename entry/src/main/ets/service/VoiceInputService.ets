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
}

const SAMPLE_RATE: number = 16000;
const BYTES_PER_SEC: number = SAMPLE_RATE * 2;
/** 单条语音上限 60 秒，到点自动收尾 */
const MAX_MS: number = 60000;

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

  /** 页面启动时把沙箱目录告诉它 */
  attach(filesDir: string): void {
    this.filesDir = filesDir;
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

  /** 按下：开麦录音。成功返回 true。 */
  async start(events: VoiceInputEvents): Promise<boolean> {
    if (this.running) {
      return false;
    }
    this.events = events;
    this.discard = false;
    this.pcmChunks = [];
    this.pcmTotal = 0;
    const capOk = await this.startCapturer();
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

  /** 正常松开：停麦、封装 wav。没录到东西返回 null。 */
  async release(): Promise<VoiceClip | null> {
    if (!this.running) {
      return null;
    }
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

  private async startCapturer(): Promise<boolean> {
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
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
        durationMs: Math.round(this.pcmTotal / BYTES_PER_SEC * 1000)
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

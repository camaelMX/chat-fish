import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 极简音频播放器：播 wav 文件，播完/出错/手动停都会收尾释放。
 * 同一时刻只有一路声音 —— 再点一次就是停。
 */
export class PlayerService {
  private player: media.AVPlayer | null = null;
  private playing: boolean = false;
  /** 播放自然结束（或被停）时给页面的回调，用于把气泡上的播放态复位 */
  private onFinish: (() => void) | null = null;

  isPlaying(): boolean {
    return this.playing;
  }

  /**
   * 播一个 wav 文件，resolve 于播放完成；被手动 stop 则 resolve。
   * callMode=true 时把播放流标成 VoIP 通话流，系统才会开 3A（回声消除），
   * 这样她说话时开麦才不会把她自己的声音当成你插话。
   * 普通语音条播放必须保持默认音乐流，不然路由/音量会变。
   */
  playFile(path: string, onFinish: () => void, callMode: boolean = false): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      if (this.playing) {
        reject(new Error('already playing'));
        return;
      }
      let file: fileIo.File | null = null;
      console.info('[VOICE] playFile ' + path);
      media.createAVPlayer().then((av: media.AVPlayer) => {
        this.player = av;
        this.playing = true;
        this.onFinish = onFinish;
        av.on('error', (err: BusinessError) => {
          console.error('[VOICE] player error ' + err.code + ' ' + err.message);
          this.teardown();
          reject(new Error('播放失败(' + err.code + ')'));
        });
        av.on('stateChange', (state: media.AVPlayerState) => {
          let dur: number = -1;
          try {
            dur = av.duration;
          } catch (e) {
            dur = -1;
          }
          console.info('[VOICE] state=' + state + ' dur=' + dur);
          if (state === 'completed' || state === 'stopped' || state === 'error') {
            this.teardown();
            resolve();
        } else if (state === 'initialized') {
          // audioRendererInfo 只允许在 initialized 状态设置
          if (callMode) {
            try {
              av.audioRendererInfo = {
                usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION,
                rendererFlags: 0
              };
            } catch (e) {
              console.warn('[VOICE] 通话播放流没设上，自动插话会降级到句间');
            }
          }
          av.prepare().then(() => {
            av.play();
          }).catch((e: BusinessError) => {
              this.teardown();
              reject(new Error('播放准备失败(' + e.code + ')'));
            });
          }
        });
        file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        av.fdSrc = { fd: file.fd };
      }).catch((e: BusinessError) => {
        this.teardown();
        reject(new Error('播放器起不来(' + e.code + ')'));
      });
    });
  }

  /** 手动停（点播放中的气泡 = 停） */
  stop(): void {
    if (this.player !== null && this.playing) {
      try {
        this.player.stop();
      } catch (e) {
        this.teardown();
      }
    }
  }

  private teardown(): void {
    const p = this.player;
    this.player = null;
    this.playing = false;
    const cb = this.onFinish;
    this.onFinish = null;
    if (p !== null) {
      try {
        p.release();
      } catch (e) {
        // 忽略
      }
    }
    if (cb !== null) {
      cb();
    }
  }
}

import { fileIo } from '@kit.CoreFileKit';

/** 她合成语音的缓存上限：超了从最老的开始删 */
const CACHE_LIMIT: number = 30 * 1024 * 1024;
/** 刚动过的文件先不动，免得删掉正在播的那一句 */
const PROTECT_MS: number = 5 * 60 * 1000;

interface CacheFile {
  path: string;
  size: number;
  mtime: number;
}

/**
 * voice 目录的清理工。
 *
 * 目录里两类文件：
 * - `v_*.wav` 你按住说话的录音，消息里用 audioPath 引用，删了那条语音就播不了
 * - `t_*.wav` 她说话的合成缓存，只是缓存，删了下次重新合成，内容不会丢
 *
 * 规则：
 * 1. 没有被任何消息引用的 `v_` 一律删（消息超过 400 条后，老的会变成孤儿）
 * 2. `t_` 保留最近用过的，总量压到 CACHE_LIMIT 以内
 */
export class VoiceStorage {
  /**
   * 扫一遍并清理，返回释放的字节数。
   * keepPaths 传当前消息里所有 audioPath，别的录音就会被当成孤儿。
   */
  static sweep(dir: string, keepPaths: string[]): number {
    let names: string[] = [];
    try {
      if (dir.length === 0 || !fileIo.accessSync(dir)) {
        return 0;
      }
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return 0;
    }

    const keep: Set<string> = new Set<string>();
    for (let i: number = 0; i < keepPaths.length; i++) {
      const p: string = keepPaths[i];
      if (p.length > 0) {
        keep.add(p);
      }
    }

    const now: number = Date.now();
    const cacheFiles: CacheFile[] = [];
    let cacheTotal: number = 0;
    let freed: number = 0;

    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i];
      const full: string = dir + '/' + name;
      let size: number = 0;
      let mtime: number = 0;
      try {
        const st = fileIo.statSync(full);
        size = st.size;
        mtime = st.mtime * 1000;
      } catch (e) {
        continue;
      }
      if (name.startsWith('v_')) {
        // 你的录音：只留消息还引用着的
        if (!keep.has(full)) {
          try {
            fileIo.unlinkSync(full);
            freed += size;
          } catch (e) {
          }
        }
      } else if (name.startsWith('t_')) {
        cacheTotal += size;
        const item: CacheFile = { path: full, size: size, mtime: mtime };
        cacheFiles.push(item);
      }
    }

    // 缓存超配额：从最老的删起，最近 5 分钟动过的留着
    if (cacheTotal > CACHE_LIMIT && cacheFiles.length > 0) {
      cacheFiles.sort((a: CacheFile, b: CacheFile): number => a.mtime - b.mtime);
      for (let i: number = 0; i < cacheFiles.length; i++) {
        if (cacheTotal <= CACHE_LIMIT) {
          break;
        }
        const f: CacheFile = cacheFiles[i];
        if (now - f.mtime < PROTECT_MS) {
          continue;
        }
        try {
          fileIo.unlinkSync(f.path);
          cacheTotal -= f.size;
          freed += f.size;
        } catch (e) {
        }
      }
    }
    return freed;
  }
}

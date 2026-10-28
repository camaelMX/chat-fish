# -*- coding: utf-8 -*-
"""
参考音频预处理：把 refs/incoming/ 里的原始录音转成 GPT-SoVITS 想要的标准格式。
用法：把两段录音放进 D:\voice-server\refs\incoming\，文件名里带 sweet / queen 即可，
     然后运行  runtime python make_refs.py
输出：D:\voice-server\refs\sweet.wav / queen.wav（22050Hz 单声道 16bit，自动削掉首尾静音）
"""
import glob
import os
import subprocess
import sys

FFMPEG = r'C:\ffmpeg\bin\ffmpeg.exe'
BASE = os.path.dirname(os.path.abspath(__file__))
REFS = os.path.join(BASE, 'refs')
INCOMING = os.path.join(REFS, 'incoming')


def find(kind):
    for ext in ('.wav', '.mp3', '.m4a', '.amr', '.flac', '.ogg'):
        hits = glob.glob(os.path.join(INCOMING, '*%s*%s' % (kind, ext))) + \
               glob.glob(os.path.join(INCOMING, '*' + kind + '*' + ext.upper()))
        if hits:
            return hits[0]
    return None


def convert(src, dst):
    # -af silenceremove 削首尾静音；重采样 22050 单声道 16bit
    cmd = [FFMPEG, '-y', '-i', src,
           '-af', 'silenceremove=start_periods=1:start_threshold=-45dB,'
                  'areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse',
           '-ar', '22050', '-ac', '1', '-sample_fmt', 's16', dst]
    subprocess.run(cmd, check=True, capture_output=True)


def main():
    ok = True
    for kind in ('sweet', 'queen'):
        src = find(kind)
        if src is None:
            print('[缺] 没找到 %s 的录音（文件名里要带 %s）' % (kind, kind))
            ok = False
            continue
        dst = os.path.join(REFS, kind + '.wav')
        convert(src, dst)
        size = os.path.getsize(dst)
        sec = 0.0
        try:
            import wave
            w = wave.open(dst)
            sec = w.getnframes() / w.getframerate()
            w.close()
        except Exception:
            pass
        print('[好] %s <- %s（%.1f 秒）' % (dst, os.path.basename(src), sec))
        if sec > 12:
            print('     注意：超过 12 秒了，建议 5-10 秒，太长首句响应会变慢')
    if not ok:
        sys.exit(1)
    print('完成。记得更新 config.json 里的 prompt_text（音频里说的那句话，一字不差）。')


if __name__ == '__main__':
    main()

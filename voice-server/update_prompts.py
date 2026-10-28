# -*- coding: utf-8 -*-
"""
自动补 prompt_text：调本机 /asr 把两段参考音频转写出来，写进 config.json。
前提：adapter（9880）在跑，make_refs.py 已经转过。
"""
import json
import os
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(BASE, 'config.json')


def asr(path):
    with open(path, 'rb') as f:
        data = f.read()
    req = urllib.request.Request('http://127.0.0.1:9880/asr', data=data,
                                 headers={'Content-Type': 'application/octet-stream'})
    r = urllib.request.urlopen(req, timeout=120)
    return json.loads(r.read()).get('text', '').strip()


def main():
    with open(CONFIG, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    for kind in ('sweet', 'queen'):
        wav = os.path.join(BASE, 'refs', kind + '.wav')
        if not os.path.exists(wav):
            print('[跳] %s.wav 不存在' % kind)
            continue
        text = asr(wav)
        if not text:
            print('[败] %s 没转出文字，手填吧' % kind)
            continue
        cfg['voices'][kind]['prompt_text'] = text
        print('[好] %s prompt_text = %s' % (kind, text))
    with open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    print('config.json 已更新。重启 adapter（stop_voice.bat / start_voice.bat）后生效。')


if __name__ == '__main__':
    main()

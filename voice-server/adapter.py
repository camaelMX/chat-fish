# -*- coding: utf-8 -*-
"""
她的声音 · 电脑侧适配服务

手机 App 只跟这个服务说话（默认 0.0.0.0:9880）：
  GET  /health                       → 200 {"ok": true}
  POST /tts  {text, voice}           → audio/wav   （转给 GPT-SoVITS api_v2，按音色映射参考音频）
  POST /asr  (wav 字节流)            → {"text": "..."} （FunASR paraformer，跑 CPU，不抢显存）

前置：
  1. GPT-SoVITS 整合包的 api_v2 服务先起好（见 start_gptsovits.bat，端口 9881）
  2. config.json 里填好两段参考音频（御姐/甜妹，各 5-10 秒 + 对应文字稿）
  3. pip install fastapi uvicorn funasr modelscope torchaudio requests
"""

import json
import os
import re
import sys
import threading
import time

# TTS 不认识 emoji，念出来是怪声；统一在入口剥掉
EMOJI_RE = re.compile(
    '[🀀-🫿☀-➿⬀-⯿︀-️'
    '‍ - ←-⇿©®™]+')


def clean_for_tts(text: str) -> str:
    return EMOJI_RE.sub('', text).replace('*', '').replace('#', '').strip()

import requests
import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE, 'config.json')


def load_config():
    with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)


CFG = load_config()
app = FastAPI()

# ---------------- 鉴权 ----------------
# config.json 的 token 非空时，/tts 和 /asr 必须带 X-Voice-Token，否则 401。
# /health 故意不校验：App 探活不带密钥，暴露出去也只泄露"服务在不在"。


def auth_ok(req: Request) -> bool:
    want = (CFG.get('token') or '').strip()
    if not want:
        return True
    return (req.headers.get('x-voice-token') or '').strip() == want


# ---------------- FunASR（语音转文字，CPU） ----------------

_asr_model = None
_asr_lock = threading.Lock()


def get_asr_model():
    """懒加载 FunASR：第一次转写时才拉模型（约 1GB，自动走 modelscope 缓存）"""
    global _asr_model
    if _asr_model is None:
        with _asr_lock:
            if _asr_model is None:
                from funasr import AutoModel
                print('[asr] loading FunASR paraformer-zh (first call, please wait)...', flush=True)
                _asr_model = AutoModel(
                    model=CFG.get('asr_model', 'paraformer-zh'),
                    vad_model='fsmn-vad',
                    punc_model='ct-punc',
                    device=CFG.get('asr_device', 'cpu'),
                    disable_update=True,
                )
                print('[asr] FunASR ready', flush=True)
    return _asr_model


# ---------------- 健康检查 ----------------

@app.get('/health')
def health():
    gpt_ok = False
    try:
        # api_v2 没有 /health，用 FastAPI 自带的 /docs 探活
        r = requests.get(CFG['gpt_sovits_url'] + '/docs', timeout=3)
        gpt_ok = (r.status_code == 200)
    except Exception:
        gpt_ok = False
    return {
        'ok': True,
        'tts': 'up' if gpt_ok else 'down',
        'asr': 'up',
        'refs': {k: bool(v.get('ref')) for k, v in CFG.get('voices', {}).items()},
    }


# ---------------- 文字转语音（GPT-SoVITS） ----------------

@app.post('/tts')
async def tts(req: Request):
    if not auth_ok(req):
        return JSONResponse({'error': 'token 不对'}, status_code=401)
    raw = await req.body()
    try:
        body = json.loads(raw.decode('utf-8'))
    except UnicodeDecodeError:
        # 命令行调试可能发 GBK，App 永远是 UTF-8
        body = json.loads(raw.decode('gbk', errors='replace'))
    text = clean_for_tts((body.get('text') or '').strip())
    voice = body.get('voice') or 'sweet'
    if not text:
        return JSONResponse({'error': 'empty text'}, status_code=400)
    vcfg = CFG.get('voices', {}).get(voice)
    if not vcfg or not vcfg.get('ref'):
        return JSONResponse({'error': 'voice "%s" 参考音频没配置，去改 config.json' % voice},
                            status_code=500)

    payload = {
        'text': text,
        'text_lang': CFG.get('text_lang', 'zh'),
        'ref_audio_path': vcfg['ref'],
        'prompt_text': vcfg.get('prompt_text', ''),
        'prompt_lang': CFG.get('prompt_lang', 'zh'),
        'text_split_method': 'cut5',
        'batch_size': 1,
        'media_type': 'wav',
        'streaming_mode': False,
        'temperature': 1.0,
        'top_p': 0.95,
        'top_k': 10,
        'repetition_penalty': 1.4,
    }
    try:
        r = requests.post(CFG['gpt_sovits_url'] + '/tts', json=payload, timeout=120)
    except Exception as e:
        return JSONResponse({'error': 'GPT-SoVITS 服务没通: %s' % e}, status_code=502)
    if r.status_code != 200:
        return JSONResponse({'error': 'GPT-SoVITS 返回 %d' % r.status_code}, status_code=502)
    return Response(content=postprocess(r.content), media_type='audio/wav')


def postprocess(wav: bytes) -> bytes:
    """合成结果统一响度、削掉头部静音——模型输出音量随机波动，这里兜底"""
    import subprocess, tempfile, os
    src = os.path.join(BASE, '_pp_in.wav')
    dst = os.path.join(BASE, '_pp_out.wav')
    with open(src, 'wb') as f:
        f.write(wav)
    try:
        subprocess.run([CFG.get('ffmpeg', 'ffmpeg'), '-y', '-i', src,
                        '-af', 'silenceremove=start_periods=1:start_threshold=-38dB,'
                               'loudnorm=I=-16:TP=-1.5:LRA=9',
                        '-ar', '32000', '-ac', '1', '-sample_fmt', 's16', dst],
                       check=True, capture_output=True)
        with open(dst, 'rb') as f:
            return f.read()
    except Exception:
        return wav
    finally:
        for f in (src, dst):
            try:
                os.remove(f)
            except OSError:
                pass


# ---------------- 语音转文字（FunASR，CPU） ----------------

@app.post('/asr')
async def asr(req: Request):
    if not auth_ok(req):
        return JSONResponse({'error': 'token 不对'}, status_code=401)
    wav = await req.body()
    if len(wav) < 100:
        return JSONResponse({'error': 'empty audio'}, status_code=400)
    tmp = os.path.join(BASE, '_tmp_%d.wav' % int(time.time() * 1000))
    with open(tmp, 'wb') as f:
        f.write(wav)
    try:
        import asyncio
        import concurrent.futures
        loop = asyncio.get_event_loop()
        # FunASR 不是线程安全的：加载+推理全程持锁串行，并发请求排队
        def run():
            with _asr_lock:
                model = get_asr_model()
                return model.generate(input=tmp, batch_size_s=60)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            res = await loop.run_in_executor(pool, run)
        text = ''
        if res and len(res) > 0:
            text = (res[0].get('text') or '').strip()
        return {'text': text}
    except Exception as e:
        import traceback
        traceback.print_exc()
        return JSONResponse({'error': '转写失败: %s' % e}, status_code=500)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


if __name__ == '__main__':
    port = int(CFG.get('port', 9880))
    print('adapter listening on 0.0.0.0:%d' % port, flush=True)
    if not (CFG.get('token') or '').strip():
        print('[warn] config.json 没有设置 token，/tts 和 /asr 对任何人不设防', flush=True)
    # 后台先把 ASR 模型装好，第一条语音不用等加载
    threading.Thread(target=get_asr_model, daemon=True).start()
    uvicorn.run(app, host='0.0.0.0', port=port, log_level='warning')

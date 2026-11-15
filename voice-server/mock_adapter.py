# -*- coding: utf-8 -*-
"""
mock 版适配服务：App 全流程联调用，不依赖 GPU/模型。
  GET  /health → 200
  POST /asr    → 固定转写「今天好累，想早点休息」（真实版等 FunASR 装好）
  POST /tts    → 返回一段随文本长度变化的提示音 wav
跑在 9880，和正式 adapter.py 同一个契约，之后无缝切换。
"""
import io
import json
import math
import struct
import wave

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI()
FAKE_TEXT = '今天好累，想早点休息'


def beep_wav(seconds: float) -> bytes:
    """生成一段柔和的 440Hz 提示音（16k/mono/16bit），时长跟文本走"""
    sr = 16000
    n = max(int(sr * seconds), sr // 2)
    buf = io.BytesIO()
    w = wave.open(buf, 'wb')
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    frames = bytearray()
    for i in range(n):
        t = i / sr
        # 渐入渐出，别刺耳
        env = min(1.0, t * 10, max(0.0, (n / sr - t) * 10))
        v = int(12000 * env * math.sin(2 * math.pi * 440 * t))
        frames += struct.pack('<h', v)
    w.writeframes(bytes(frames))
    w.close()
    return buf.getvalue()


@app.get('/health')
def health():
    return {'ok': True, 'tts': 'mock', 'asr': 'mock'}


@app.post('/asr')
async def asr(req: Request):
    body = await req.body()
    if len(body) < 100:
        return JSONResponse({'error': 'empty audio'}, status_code=400)
    return {'text': FAKE_TEXT}


@app.post('/tts')
async def tts(req: Request):
    raw = await req.body()
    try:
        body = json.loads(raw.decode('utf-8'))
    except UnicodeDecodeError:
        body = json.loads(raw.decode('gbk', errors='replace'))
    text = (body.get('text') or '').strip()
    if not text:
        return JSONResponse({'error': 'empty text'}, status_code=400)
    # 中文大约每字 0.18 秒，太长截到 12 秒
    seconds = min(len(text) * 0.18, 12.0)
    return Response(content=beep_wav(seconds), media_type='audio/wav')


if __name__ == '__main__':
    print('mock adapter on 0.0.0.0:9880', flush=True)
    uvicorn.run(app, host='0.0.0.0', port=9880, log_level='warning')

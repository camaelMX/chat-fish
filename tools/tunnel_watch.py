# -*- coding: utf-8 -*-
"""
启动 Cloudflare quick tunnel，并把分配到的公网网址写进 voice-server/tunnel_url.txt。

为什么要这一步：quick tunnel 每次重启都会换一个 xxx.trycloudflare.com 域名，
以前得手动抄进 App 设置。现在 adapter.py 的 /ping 会读这个文件，App 在家
连局域网时顺手把网址记到手机里，出门直接走隧道 —— 不用域名、不用第三方
服务、不用重新打包 App。

只用标准库，任意 Python 3.8+ 都能跑。窗口不要关，关了隧道就断。
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

URL_RE = re.compile(r'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com', re.IGNORECASE)


def collect_targets():
    """
    网址文件的位置。隧道脚本在仓库 tools\\ 下，adapter 可能跑在另一个部署
    目录（设置环境变量 VOICE_DIR 指向它），所以所有「有 adapter.py」的候选
    目录都写一份，谁在跑谁就能读到。
    """
    env = os.environ.get('VOICE_TUNNEL_URL_FILE', '').strip()
    if env and Path(env).parent.is_dir():
        return [Path(env)]

    dirs = []
    deploy = os.environ.get('VOICE_DIR', '').strip()
    if deploy:
        dirs.append(Path(deploy))          # 部署目录（env.bat 里设的）
    dirs += [
        ROOT / 'voice-server',             # 仓库源码目录
        HERE.parent,                       # tools 被单独拷过去时
        HERE,                              # 兜底
    ]
    existing = []
    for d in dirs:
        if d.is_dir() and d not in existing:
            existing.append(d)
    matched = [d for d in existing if (d / 'adapter.py').exists()]
    base = matched if matched else (existing[:1] if existing else [HERE])
    targets = []
    for d in base:
        # 两种命名都写：老的自启脚本读 tunnel-url.txt，
        # 仓库版 adapter 两个都认，tools 脚本原来用 tunnel_url.txt
        for name in ('tunnel-url.txt', 'tunnel_url.txt'):
            p = d / name
            if p not in targets:
                targets.append(p)
    return targets


def find_cloudflared() -> str:
    local = HERE / 'cloudflared.exe'
    if local.exists():
        return str(local)
    return shutil.which('cloudflared') or ''


def write_url(targets, url: str) -> None:
    for target in targets:
        try:
            target.write_text(url + ('\n' if url else ''), encoding='utf-8')
        except OSError as e:
            print('[警告] 写 %s 失败：%s' % (target, e), flush=True)


def main() -> int:
    exe = find_cloudflared()
    if not exe:
        print('[错误] 没找到 cloudflared.exe：放到 tools 目录，或加进 PATH', flush=True)
        return 1

    targets = collect_targets()
    print('隧道网址会写到：%s' % '、'.join(str(p) for p in targets), flush=True)
    print('正在连接 Cloudflare，稍等几秒……', flush=True)
    print('这个窗口不要关，关掉隧道就断了。', flush=True)
    print('=' * 60, flush=True)

    # 两个参数不能去掉，原因见 docs/外网访问.md：
    #   --edge-ip-version 4  家里路由器返回的 IPv6 记录有一条非法的 ::
    #   --protocol http2     家里宽带到 Cloudflare 的 UDP 7844 不通
    cmd = [
        exe, 'tunnel', '--url', 'http://127.0.0.1:9880',
        '--no-autoupdate', '--edge-ip-version', '4', '--protocol', 'http2',
    ]
    try:
        proc = subprocess.Popen(
            cmd, cwd=str(HERE), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace', bufsize=1,
        )
    except OSError as e:
        print('[错误] 启动 cloudflared 失败：%s' % e, flush=True)
        return 1

    current = ''
    try:
        if proc.stdout is None:
            proc.wait()
            return 0
        for raw in proc.stdout:
            line = raw.rstrip('\r\n')
            print(line, flush=True)
            m = URL_RE.search(line)
            if not m:
                continue
            url = m.group(0)
            if url == current:
                continue
            current = url
            write_url(targets, url)
            print('', flush=True)
            print('=' * 60, flush=True)
            print('  隧道已就绪：%s' % url, flush=True)
            print('  手机在家连一次局域网就会自动记住，出门直接能用', flush=True)
            print('=' * 60, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        # 隧道停了就把网址清掉，别让 App 拿着过期地址一直试
        write_url(targets, '')
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
    return 0


if __name__ == '__main__':
    sys.exit(main())

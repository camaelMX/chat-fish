# -*- coding: utf-8 -*-
"""一次性更新 App 里四处头像资源（通话页两张头像随机切换）。

用法（需要 Pillow）：
    python tools/update_avatars.py                       # 两张都用 assets/ 里的默认源图
    python tools/update_avatars.py <主图>                # 换桌面图标/左上角/通话头像 A
    python tools/update_avatars.py <主图> <通话头像B>     # 两张一起换

生成：
  AppScope/resources/base/media/app_icon.png       216×216  桌面图标（app.json5 的 $media:app_icon）
  entry/src/main/resources/base/media/startIcon.png 216×216 启动图标 + 聊天页左上角头像
  AppScope/resources/base/media/call_avatar.png    512×512  通话页头像 A（平涂扩图版）
  AppScope/resources/base/media/call_avatar_alt.png 512×512 通话页头像 B（光影圆底版）

通话页是正圆裁切，所以 A 会在四周补 6% 白边，保证头顶光环和左右羽翼
不被圆边切掉；B 自带圆形构图和深色四角，直接按原样输出即可。
换图时覆盖 assets/ 里的源图再跑一次，不用改任何代码。
"""

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / 'assets' / 'avatar_source.jpg'
DEFAULT_ALT = ROOT / 'assets' / 'avatar_alt_source.png'
ICON = ROOT / 'AppScope' / 'resources' / 'base' / 'media' / 'app_icon.png'
START = ROOT / 'entry' / 'src' / 'main' / 'resources' / 'base' / 'media' / 'startIcon.png'
CALL = ROOT / 'AppScope' / 'resources' / 'base' / 'media' / 'call_avatar.png'
CALL_ALT = ROOT / 'AppScope' / 'resources' / 'base' / 'media' / 'call_avatar_alt.png'
ICON_SIZE = 216
CALL_SIZE = 512
CALL_PAD_RATE = 0.06


def square(im: Image.Image) -> Image.Image:
    """非正方形图先居中裁成正方形，避免头像被拉伸变形。"""
    w, h = im.size
    if w == h:
        return im
    side = min(w, h)
    return im.crop(((w - side) // 2, (h - side) // 2,
                    (w + side) // 2, (h + side) // 2))


def load(path: Path) -> Image.Image:
    if not path.exists():
        raise SystemExit('找不到图片：%s' % path)
    return square(Image.open(path).convert('RGB'))


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
    alt_src = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_ALT
    im = load(src)

    icon = im.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    icon.save(ICON)
    icon.save(START)

    pad = int(CALL_SIZE * CALL_PAD_RATE)
    inner = im.resize((CALL_SIZE - 2 * pad, CALL_SIZE - 2 * pad), Image.LANCZOS)
    call = Image.new('RGB', (CALL_SIZE, CALL_SIZE), (255, 255, 255))
    call.paste(inner, (pad, pad))
    call.save(CALL)

    alt = load(alt_src)
    alt.resize((CALL_SIZE, CALL_SIZE), Image.LANCZOS).save(CALL_ALT)

    print('主图 %s %s / 副图 %s %s' % (src, im.size, alt_src, alt.size))
    print('桌面图标 / 启动图标 / 左上角头像：%s、%s（%dx%d）'
          % (ICON.name, START.name, ICON_SIZE, ICON_SIZE))
    print('通话页头像 A：%s（%dx%d，四周 %dpx 白边）'
          % (CALL.name, CALL_SIZE, CALL_SIZE, pad))
    print('通话页头像 B：%s（%dx%d，原样圆形构图）'
          % (CALL_ALT.name, CALL_SIZE, CALL_SIZE))


if __name__ == '__main__':
    main()

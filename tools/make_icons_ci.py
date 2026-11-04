# CI 用：在云端编译前生成 App 图标（终定 A「流光三线」，纯白底 + 纯黑圆角三线）
# 仓库里不存二进制 PNG，GitHub Actions 里用 Pillow 现生成，与本地定版几何完全一致。
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048
W = S

img = Image.new('RGB', (S, S), (255, 255, 255))
d = ImageDraw.Draw(img)
bar_h = int(0.054 * W)
ys = [0.395, 0.500, 0.605]
starts = [0.285, 0.335, 0.385]
lengths = [0.430, 0.345, 0.260]
for yc, xs, ln in zip(ys, starts, lengths):
    y0 = int(yc * W - bar_h / 2)
    y1 = int(yc * W + bar_h / 2)
    d.rounded_rectangle([int(xs * W), y0, int((xs + ln) * W), y1], radius=bar_h // 2, fill=(0, 0, 0))

# 微细节（终定 A）：第一条线内侧居中白色小字 lumen，苹果式紧字距、x 高度光学居中
from PIL import ImageFont
_word = "lumen"
_size = 46
_font = None
for _p in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
           "/System/Library/Fonts/Supplemental/Arial.ttf",
           "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
           "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
    try:
        _font = ImageFont.truetype(_p, _size); break
    except Exception:
        continue
if _font is not None:
    _tracking = int(_size * 0.07)
    _widths = [d.textlength(c, font=_font) for c in _word]
    _total = sum(_widths) + _tracking * (len(_word) - 1)
    _x = (starts[0] + lengths[0] / 2) * W - _total / 2
    _asc, _desc = _font.getmetrics()
    _ty = ys[0] * W - _asc * 0.36 - _size * 0.18
    for _ch, _wch in zip(_word, _widths):
        d.text((_x, _ty), _ch, font=_font, fill=(255, 255, 255))
        _x += _wch + _tracking

icon = img.resize((1024, 1024), Image.LANCZOS)
out = os.path.join(ROOT, 'Lumen', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-1024.png')
icon.save(out)
print('wrote', out)

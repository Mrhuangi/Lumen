# 流光 App 图标定版（黑白极简）：纯黑底 + 白色「流光三线」
# 用户 2026-11-04 在 A 流光三线 / B 光圈 / C 日食三候选中最终选定 A（候选生成见 make_candidates.py）。
from PIL import Image, ImageDraw

S = 2048
W = S
img = Image.new('RGB', (S, S), (0, 0, 0))
d = ImageDraw.Draw(img)
bar_h = int(0.054 * W)
ys = [0.395, 0.500, 0.605]
starts = [0.285, 0.335, 0.385]
lengths = [0.430, 0.345, 0.260]
for yc, xs, ln in zip(ys, starts, lengths):
    y0 = int(yc * W - bar_h / 2); y1 = int(yc * W + bar_h / 2)
    d.rounded_rectangle([int(xs * W), y0, int((xs + ln) * W), y1], radius=bar_h // 2, fill=(255, 255, 255))

icon = img.resize((1024, 1024), Image.LANCZOS)
icon.save('/home/hatch/workspace/Lumen/Lumen/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')
print('bg:', icon.load()[60, 60], 'bar:', icon.load()[400, 404])

prev = icon.convert('RGBA')
corner = Image.new('L', (1024, 1024), 0)
pd = ImageDraw.Draw(corner)
pd.rounded_rectangle([0, 0, 1023, 1023], radius=225, fill=255)
prev.putalpha(corner)
canvas = Image.new('RGBA', (1100, 1100), (0, 0, 0, 0))
canvas.alpha_composite(prev, (38, 38))
cd = ImageDraw.Draw(canvas)
cd.rounded_rectangle([38, 38, 1061, 1061], radius=225, outline=(255, 255, 255, 60), width=2)
canvas.save('/home/hatch/workspace/liuguang-icon-preview.png')
print('icon done')

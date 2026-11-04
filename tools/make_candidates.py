# 流光图标中心符号候选（黑白极简）：A 流光三线 / B 光圈 / C 日食
from PIL import Image, ImageDraw, ImageFont

S = 2048
W = S

def canvas():
    img = Image.new('RGB', (S, S), (0, 0, 0))
    return img, ImageDraw.Draw(img)

# A 流光三线：三条错落的圆角横线，像光流过
imgA, d = canvas()
bar_h = int(0.054 * W)
ys = [0.395, 0.500, 0.605]
starts = [0.285, 0.335, 0.385]
lengths = [0.430, 0.345, 0.260]
for yc, xs, ln in zip(ys, starts, lengths):
    y0 = int(yc * W - bar_h / 2); y1 = int(yc * W + bar_h / 2)
    d.rounded_rectangle([int(xs * W), y0, int((xs + ln) * W), y1], radius=bar_h // 2, fill=(255, 255, 255))
imgA = imgA.resize((1024, 1024), Image.LANCZOS)
imgA.save('/home/hatch/workspace/icon-candidate-a.png')

# B 光圈：圆环 + 光点，像镜头，也像一枚「光」
imgB, d = canvas()
r = 0.205 * W; c = 0.5 * W
d.ellipse([c - r, c - r, c + r, c + r], outline=(255, 255, 255), width=int(0.058 * W))
ri = 0.082 * W
d.ellipse([c - ri, c - ri, c + ri, c + ri], fill=(255, 255, 255))
imgB = imgB.resize((1024, 1024), Image.LANCZOS)
imgB.save('/home/hatch/workspace/icon-candidate-b.png')

# C 日食：黑白相切出的月牙——黑暗里透出的光
imgC, d = canvas()
cx, cy, r = 0.485 * W, 0.500 * W, 0.200 * W
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255))
ox, oy, orr = cx + 0.105 * W, cy - 0.048 * W, 0.168 * W
d.ellipse([ox - orr, oy - orr, ox + orr, oy + orr], fill=(0, 0, 0))
imgC = imgC.resize((1024, 1024), Image.LANCZOS)
imgC.save('/home/hatch/workspace/icon-candidate-c.png')

# 对比图：三枚圆角图标横排
def rounded_icon(img, size=620, radius=138):
    out = img.resize((size, size), Image.LANCZOS).convert('RGBA')
    m = Image.new('L', (size, size), 0)
    md = ImageDraw.Draw(m)
    md.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    out.putalpha(m)
    return out

sheet = Image.new('RGBA', (2200, 940), (26, 26, 26, 255))
font = ImageFont.load_default(size=64)
for i, p in enumerate(['/home/hatch/workspace/icon-candidate-a.png',
                       '/home/hatch/workspace/icon-candidate-b.png',
                       '/home/hatch/workspace/icon-candidate-c.png']):
    ic = rounded_icon(Image.open(p))
    x = 90 + i * 700
    sheet.alpha_composite(ic, (x, 70))
    sd = ImageDraw.Draw(sheet)
    sd.rounded_rectangle([x, 70, x + 619, 689], radius=138, outline=(255, 255, 255, 70), width=2)
    label = 'ABC'[i]
    tw = sd.textlength(label, font=font)
    sd.text((x + (620 - tw) / 2, 750), label, font=font, fill=(255, 255, 255, 255))
sheet.convert('RGB').save('/home/hatch/workspace/liuguang-icon-candidates.png')
print('candidates done')

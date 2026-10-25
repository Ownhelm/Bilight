#!/usr/bin/env python3
"""Draw original fictional covers; compose actual mock-only product captures for the README."""
from pathlib import Path
import argparse
import shutil
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/assets'
OUT.mkdir(parents=True, exist_ok=True)
FONT = next((p for p in ['/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/STHeiti Medium.ttc', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'] if Path(p).exists()), None)

def font(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()

def label(draw, xy, text, size=26, fill='#334349'):
    draw.text(xy, text, font=font(size), fill=fill)

def covers():
    for name, background in [('mountain', '#dcebe8'), ('waves', '#deedf7'), ('window', '#f8e4d5'), ('code', '#e6e8f3')]:
        im = Image.new('RGB', (1000, 625), background)
        d = ImageDraw.Draw(im)
        if name == 'mountain':
            d.ellipse((705, 85, 840, 220), fill='#f4ca92')
            d.polygon([(0, 470), (310, 150), (560, 470)], fill='#96b7ac')
            d.polygon([(310, 510), (650, 215), (1000, 510)], fill='#6a9487')
            d.polygon([(0, 540), (340, 380), (680, 625), (0, 625)], fill='#466c65')
            d.polygon([(490, 625), (890, 370), (1000, 480), (1000, 625)], fill='#35554f')
            label(d, (58, 62), '山野之间', 42)
            label(d, (62, 120), '山间放映室 · 演示封面', 22)
        elif name == 'waves':
            d.ellipse((720, 65, 850, 195), fill='#fff1d3')
            d.rectangle((0, 320, 1000, 625), fill='#a4c8d7')
            for i, color in enumerate(['#7baebe', '#6a9dae', '#4d8091']):
                d.ellipse((-300 + i*100, 370 + i*75, 1350, 900), fill=color)
            d.line((80, 396, 420, 396), fill='#eff9fb', width=4)
            d.line((600, 459, 940, 459), fill='#eff9fb', width=3)
            label(d, (58, 62), '海边来信', 42)
            label(d, (62, 120), '给生活留一点空白', 22)
        elif name == 'window':
            d.rounded_rectangle((430, 70, 790, 500), 125, fill='#fff9ef')
            d.rounded_rectangle((459, 100, 761, 470), 100, fill='#adcad4')
            d.rectangle((605, 100, 615, 470), fill='#fff9ef')
            d.rectangle((459, 295, 761, 306), fill='#fff9ef')
            d.rectangle((310, 490, 890, 512), fill='#b78f77')
            d.rectangle((150, 555, 940, 625), fill='#d4b7a0')
            d.rounded_rectangle((600, 500, 675, 555), 8, fill='#fbfaf7')
            label(d, (55, 90), '慢慢', 42)
            label(d, (55, 150), '观察', 42)
        else:
            d.rounded_rectangle((145, 115, 855, 535), 24, fill='#fffefd')
            d.rounded_rectangle((145, 115, 855, 163), 22, fill='#d2d6e7')
            for x, color in [(174, '#ef9eac'), (200, '#edc989'), (226, '#a6c7b9')]:
                d.ellipse((x, 133, x+12, 145), fill=color)
            for i, width in enumerate([220, 310, 410, 280, 350, 180]):
                x = 207 + (30 if i in [2, 3, 4] else 0)
                d.rounded_rectangle((x, 205+i*40, x+width, 217+i*40), 6, fill=['#c2b4d7', '#a7c7ca', '#d7bdca'][i%3])
            label(d, (52, 38), '像素笔记', 34)
        im.save(OUT / f'demo-{name}.png', optimize=True)
    for i, color in enumerate(['#ee7d9e', '#6c9b8d', '#8196bc', '#d3a17a']):
        im = Image.new('RGB', (240, 240), color)
        d = ImageDraw.Draw(im)
        d.ellipse((80, 45, 160, 125), fill='#fffaf7')
        d.rounded_rectangle((45, 140, 195, 267), 68, fill='#fffaf7')
        im.save(OUT / f'demo-avatar-{i}.png', optimize=True)
    target = ROOT / 'ios/Bilight/Demo'
    target.mkdir(parents=True, exist_ok=True)
    for file in OUT.glob('demo-*.png'):
        shutil.copyfile(file, target / file.name)

def card(canvas, image, box, radius=18):
    image = ImageOps.fit(image.convert('RGB'), (box[2], box[3]))
    mask = Image.new('L', image.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width, image.height), radius, fill=255)
    shadow = Image.new('RGBA', canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1]+12, box[0]+box[2], box[1]+box[3]+12), radius, fill=(50, 53, 71, 30))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    canvas.paste(image, (box[0], box[1]), mask)

def compose():
    im = Image.new('RGBA', (1680, 1060), '#faf9fb')
    d = ImageDraw.Draw(im)
    d.ellipse((1170, -300, 1920, 450), fill='#fbeaf0')
    d.ellipse((-360, 610, 640, 1480), fill='#eaf3f8')
    # Original TV mark, matching the app's simple outline language.
    d.rounded_rectangle((67, 74, 124, 115), 9, outline='#ed6d96', width=4)
    d.line((82, 64, 96, 74, 110, 64), fill='#ed6d96', width=4)
    d.ellipse((83, 91, 87, 95), fill='#ed6d96')
    d.ellipse((103, 91, 107, 95), fill='#ed6d96')
    label(d, (142, 51), 'Bilight', 62, '#2a2c35')
    label(d, (69, 145), '搜你所想，看你所选', 38, '#424650')
    label(d, (71, 209), '一个只保留搜索与关注的 B 站客户端', 22, '#858994')
    browser = Image.open(OUT / 'web-following.png')
    # Keep the whole real browser viewport; no invented controls or product content.
    width = 1160
    height = round(browser.height * width / browser.width)
    card(im, browser, (65, 305, width, height))
    phone = Image.open(OUT / 'ios-home.png')
    ph = 765
    pw = round(phone.width * ph / phone.height)
    card(im, phone, (1257, 174, pw, ph), 35)
    d = ImageDraw.Draw(im)
    label(d, (76, 963), '原生 iPhone App    /    本地 Docker 网页端', 25, '#5f6571')
    label(d, (76, 1007), '界面截图使用虚构账号、自制封面与 mock 数据', 18, '#9397a1')
    im.convert('RGB').save(OUT / 'hero.png', optimize=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--compose', action='store_true')
    args = parser.parse_args()
    compose() if args.compose else covers()

# Spacewalk launch film: 10 s, 1920x1080, 60 fps. Composited from the app icon, SF Pro type and
# transition frames rendered by the real engine. Regenerate with:
#   spacewalk effect cube && spacewalk render "/tmp/reel/0-cube|scrub|60|1440x900"
#   spacewalk effect flip && spacewalk render "/tmp/reel/3-flip|scrub|60|1440x900|back"
#   python3 Scripts/launch_film.py /tmp/reel out
#   ffmpeg -framerate 60 -i out/f_%04d.png -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart launch.mp4
# Needs Pillow and numpy. Beats: icon reveal, wordmark, tagline, the product on a device with cube
# and flip, headline, closing lockup.
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np, glob, math, os, sys

W, H, FPS, DUR = 1920, 1080, 60, 10.0
N = int(FPS * DUR)
REEL = sys.argv[1] if len(sys.argv) > 1 else 'reel'
OUT = sys.argv[2] if len(sys.argv) > 2 else 'launch_frames'; os.makedirs(OUT, exist_ok=True)
BG = (10, 10, 14, 255)
PRIMARY = (246, 246, 250); SECONDARY = (158, 158, 170); MUTED = (118, 118, 130)

def font(name, size, mono=False):
    path = '/System/Library/Fonts/SFNSMono.ttf' if mono else '/System/Library/Fonts/SFNS.ttf'
    f = ImageFont.truetype(path, size)
    try: f.set_variation_by_name(name)
    except Exception: pass
    return f
WORDMARK = font('Semibold', 150); WORD_SMALL = font('Semibold', 120)
HEADLINE = font('Semibold', 58); TAGLINE = font('Regular', 46); LINE = font('Regular', 40); MONO = font('Regular', 32, mono=True)

icon = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Resources', 'AppIcon', 'icon-1024.png')).convert('RGBA')
cube = [Image.open(f).convert('RGBA') for f in sorted(glob.glob(os.path.join(REEL, '0-cube', 'cube_scrub_*.png')))]
flip = [Image.open(f).convert('RGBA') for f in sorted(glob.glob(os.path.join(REEL, '3-flip', 'flip_scrub_*.png')))]
assert len(cube) == 60 and len(flip) == 60

clamp = lambda v: max(0.0, min(1.0, v))
def seg(t, a, b): return clamp((t - a) / (b - a))
def smooth(x): x = clamp(x); return x * x * (3 - 2 * x)
def expo(x): x = clamp(x); return 1 - math.pow(2, -10 * x) if x < 1 else 1.0
def bezier(x1, y1, x2, y2, x):
    # CSS cubic-bezier by bisection; (0.4, 0, 0.2, 1) is the app's "smooth" curve.
    def pt(s, a, b): return 3 * (1 - s) ** 2 * s * a + 3 * (1 - s) * s * s * b + s ** 3
    lo, hi, s = 0.0, 1.0, x
    for _ in range(30):
        px = pt(s, x1, x2)
        if abs(px - x) < 1e-5: break
        if px < x: lo = s
        else: hi = s
        s = (lo + hi) / 2
    return pt(s, y1, y2)

def radial(size, color, strength):
    y, x = np.ogrid[:size, :size]
    r = np.sqrt((x - size / 2) ** 2 + (y - size / 2) ** 2) / (size / 2)
    a = np.clip(1 - r, 0, 1) ** 2.4 * strength
    arr = np.zeros((size, size, 4), np.uint8); arr[..., :3] = color; arr[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(arr)
GLOW_V = radial(512, (120, 90, 255), 0.95)
GLOW_T = radial(512, (40, 170, 200), 0.7)

def with_alpha(layer, a):
    if a >= 0.999: return layer
    alpha = layer.getchannel('A').point(lambda v: int(v * a))
    layer = layer.copy(); layer.putalpha(alpha); return layer

def paste(base, img, center, width, a=1.0):
    if a <= 0.002 or width < 2: return
    h = int(round(img.height * width / img.width)); w = int(round(width))
    layer = with_alpha(img.resize((w, h), Image.LANCZOS), a)
    base.alpha_composite(layer, (int(center[0] - w / 2), int(center[1] - h / 2)))

def glow(base, g, center, size, a):
    if a <= 0.002: return
    layer = with_alpha(g.resize((int(size), int(size)), Image.BILINEAR), a)
    base.alpha_composite(layer, (int(center[0] - size / 2), int(center[1] - size / 2)))

def text(base, s, f, pos, fill, a, anchor='mm'):
    # Drawn on its own layer and composited: ImageDraw writes a translucent fill straight into the
    # pixels, which would make every fade a hard cut once the alpha channel is dropped.
    if a <= 0.002: return
    probe = ImageDraw.Draw(base)
    x0, y0, x1, y1 = probe.textbbox(pos, s, font=f, anchor=anchor)
    pad = 6
    layer = Image.new('RGBA', (int(x1 - x0) + 2 * pad, int(y1 - y0) + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((pos[0] - x0 + pad, pos[1] - y0 + pad), s, font=f, fill=(*fill, 255), anchor=anchor)
    base.alpha_composite(with_alpha(layer, a), (int(x0) - pad, int(y0) - pad))

def rounded(img, radius):
    mask = Image.new('L', img.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    out = img.copy(); out.putalpha(mask); return out

# ---- lockup geometry
WORD = 'Spacewalk'
tw = WORDMARK.getlength(WORD); ICON_S = 176; GAP = 44
lock_w = ICON_S + GAP + tw; lock_x = (W - lock_w) / 2
icon_lock_center = (lock_x + ICON_S / 2, 540); text_left = lock_x + ICON_S + GAP

def frame(t):
    base = Image.new('RGBA', (W, H), BG)

    # ---- beats 1 to 3: icon, wordmark, tagline (0.0 to 4.4 s)
    if t < 4.5:
        lock_a = 1 - smooth(seg(t, 3.9, 4.4))
        reveal = smooth(seg(t, 0.0, 0.9)) * lock_a
        size0 = 440 * (0.86 + 0.14 * expo(seg(t, 0.0, 1.1)))
        move = expo(seg(t, 1.25, 2.05))
        cx = 960 + (icon_lock_center[0] - 960) * move
        cy = 500 + (icon_lock_center[1] - 500) * move
        size = size0 + (ICON_S - size0) * move
        glow(base, GLOW_V, (cx, cy), size * 3.6, smooth(seg(t, 0.15, 1.3)) * 1.0 * lock_a * (1 - 0.55 * move))
        glow(base, GLOW_T, (cx - size * 0.5, cy + size * 0.35), size * 2.2, smooth(seg(t, 0.4, 1.5)) * 0.5 * lock_a * (1 - 0.6 * move))
        paste(base, icon, (cx, cy), size, reveal)
        baseline = 540 + 54
        for i, ch in enumerate(WORD):
            start = 1.8 + i * 0.045
            a = expo(seg(t, start, start + 0.55))
            if a <= 0: continue
            x = text_left + WORDMARK.getlength(WORD[:i]) + (1 - a) * 28
            text(base, ch, WORDMARK, (x, baseline), PRIMARY, a * lock_a, anchor='ls')
        a = smooth(seg(t, 2.75, 3.4))
        text(base, 'Instant, animated switching between macOS Spaces.', TAGLINE, (960, 690 + (1 - a) * 14), SECONDARY, a * lock_a)

    # ---- beat 4: the product on a device (4.2 to 8.6 s)
    if 4.2 <= t < 8.7:
        dev_a = smooth(seg(t, 4.2, 4.9)) * (1 - smooth(seg(t, 8.1, 8.6)))
        cam = 0.955 + 0.045 * smooth(seg(t, 4.2, 8.3))
        sw, sh = int(1152 * cam), int(720 * cam)
        bez = int(16 * cam); cx, cy = 960, 468
        if t < 5.0: screen = cube[0]
        elif t < 5.55: screen = cube[min(59, round(bezier(0.4, 0, 0.2, 1, seg(t, 5.0, 5.55)) * 59))]
        elif t < 6.5: screen = cube[59]
        elif t < 7.05: screen = flip[min(59, round(bezier(0.4, 0, 0.2, 1, seg(t, 6.5, 7.05)) * 59))]
        else: screen = flip[59]
        glow(base, GLOW_V, (cx, cy + 60), sw * 1.5, 0.5 * dev_a)
        device = Image.new('RGBA', (sw + 2 * bez, sh + 2 * bez), (0, 0, 0, 0))
        dd = ImageDraw.Draw(device)
        dd.rounded_rectangle((0, 0, device.width - 1, device.height - 1), radius=int(30 * cam), fill=(24, 24, 30, 255), outline=(255, 255, 255, 36), width=2)
        device.alpha_composite(rounded(screen.resize((sw, sh), Image.LANCZOS), int(14 * cam)), (bez, bez))
        shadow = Image.new('RGBA', (device.width + 160, device.height + 160), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((80, 110, 80 + device.width, 110 + device.height), radius=40, fill=(0, 0, 0, 170))
        shadow = shadow.filter(ImageFilter.GaussianBlur(40))
        base.alpha_composite(with_alpha(shadow, dev_a), (int(cx - shadow.width / 2), int(cy - shadow.height / 2)))
        base.alpha_composite(with_alpha(device, dev_a), (int(cx - device.width / 2), int(cy - device.height / 2)))
        a = smooth(seg(t, 5.75, 6.35)) * dev_a
        text(base, 'Twelve transitions. Or none at all.', HEADLINE, (960, 985 + (1 - a) * 12), PRIMARY, a)

    # ---- beat 5: closing lockup (8.5 to 10.0 s)
    if t >= 8.5:
        a_icon = smooth(seg(t, 8.5, 9.05)); s = 230 * (0.9 + 0.1 * expo(seg(t, 8.5, 9.3)))
        glow(base, GLOW_V, (960, 400), s * 3.0, a_icon * 0.7)
        paste(base, icon, (960, 400), s, a_icon)
        a = smooth(seg(t, 8.75, 9.25)); text(base, WORD, WORD_SMALL, (960, 600 + (1 - a) * 16), PRIMARY, a)
        a = smooth(seg(t, 9.0, 9.45)); text(base, 'Free and open source, for macOS 26.', LINE, (960, 702 + (1 - a) * 12), SECONDARY, a)
        a = smooth(seg(t, 9.15, 9.6)); text(base, 'github.com/tornikegomareli/Spacewalk', MONO, (960, 775), MUTED, a)

    fade = 1 - smooth(seg(t, 9.65, 10.0))
    if fade < 1:
        black = Image.new('RGBA', (W, H), (10, 10, 14, int(255 * (1 - fade))))
        base.alpha_composite(black)
    return base.convert('RGB')

if __name__ == '__main__':
    for i in range(N):
        frame(i / FPS).save(f'{OUT}/f_{i:04d}.png')
        if i % 100 == 0: print('frame', i, flush=True)
    print('done', N)

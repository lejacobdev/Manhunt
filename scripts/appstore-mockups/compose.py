"""App Store mock-ups in the style of the 1.0 set: dark grey canvas, a wide-tracked title and a
subtitle in Quicksand, and the screenshot inside a drawn iPhone frame. 1284 x 2778 (6.5")."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = Path(__file__).parent
FONT = str(HERE / 'fonts' / 'Quicksand.ttf')
W, H = 1284, 2778
BG = (50, 50, 52)
SS = 2  # supersampling for smooth curves


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def tracked_width(draw, text, f, tracking):
    return sum(draw.textlength(ch, font=f) for ch in text) + tracking * (len(text) - 1)


def draw_tracked(draw, cx, y, text, f, tracking, fill):
    x = cx - tracked_width(draw, text, f, tracking) / 2
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + tracking


def fit_title(draw, text, max_w):
    size = 108
    while True:
        f = font(size, b'Bold')
        if tracked_width(draw, text, f, size * 0.16) <= max_w or size < 60:
            return f, size * 0.16
        size -= 2


def phone(shot: Image.Image, screen_w: int) -> Image.Image:
    """The screenshot inside an iPhone 17 Pro-like frame, at screen width `screen_w`."""
    shot = shot.convert('RGB')
    screen_h = round(screen_w * shot.height / shot.width)
    bezel, rim = 40, 9  # black bezel, then the metal rim
    pw, ph = screen_w + 2 * (bezel + rim), screen_h + 2 * (bezel + rim)
    s = SS
    img = Image.new('RGBA', (pw * s, ph * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    outer_r = 168
    # Metal rim: a light edge, then a darker band, like the titanium sides.
    d.rounded_rectangle([0, 0, pw * s - 1, ph * s - 1], radius=outer_r * s, fill=(150, 150, 154))
    d.rounded_rectangle([3 * s, 3 * s, (pw - 3) * s - 1, (ph - 3) * s - 1], radius=(outer_r - 3) * s, fill=(70, 70, 74))
    d.rounded_rectangle([rim * s, rim * s, (pw - rim) * s - 1, (ph - rim) * s - 1], radius=(outer_r - rim) * s, fill=(6, 6, 7))
    img = img.resize((pw, ph), Image.LANCZOS)

    # Screen, with its own rounded corners.
    screen_r = outer_r - rim - bezel + 12
    mask = Image.new('L', (screen_w * s, screen_h * s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen_w * s - 1, screen_h * s - 1], radius=screen_r * s, fill=255)
    mask = mask.resize((screen_w, screen_h), Image.LANCZOS)
    img.paste(shot.resize((screen_w, screen_h), Image.LANCZOS), (bezel + rim, bezel + rim), mask)

    # Dynamic Island, in real proportions (126 x 37 pt on a 402 pt-wide screen, 11 pt down).
    iw, ih, top = screen_w * 126 / 402, screen_w * 37 / 402, screen_w * 11 / 402
    isl = Image.new('RGBA', (int(iw * s), int(ih * s)), (0, 0, 0, 0))
    ImageDraw.Draw(isl).rounded_rectangle([0, 0, isl.width - 1, isl.height - 1], radius=isl.height // 2, fill=(0, 0, 0, 255))
    isl = isl.resize((int(iw), int(ih)), Image.LANCZOS)
    img.alpha_composite(isl, (int(bezel + rim + (screen_w - iw) / 2), int(bezel + rim + top)))

    # Side buttons, a few pixels proud of the frame.
    out = Image.new('RGBA', (pw + 16, ph), (0, 0, 0, 0))
    bd = ImageDraw.Draw(out)
    for (y0, y1) in [(0.17, 0.205), (0.245, 0.31), (0.33, 0.395)]:
        bd.rounded_rectangle([0, int(ph * y0), 14, int(ph * y1)], radius=5, fill=(96, 96, 100))
    bd.rounded_rectangle([pw + 2, int(ph * 0.27), pw + 15, int(ph * 0.37)], radius=5, fill=(96, 96, 100))
    out.alpha_composite(img, (8, 0))
    return out


def compose(shot_path, title, subtitle, out_path):
    canvas = Image.new('RGBA', (W, H), BG + (255,))
    d = ImageDraw.Draw(canvas)
    tf, tracking = fit_title(d, title, W - 120)
    draw_tracked(d, W / 2, 196, title, tf, tracking, (255, 255, 255))
    if subtitle:
        sf = font(70, b'SemiBold')
        while d.textlength(subtitle, font=sf) > W - 100:
            sf = font(sf.size - 2, b'SemiBold')
        d.text((W / 2, 368), subtitle, font=sf, fill=(255, 255, 255), anchor='mt')

    device = phone(Image.open(shot_path), 944)
    # Soft shadow under the phone, as on the originals.
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    x = (W - device.width) // 2
    y = 590
    shadow_mask = device.split()[3].point(lambda a: 110 if a else 0)
    shadow.paste((0, 0, 0, 255), (x, y + 18), shadow_mask)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    canvas.alpha_composite(device, (x, y))
    canvas.convert('RGB').save(out_path, optimize=True)


if __name__ == '__main__':
    compose(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '', sys.argv[4] if len(sys.argv) > 4 else 'out.png')

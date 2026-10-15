"""Genera le icone dei driver (disegni originali, nessun asset di terzi).

  drivers/controller/www/icons/icon_16.gif, icon_32.gif          sole stilizzato
  drivers/webview/www/icons/icon_16.gif, icon_32.gif             curva giornaliera con sole
  drivers/webview/www/icons/icon_70.png, icon_90.png, icon_300.png   icone del Navigator

Le icone vivono DENTRO www/ (vedi docs/ARCHITECTURE.md §5). Richiede Pillow.
Uso: python tools/generate_icons.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CONTROLLER_OUT = ROOT / "drivers" / "controller" / "www" / "icons"
WEBVIEW_OUT = ROOT / "drivers" / "webview" / "www" / "icons"
SS = 8  # supersampling per bordi lisci

SUN = (255, 200, 40, 255)
RAY = (245, 166, 35, 255)
BG = (29, 32, 38, 255)
GRID = (60, 66, 76, 255)
CCT = (110, 193, 255, 255)


def sun_layer(size):
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = big / 2
    r = big * 0.22
    ray_in, ray_out, w = big * 0.32, big * 0.46, max(2, int(big * 0.07))
    for i in range(8):
        a = math.radians(i * 45)
        d.line([(c + ray_in * math.cos(a), c + ray_in * math.sin(a)),
                (c + ray_out * math.cos(a), c + ray_out * math.sin(a))], fill=RAY, width=w)
    d.ellipse([c - r, c - r, c + r, c + r], fill=SUN)
    return img


def curve_layer(size):
    """Quadrato scuro arrotondato con la curva luminosita' del giorno e il sole sul picco."""
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.18, fill=BG)
    m = big * 0.12
    x0, x1 = m, big - m
    base = big * 0.78
    top = big * 0.24
    # base e griglia
    d.line([(x0, base), (x1, base)], fill=GRID, width=max(1, int(big * 0.012)))
    for k in range(1, 4):
        gx = x0 + (x1 - x0) * k / 4
        d.line([(gx, top * 0.7), (gx, base)], fill=GRID, width=max(1, int(big * 0.008)))
    # due curve: brightness (giallo) e CCT (azzurra), campana attorno al mezzogiorno
    for color, amp, shift, width in ((CCT, 0.62, 0.0, 0.020), (RAY, 1.0, 0.0, 0.030)):
        pts = []
        for i in range(61):
            u = i / 60
            y = base - (base - top) * amp * math.exp(-((u - 0.5 + shift) ** 2) / 0.045)
            pts.append((x0 + (x1 - x0) * u, y))
        d.line(pts, fill=color, width=max(2, int(big * width)), joint="curve")
    # sole sul picco
    cx, cy, r = (x0 + x1) / 2, top, big * 0.07
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=SUN)
    return img


def to_gif(img, size):
    small = img.resize((size, size), Image.LANCZOS)
    # GIF: trasparenza a 1 bit, palette da 255 colori + indice trasparente
    alpha = small.getchannel("A")
    pal = small.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=255)
    mask = alpha.point(lambda v: 255 if v < 128 else 0)
    pal.paste(255, mask)
    pal.info["transparency"] = 255
    return pal


def save_gif(layer_fn, out, sizes=(16, 32)):
    out.mkdir(parents=True, exist_ok=True)
    for s in sizes:
        to_gif(layer_fn(s), s).save(out / f"icon_{s}.gif", transparency=255)
        print("scritto", out / f"icon_{s}.gif")


def save_png(layer_fn, out, sizes=(70, 90, 300)):
    out.mkdir(parents=True, exist_ok=True)
    for s in sizes:
        layer_fn(s).resize((s, s), Image.LANCZOS).save(out / f"icon_{s}.png")
        print("scritto", out / f"icon_{s}.png")


if __name__ == "__main__":
    save_gif(sun_layer, CONTROLLER_OUT)
    save_gif(curve_layer, WEBVIEW_OUT)
    save_png(curve_layer, WEBVIEW_OUT)

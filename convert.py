#!/usr/bin/env python3
"""Convertisseur local : PDF / images → WebP, JPG, PNG, AVIF, et fusion en un seul PDF.

  convert.py ~/Dossier                    -> ~/Dossier_webp/ (même arborescence)
  convert.py doc.pdf photo.heic --to jpg  -> doc-p01.jpg…, photo.jpg à côté des originaux
  convert.py --merge a.pdf b.jpg Dossier/ -> Fusion.pdf (dans l'ordre donné)
"""
import argparse
import io
import json
import re
import sys
from pathlib import Path

import fitz  # PyMuPDF
from PIL import Image, ImageOps, ImageSequence
from pillow_heif import register_heif_opener

register_heif_opener()

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".gif", ".bmp", ".avif"}
SUPPORTED = IMAGE_EXTS | {".pdf"}
PIL_FORMAT = {"webp": "WEBP", "jpg": "JPEG", "png": "PNG", "avif": "AVIF"}
A4_WIDTH = 595.276  # points
JSON_MODE = False


def report(**event):
    if JSON_MODE:
        print(json.dumps(event, ensure_ascii=False), flush=True)
    elif event["type"] == "done":
        print(f"✓ {event['src']}")
    elif event["type"] == "error":
        print(f"✗ {event['src']} : {event['message']}", file=sys.stderr)
    elif event["type"] == "summary":
        if event["out"]:
            print(f"\n→ {event['out']}")
        print(event["message"])  # dernière ligne : reprise telle quelle par l'action rapide


def human_size(n: float) -> str:
    for unit in ("o", "Ko", "Mo", "Go"):
        if n < 1000 or unit == "Go":
            return f"{n:.0f} {unit}" if unit in ("o", "Ko") else f"{n:.1f} {unit}".replace(".", ",")
        n /= 1000


def natural_key(path: Path):
    """page2 avant page10."""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", str(path))]


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'s' if n > 1 else ''}"


def free_path(path: Path) -> Path:
    """Ne jamais écraser : ajoute (1), (2)... si le fichier existe."""
    candidate, n = path, 1
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} ({n}){path.suffix}")
        n += 1
    return candidate


def files_in(folder: Path) -> list:
    return sorted(
        (p for p in folder.rglob("*")
         if p.is_file() and p.suffix.lower() in SUPPORTED
         and not any(part.startswith(".") for part in p.relative_to(folder).parts)),
        key=natural_key,
    )


# ---------------------------------------------------------------- conversion

def prepare(img: Image.Image, fmt: str, max_width: int) -> Image.Image:
    img = ImageOps.exif_transpose(img)
    if max_width and img.width > max_width:
        img = img.resize((max_width, round(img.height * max_width / img.width)), Image.LANCZOS)
    if fmt == "jpg" and img.mode not in ("RGB", "L"):
        bg = Image.new("RGB", img.size, "white")
        img = img.convert("RGBA")
        bg.paste(img, mask=img.getchannel("A"))
        return bg
    if img.mode not in ("RGB", "RGBA", "L", "LA"):
        return img.convert("RGBA" if "A" in img.getbands() or img.mode == "P" else "RGB")
    return img


def save(img: Image.Image, dst: Path, fmt: str, quality: int, max_width: int) -> Path:
    # Les métadonnées (EXIF, GPS) ne sont volontairement pas recopiées.
    options = {"optimize": True} if fmt in ("png", "jpg") else {}
    if fmt != "png":
        options["quality"] = quality
    if fmt == "webp":
        options["method"] = 6

    if getattr(img, "is_animated", False) and fmt in ("webp", "avif"):
        frames = [prepare(f.copy(), fmt, max_width) for f in ImageSequence.Iterator(img)]
        options.update(save_all=True, append_images=frames[1:], loop=img.info.get("loop", 0),
                       duration=img.info.get("duration", 100))
        out = frames[0]
    else:
        out = prepare(img, fmt, max_width)

    dst = free_path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    out.save(dst, PIL_FORMAT[fmt], **options)
    return dst


def convert_file(src: Path, dst_base: Path, fmt: str, quality: int, max_width: int) -> list:
    """dst_base = chemin de sortie sans extension."""
    if src.suffix.lower() != ".pdf":
        with Image.open(src) as img:
            return [save(img, dst_base.with_suffix(f".{fmt}"), fmt, quality, max_width)]

    created = []
    with fitz.open(src) as doc:
        for i, page in enumerate(doc, 1):
            # Rendu à la largeur cible (ou 200 dpi si pas de limite) pour garder du détail.
            zoom = (max_width / page.rect.width) if max_width else 200 / 72
            pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            name = dst_base.name if len(doc) == 1 else f"{dst_base.name}-p{i:02d}"
            created.append(save(img, dst_base.with_name(name + f".{fmt}"), fmt, quality, max_width))
    return created


def run_convert(targets: list, fmt: str, quality: int, max_width: int):
    jobs, outs = [], []
    for target in targets:
        if target.is_dir():
            out = free_path(target.with_name(f"{target.name}_{fmt}"))
            outs.append(out)
            jobs += [(p, out / p.relative_to(target).with_suffix("")) for p in files_in(target)]
        else:
            outs.append(target.parent)
            jobs.append((target, target.with_suffix("")))

    report(type="start", total=len(jobs))
    ok = errors = before = after = 0
    for n, (src, dst_base) in enumerate(jobs, 1):
        try:
            created = convert_file(src, dst_base, fmt, quality, max_width)
            before += src.stat().st_size
            for dst in created:
                ok += 1
                after += dst.stat().st_size
                report(type="done", index=n, total=len(jobs), src=src.name, dst=str(dst))
        except Exception as e:  # un fichier cassé ne doit pas arrêter le lot
            errors += 1
            report(type="error", index=n, total=len(jobs), src=src.name, message=str(e))

    message = f"{plural(ok, 'fichier')} · {human_size(before)} → {human_size(after)}"
    if before and after < before:
        message += f" (−{round((1 - after / before) * 100)} %)"
    if errors:
        message += f" · {plural(errors, 'erreur')}"
    report(type="summary", ok=ok, errors=errors, message=message,
           out=str(outs[0]) if len(set(outs)) == 1 else "")
    return ok, errors


# ---------------------------------------------------------------- fusion

def image_page(doc: fitz.Document, src: Path):
    """Ajoute une image comme page au format largeur A4."""
    with Image.open(src) as img:
        img = ImageOps.exif_transpose(img)
        buf = io.BytesIO()
        if img.mode in ("RGBA", "LA", "P"):
            img.convert("RGBA").save(buf, "PNG")
        else:
            img.convert("RGB").save(buf, "JPEG", quality=92)
        w, h = img.size
    page = doc.new_page(width=A4_WIDTH, height=A4_WIDTH * h / w)
    page.insert_image(page.rect, stream=buf.getvalue())


def run_merge(targets: list, output: Path = None):
    files = []
    for target in targets:
        files += files_in(target) if target.is_dir() else [target]

    if output is None:
        first = targets[0]
        name = f"{first.name}.pdf" if len(targets) == 1 and first.is_dir() else "Fusion.pdf"
        output = first.parent / name
    output = free_path(output)

    report(type="start", total=len(files))
    doc = fitz.open()
    ok = errors = 0
    for n, src in enumerate(files, 1):
        try:
            if src.suffix.lower() == ".pdf":
                with fitz.open(src) as pdf:
                    doc.insert_pdf(pdf)
            else:
                image_page(doc, src)
            ok += 1
            report(type="done", index=n, total=len(files), src=src.name, dst=str(output))
        except Exception as e:
            errors += 1
            report(type="error", index=n, total=len(files), src=src.name, message=str(e))

    if doc.page_count:
        doc.save(output, garbage=3, deflate=True)
        message = (f"{plural(ok, 'fichier')} fusionné{'s' if ok > 1 else ''} → {output.name}"
                   f" · {plural(doc.page_count, 'page')}, {human_size(output.stat().st_size)}")
    else:
        output, message = "", "Rien à fusionner"
    if errors:
        message += f" · {plural(errors, 'erreur')}"
    report(type="summary", ok=ok, errors=errors, message=message, out=str(output))
    return ok, errors


# ---------------------------------------------------------------- CLI

def main():
    global JSON_MODE
    parser = argparse.ArgumentParser(description="Convertisseur local PDF / images → WebP, JPG, PNG, AVIF, ou fusion en PDF")
    parser.add_argument("paths", nargs="+", type=Path, help="fichiers ou dossiers")
    parser.add_argument("--to", choices=PIL_FORMAT, default="webp", help="format de sortie (défaut : webp)")
    parser.add_argument("-q", "--quality", type=int, default=82, help="qualité 1-100 (défaut : 82)")
    parser.add_argument("-w", "--max-width", type=int, default=1600, help="largeur max en px, 0 = taille d'origine (défaut : 1600)")
    parser.add_argument("--merge", action="store_true", help="fusionner PDF et images en un seul PDF, dans l'ordre donné")
    parser.add_argument("-o", "--output", type=Path, help="fichier PDF de sortie pour --merge")
    parser.add_argument("--json", action="store_true", help="progression en JSON (pour l'app)")
    args = parser.parse_args()
    JSON_MODE = args.json

    targets = []
    for target in args.paths:
        target = target.expanduser().resolve()
        if not target.exists():
            report(type="error", src=str(target), message="introuvable")
        elif target.is_file() and target.suffix.lower() not in SUPPORTED:
            report(type="error", src=target.name, message="format non pris en charge")
        else:
            targets.append(target)
    if not targets:
        report(type="summary", ok=0, errors=1, message="Aucun fichier pris en charge", out="")
        sys.exit(1)

    if args.merge:
        ok, errors = run_merge(targets, args.output.expanduser() if args.output else None)
    else:
        ok, errors = run_convert(targets, args.to, args.quality, args.max_width)
    sys.exit(1 if errors and not ok else 0)


if __name__ == "__main__":
    main()

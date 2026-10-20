#!/usr/bin/env python3
"""Convertisseur local : convertir, fusionner, compresser et découper des PDF et des images.

  convert.py ~/Dossier                    -> ~/Dossier_webp/ (même arborescence)
  convert.py doc.pdf photo.heic --to jpg  -> doc-p01.jpg…, photo.jpg à côté des originaux
  convert.py --merge a.pdf b.jpg Dossier/ -> Fusion.pdf (dans l'ordre donné)
  convert.py --compress medium doc.pdf    -> doc (compressé).pdf
  convert.py --split doc.pdf              -> doc_pages/doc-p01.pdf…
  convert.py --split --pages "1-3, 7" doc.pdf -> doc (p. 1-3, 7).pdf

Mot de passe des PDF protégés : variable d'environnement CONVERTISSEUR_PASSWORD.
"""
import argparse
import io
import json
import os
import re
import sys
from pathlib import Path

import fitz  # PyMuPDF
from PIL import Image, ImageOps, ImageSequence
from pillow_heif import register_heif_opener

register_heif_opener()
fitz.TOOLS.mupdf_display_errors(False)  # avertissements MuPDF sans gravité (PDF imparfaits)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".gif", ".bmp", ".avif"}
PDF_EXTS = {".pdf"}
SUPPORTED = IMAGE_EXTS | PDF_EXTS
PIL_FORMAT = {"webp": "WEBP", "jpg": "JPEG", "png": "PNG", "avif": "AVIF"}
# niveau -> (dpi cible des images, qualité JPEG)
COMPRESS_LEVELS = {"light": (150, 80), "medium": (120, 65), "strong": (90, 50)}
A4_WIDTH = 595.276  # points
JSON_MODE = False
OUT_DIR = None  # dossier de sortie choisi ; None = à côté des originaux


class Locked(Exception):
    def __init__(self):
        super().__init__("protégé par mot de passe")


class Skipped(Exception):
    """Fichier ignoré sans que ce soit une erreur (ex. PDF déjà optimisé)."""


def report(**event):
    if JSON_MODE:
        print(json.dumps(event, ensure_ascii=False), flush=True)
    elif event["type"] == "done":
        print(f"✓ {event['src']}")
    elif event["type"] in ("error", "skip"):
        print(f"{'✗' if event['type'] == 'error' else '–'} {event['src']} : {event['message']}", file=sys.stderr)
    elif event["type"] == "summary":
        if event["out"]:
            print(f"\n→ {event['out']}")
        print(event["message"])  # dernière ligne : reprise telle quelle par les actions rapides


def human_size(n: float) -> str:
    for unit in ("o", "Ko", "Mo", "Go"):
        if n < 1000 or unit == "Go":
            return f"{n:.0f} {unit}" if unit in ("o", "Ko") else f"{n:.1f} {unit}".replace(".", ",")
        n /= 1000


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'s' if n > 1 else ''}"


def natural_key(path: Path):
    """page2 avant page10."""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", str(path))]


def free_path(path: Path) -> Path:
    """Ne jamais écraser : ajoute (1), (2)... si le fichier existe."""
    candidate, n = path, 1
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} ({n}){path.suffix}")
        n += 1
    return candidate


def new_file(path: Path) -> Path:
    path = free_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def files_in(folder: Path, exts=SUPPORTED) -> list:
    return sorted(
        (p for p in folder.rglob("*")
         if p.is_file() and p.suffix.lower() in exts
         and not any(part.startswith(".") for part in p.relative_to(folder).parts)),
        key=natural_key,
    )


def open_pdf(path: Path) -> fitz.Document:
    doc = fitz.open(path)
    if doc.needs_pass and not doc.authenticate(os.environ.get("CONVERTISSEUR_PASSWORD", "")):
        doc.close()
        raise Locked()
    return doc


def save_pdf(doc: fitz.Document, dst: Path):
    # Le résultat n'est pas protégé, même si l'original l'était.
    doc.save(dst, garbage=4, deflate=True, clean=True, encryption=fitz.PDF_ENCRYPT_NONE)


# ---------------------------------------------------------------- lots (convertir, compresser, découper)

def plan(targets: list, suffix: str, exts) -> tuple:
    """Fichier -> sortie à côté (ou dans OUT_DIR) ; dossier -> <dossier>_<suffix>/ avec la même arborescence."""
    jobs, outs = [], []
    for target in targets:
        base = OUT_DIR or target.parent
        if target.is_dir():
            root = free_path(base / f"{target.name}_{suffix}")
            outs.append(root)
            jobs += [(p, root / p.relative_to(target).with_suffix("")) for p in files_in(target, exts)]
        elif target.suffix.lower() in exts:
            outs.append(base)
            jobs.append((target, base / target.stem))
        else:
            report(type="error", src=target.name, path=str(target), message="format non pris en charge ici")
    return jobs, outs


def run_jobs(jobs: list, outs: list, work, sizes=True):
    """work(src, dst_base) -> liste des fichiers créés."""
    report(type="start", total=len(jobs))
    ok = errors = skipped = locked = before = after = 0
    for n, (src, dst_base) in enumerate(jobs, 1):
        try:
            created = work(src, dst_base)
            before += src.stat().st_size
            for dst in created:
                ok += 1
                after += dst.stat().st_size
                report(type="done", index=n, total=len(jobs), src=src.name, dst=str(dst))
        except Skipped as e:
            skipped += 1
            report(type="skip", index=n, total=len(jobs), src=src.name, path=str(src), message=str(e))
        except Locked as e:
            locked += 1
            report(type="error", code="password", index=n, total=len(jobs), src=src.name, path=str(src), message=str(e))
        except Exception as e:  # un fichier cassé ne doit pas arrêter le lot
            errors += 1
            report(type="error", index=n, total=len(jobs), src=src.name, path=str(src), message=str(e))

    message = plural(ok, "fichier")
    if sizes and ok:
        message += f" · {human_size(before)} → {human_size(after)}"
        if before and after < before:
            message += f" (−{round((1 - after / before) * 100)} %)"
    elif not sizes:
        message += f" créé{'s' if ok > 1 else ''}"
    if skipped:
        message += f" · {skipped} ignoré{'s' if skipped > 1 else ''}"
    if locked:
        message += f" · {locked} protégé{'s' if locked > 1 else ''} par mot de passe"
    if errors:
        message += f" · {plural(errors, 'erreur')}"
    report(type="summary", ok=ok, errors=errors + locked, message=message,
           out=str(outs[0]) if len(set(outs)) == 1 else "")
    return ok, errors


# ---------------------------------------------------------------- convertir

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


def save_image(img: Image.Image, dst: Path, fmt: str, quality: int, max_width: int) -> Path:
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

    dst = new_file(dst)
    out.save(dst, PIL_FORMAT[fmt], **options)
    return dst


def convert_file(src: Path, dst_base: Path, fmt: str, quality: int, max_width: int) -> list:
    if src.suffix.lower() != ".pdf":
        with Image.open(src) as img:
            return [save_image(img, dst_base.with_suffix(f".{fmt}"), fmt, quality, max_width)]

    created = []
    with open_pdf(src) as doc:
        for i, page in enumerate(doc, 1):
            # Rendu à la largeur cible (ou 200 dpi si pas de limite) pour garder du détail.
            zoom = (max_width / page.rect.width) if max_width else 200 / 72
            pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            name = dst_base.name if len(doc) == 1 else f"{dst_base.name}-p{i:02d}"
            created.append(save_image(img, dst_base.with_name(name + f".{fmt}"), fmt, quality, max_width))
    return created


# ---------------------------------------------------------------- compresser

def shrink_images(doc: fitz.Document, dpi: int, quality: int):
    """Réduit chaque image à `dpi` (selon sa taille affichée) et la réencode en JPEG si c'est plus léger.
    Le texte et les dessins vectoriels ne sont pas touchés ; les images transparentes ou CMJN sont gardées telles quelles."""
    done = set()
    for page in doc:
        for xref, smask, *_ in page.get_images(full=True):
            if xref in done or smask:
                continue
            done.add(xref)
            rects = page.get_image_rects(xref)
            if not rects:
                continue
            raw = doc.extract_image(xref)
            try:
                img = Image.open(io.BytesIO(raw["image"]))
                img.load()
            except Exception:
                continue  # format d'image que Pillow ne lit pas (JBIG2…) : on le laisse
            if img.mode not in ("RGB", "L"):
                continue
            target = round(img.width * min(1, dpi * max(r.width for r in rects) / 72 / img.width))
            if target < img.width:
                img = img.resize((target, max(1, round(img.height * target / img.width))), Image.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=quality, optimize=True)
            if buf.tell() < len(raw["image"]) * 0.9:
                page.replace_image(xref, stream=buf.getvalue())


def compress_file(src: Path, dst_base: Path, level: str) -> list:
    with open_pdf(src) as doc:
        shrink_images(doc, *COMPRESS_LEVELS[level])
        dst = new_file(dst_base.with_name(f"{dst_base.name} (compressé).pdf"))
        save_pdf(doc, dst)
    if dst.stat().st_size >= src.stat().st_size * 0.97:
        dst.unlink()
        raise Skipped("déjà bien compressé, rien à gagner")
    return [dst]


# ---------------------------------------------------------------- découper

def parse_pages(spec: str, count: int) -> list:
    """« 1-3, 7, 10- » -> [0, 1, 2, 6, 9, …] (indices à partir de 0)."""
    pages = []
    for part in filter(None, (p.strip() for p in spec.replace(";", ",").split(","))):
        m = re.fullmatch(r"(\d*)\s*-\s*(\d*)|(\d+)", part)
        if not m:
            raise ValueError(f"« {part} » n'est pas une page valide (exemple : 1-3, 7)")
        if m.group(3):
            start = end = int(m.group(3))
        else:
            start, end = int(m.group(1) or 1), int(m.group(2) or count)
        if not (1 <= start <= end <= count):
            raise ValueError(f"pages « {part} » hors du document ({plural(count, 'page')})")
        pages += [p - 1 for p in range(start, end + 1) if p - 1 not in pages]
    if not pages:
        raise ValueError("aucune page indiquée")
    return pages


def split_file(src: Path, dst_base: Path, spec: str) -> list:
    with open_pdf(src) as doc:
        if spec:
            pages = parse_pages(spec, doc.page_count)
            label = re.sub(r"\s+", "", spec).replace(",", ", ")
            doc.select(pages)
            dst = new_file(dst_base.with_name(f"{dst_base.name} (p. {label}).pdf"))
            save_pdf(doc, dst)
            return [dst]

        folder = dst_base.with_name(f"{dst_base.name}_pages")
        created = []
        for i in range(doc.page_count):
            single = fitz.open()
            single.insert_pdf(doc, from_page=i, to_page=i)
            dst = new_file(folder / f"{dst_base.name}-p{i + 1:02d}.pdf")
            save_pdf(single, dst)
            created.append(dst)
        return created


# ---------------------------------------------------------------- fusionner

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
        output = (OUT_DIR or first.parent) / name

    report(type="start", total=len(files))
    doc = fitz.open()
    ok = errors = locked = 0
    for n, src in enumerate(files, 1):
        try:
            if src.suffix.lower() == ".pdf":
                with open_pdf(src) as pdf:
                    doc.insert_pdf(pdf)
            else:
                image_page(doc, src)
            ok += 1
            report(type="done", index=n, total=len(files), src=src.name, dst=str(output))
        except Locked as e:
            locked += 1
            report(type="error", code="password", index=n, total=len(files), src=src.name, path=str(src), message=str(e))
        except Exception as e:
            errors += 1
            report(type="error", index=n, total=len(files), src=src.name, path=str(src), message=str(e))

    if locked:
        # Pas de fusion incomplète : l'app redemande le mot de passe et relance tout.
        output, message = "", f"Fusion interrompue : {locked} PDF protégé{'s' if locked > 1 else ''} par mot de passe"
    elif doc.page_count:
        output = new_file(output)
        save_pdf(doc, output)
        message = (f"{plural(ok, 'fichier')} fusionné{'s' if ok > 1 else ''} → {output.name}"
                   f" · {plural(doc.page_count, 'page')}, {human_size(output.stat().st_size)}")
    else:
        output, message = "", "Rien à fusionner"
    if errors:
        message += f" · {plural(errors, 'erreur')}"
    report(type="summary", ok=ok, errors=errors + locked, message=message, out=str(output))
    return ok, errors


# ---------------------------------------------------------------- CLI

def main():
    global JSON_MODE, OUT_DIR
    parser = argparse.ArgumentParser(description="Convertisseur local : convertir, fusionner, compresser, découper")
    parser.add_argument("paths", nargs="+", type=Path, help="fichiers ou dossiers")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--merge", action="store_true", help="fusionner PDF et images en un seul PDF, dans l'ordre donné")
    mode.add_argument("--compress", choices=COMPRESS_LEVELS, help="compresser des PDF : light, medium ou strong")
    mode.add_argument("--split", action="store_true", help="découper des PDF (une page par fichier, ou --pages)")
    parser.add_argument("--to", choices=PIL_FORMAT, default="webp", help="format de sortie (défaut : webp)")
    parser.add_argument("-q", "--quality", type=int, default=82, help="qualité 1-100 (défaut : 82)")
    parser.add_argument("-w", "--max-width", type=int, default=1600, help="largeur max en px, 0 = taille d'origine (défaut : 1600)")
    parser.add_argument("--pages", default="", help="avec --split : pages à extraire, ex. « 1-3, 7 »")
    parser.add_argument("-o", "--output", type=Path, help="avec --merge : fichier PDF de sortie")
    parser.add_argument("--out-dir", type=Path, help="dossier où enregistrer les résultats (défaut : à côté des originaux)")
    parser.add_argument("--json", action="store_true", help="progression en JSON (pour l'app)")
    args = parser.parse_args()
    JSON_MODE = args.json
    if args.out_dir:
        OUT_DIR = args.out_dir.expanduser().resolve()
        OUT_DIR.mkdir(parents=True, exist_ok=True)

    targets = []
    for target in args.paths:
        target = target.expanduser().resolve()
        if not target.exists():
            report(type="error", src=str(target), path=str(target), message="introuvable")
        elif target.is_file() and target.suffix.lower() not in SUPPORTED:
            report(type="error", src=target.name, path=str(target), message="format non pris en charge")
        else:
            targets.append(target)
    if not targets:
        report(type="summary", ok=0, errors=1, message="Aucun fichier pris en charge", out="")
        sys.exit(1)

    if args.merge:
        ok, errors = run_merge(targets, args.output.expanduser() if args.output else None)
    elif args.compress:
        jobs, outs = plan(targets, "compressé", PDF_EXTS)
        ok, errors = run_jobs(jobs, outs, lambda s, d: compress_file(s, d, args.compress))
    elif args.split:
        jobs, outs = plan(targets, "découpé", PDF_EXTS)
        ok, errors = run_jobs(jobs, outs, lambda s, d: split_file(s, d, args.pages.strip()), sizes=False)
    else:
        jobs, outs = plan(targets, args.to, SUPPORTED)
        ok, errors = run_jobs(jobs, outs, lambda s, d: convert_file(s, d, args.to, args.quality, args.max_width))
    sys.exit(1 if errors and not ok else 0)  # errors inclut les PDF verrouillés


if __name__ == "__main__":
    main()

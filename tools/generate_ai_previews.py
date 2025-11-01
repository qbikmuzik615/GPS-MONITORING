#!/usr/bin/env python3
"""
generate_ai_previews.py
Production-ready, CI-friendly generator to index repo files, detect large/binary/LFS files,
produce ai-previews/ with ai-file-metadata.json, ai-file-metadata.ndjson, per-file previews,
and lightweight converted artifacts for common GPS formats.
Designed for GitHub Actions free-tier: idempotent, limited exports, robust error handling.
"""
import os, json, hashlib, subprocess, shlex, sys
from pathlib import Path
from datetime import datetime

ROOT = Path('.').resolve()
OUT = ROOT / 'ai-previews'
CONVERTED = OUT / 'converted'
PREVIEW = OUT / 'preview'

# Tunables (override via env)
MAX_PREVIEW_BYTES = int(os.getenv('MAX_PREVIEW_BYTES', '4096'))
BIG_FILE_THRESHOLD = int(os.getenv('BIG_FILE_THRESHOLD', str(1_048_576)))
PREVIEW_HEX_BYTES = int(os.getenv('PREVIEW_HEX_BYTES', '512'))
CSV_ROW_LIMIT = int(os.getenv('CSV_ROW_LIMIT', '100'))
LFS_FETCH_ENABLED = os.getenv('GIT_LFS_FETCH', 'false').lower() in ('1','true','yes')

def run(cmd, capture=True, check=False):
    p = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}\nstdout:{p.stdout}\nstderr:{p.stderr}")
    return p

def git_tracked_files():
    p = run('git ls-files -z')
    if p.returncode == 0 and p.stdout:
        return [f for f in p.stdout.split('\0') if f]
    # fallback: filesystem walk (ignore .git and ai-previews)
    files = []
    for root, dirs, filenames in os.walk('.'):  
        if root.startswith('./.git') or root.startswith('./ai-previews'):
            continue
        for fn in filenames:
            path = os.path.join(root, fn)
            if path.startswith('./'):
                path = path[2:]
            files.append(path)
    return files

def file_sha1(path:Path):
    h = hashlib.sha1()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()

def mime_type(path:Path):
    try:
        p = run(f"file --brief --mime-type {shlex.quote(str(path))}")
        if p.returncode == 0:
            return p.stdout.strip()
    except Exception:
        pass
    return 'unknown/unknown'

def is_lfs_pointer(path:Path):
    try:
        with open(path, 'r', errors='ignore') as fh:
            head = fh.read(4096)
            return 'version https://git-lfs.github.com/spec' in head
    except Exception:
        return False

def preview_text(path:Path):
    out = {}
    try:
        size = path.stat().st_size
        out['size'] = size
        with open(path, 'rb') as fh:
            chunk = fh.read(MAX_PREVIEW_BYTES)
        zeros = chunk.count(b'\x00')
        binary = (zeros > 0) or any(b > 127 for b in chunk[:200])
        if not binary:
            try:
                text = chunk.decode('utf-8', errors='replace')
            except Exception:
                text = chunk.decode('latin1', errors='replace')
            out['preview_text'] = text.splitlines(True)[:100]
        else:
            out['preview_hex'] = chunk[:PREVIEW_HEX_BYTES].hex()
    except Exception as e:
        out['preview_error'] = str(e)
    return out

def ensure_dirs():
    OUT.mkdir(exist_ok=True)
    CONVERTED.mkdir(parents=True, exist_ok=True)
    PREVIEW.mkdir(parents=True, exist_ok=True)

def convert_sqlite(path:Path, outdir:Path):
    try:
        p = run(f"sqlite3 {shlex.quote(str(path))} .tables")
        if p.returncode != 0:
            return {'error': 'sqlite-error', 'msg': p.stderr.strip()}
        tables = [t for t in p.stdout.strip().split() if t]
        exported = []
        for t in tables:
            safe_t = t.replace('"','').replace("'",'')
            csv_out = outdir / f"{path.name}__{safe_t}.csv"
            cmd = f"sqlite3 -header -csv {shlex.quote(str(path))} \"select * from '{safe_t}' limit {CSV_ROW_LIMIT};\" > {shlex.quote(str(csv_out))}"
            r = run(cmd)
            if r.returncode == 0:
                exported.append(str(csv_out))
        return {'tables': tables, 'exported': exported}
    except Exception as e:
        return {'error': 'exception', 'msg': str(e)}

def extract_mbtiles_metadata(path:Path, outdir:Path):
    try:
        txt = run(f"sqlite3 {shlex.quote(str(path))} \"select name, value from metadata;\"")
        if txt.returncode != 0:
            return {'error': 'mbtiles-sqlite-error', 'msg': txt.stderr.strip()}
        outf = outdir / f"{path.name}.metadata.txt"
        with open(outf, 'w', encoding='utf-8') as fh:
            fh.write(txt.stdout)
        return {'metadata': str(outf)}
    except Exception as e:
        return {'error': 'exception', 'msg': str(e)}

def convert_gpx_kml(path:Path, outdir:Path):
    try:
        outf = outdir / f"{path.name}.geojson"
        cmd = f"ogr2ogr -f GeoJSON {shlex.quote(str(outf))} {shlex.quote(str(path))}"
        r = run(cmd)
        if r.returncode == 0:
            return {'geojson': str(outf)}
        return {'error': 'ogr2ogr-failed', 'msg': r.stderr.strip()}
    except Exception as e:
        return {'error': 'exception', 'msg': str(e)}

def write_preview(path:Path, meta:dict):
    safe = path.as_posix().replace('/','__')
    outf = PREVIEW / f"{safe}.json"
    with open(outf, 'w', encoding='utf-8') as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    return outf

def maybe_fetch_lfs():
    if not LFS_FETCH_ENABLED:
        return
    try:
        run("git lfs version")
        run("git lfs pull --all")
    except Exception:
        pass

def main():
    ensure_dirs()
    if LFS_FETCH_ENABLED:
        maybe_fetch_lfs()
    files = git_tracked_files()
    metadata = []
    ndjson_lines = []
    for f in files:
        p = Path(f)
        try:
            st = p.stat()
        except Exception:
            continue
        entry = {
            'path': f,
            'size': st.st_size,
            'sha1': file_sha1(p),
            'mime': mime_type(p),
            'is_lfs_pointer': is_lfs_pointer(p),
            'scanned_at': datetime.utcnow().isoformat() + 'Z'
        }
        pv = preview_text(p)
        entry.update(pv)
        converted_info = {}
        lower = f.lower()
        if lower.endswith(('.db', '.sqlite')):
            outdir = CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted_info = convert_sqlite(p, outdir)
        elif lower.endswith('.mbtiles'):
            outdir = CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted_info = extract_mbtiles_metadata(p, outdir)
        elif lower.endswith(('.gpx', '.kml')):
            outdir = CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted_info = convert_gpx_kml(p, outdir)
        if converted_info:
            entry['converted'] = converted_info
        if entry.get('size', 0) > BIG_FILE_THRESHOLD and 'preview_text' in entry:
            entry['preview_text'] = entry['preview_text'][:50]
        write_preview(p, entry)
        metadata.append(entry)
        ndjson_lines.append(json.dumps(entry, ensure_ascii=False))
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / 'ai-file-metadata.json', 'w', encoding='utf-8') as fh:
        json.dump(metadata, fh, ensure_ascii=False, indent=2)
    with open(OUT / 'ai-file-metadata.ndjson', 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(ndjson_lines))
    print(f"Generated previews in {OUT} - {len(metadata)} files indexed.")

if __name__ == '__main__':
    main()

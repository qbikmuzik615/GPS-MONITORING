#!/usr/bin/env bash
# setup_ai_preview_automate.sh
# One-shot installer: creates AI preview generator, Action workflow, README,
# commits & pushes, optionally configures repo secrets via gh.
#
# Usage: From repo root run:
#   chmod +x setup_ai_preview_automate.sh
#   ./setup_ai_preview_automate.sh [--branch BRANCH] [--anthropic KEY] [--pat KEY] [--force-gh-install]
#
# Examples:
#   ./setup_ai_preview_automate.sh --branch main
#   ./setup_ai_preview_automate.sh --branch main --anthropic sk-XXX --pat ghp_XXX
#
set -euo pipefail

# Defaults
TARGET_BRANCH="${1:-}"
# We'll allow CLI flags parsing lightly
BRANCH="main"
ANTHROPIC_KEY=""
GITHUB_PAT=""
FORCE_GH_INSTALL=false

# Basic arg parse
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="$2"; shift 2;;
    --anthropic)
      ANTHROPIC_KEY="$2"; shift 2;;
    --pat)
      GITHUB_PAT="$2"; shift 2;;
    --force-gh-install)
      FORCE_GH_INSTALL=true; shift;;
    -h|--help)
      echo "Usage: $0 [--branch BRANCH] [--anthropic KEY] [--pat KEY] [--force-gh-install]"
      exit 0;;
    *)
      echo "Unknown arg: $1"; exit 1;;
  esac
done

echo "Target branch: $BRANCH"

# Verify repo root
if [ ! -d .git ]; then
  echo "ERROR: This must be run from the root of a git repository (your local clone)."; exit 1
fi

# Ensure we have a git remote
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$REMOTE_URL" ]; then
  echo "ERROR: No 'origin' remote found. Set remote and re-run."; exit 1
fi

# Prepare directories
mkdir -p tools .github/workflows

# Create generator script
cat > tools/generate_ai_previews.py <<'PY'
#!/usr/bin/env python3
"""
generate_ai_previews.py
Lightweight, CI-friendly generator of AI preview artifacts for repo ingestion.
Outputs:
  - ai-previews/ai-file-metadata.json (array)
  - ai-previews/ai-file-metadata.ndjson (ndjson)
  - ai-previews/preview/*.json (per-file previews)
  - ai-previews/converted/* (CSV, metadata, small GeoJSONs when possible)
Designed to be idempotent and safe on free-tier GitHub Actions.
"""
import os, json, hashlib, subprocess, shlex
from pathlib import Path
from datetime import datetime

ROOT = Path('.').resolve()
OUT = ROOT / 'ai-previews'
CONVERTED = OUT / 'converted'
PREVIEW = OUT / 'preview'

# tunables via env
MAX_PREVIEW_BYTES = int(os.getenv('MAX_PREVIEW_BYTES', 4096))
BIG_FILE_THRESHOLD = int(os.getenv('BIG_FILE_THRESHOLD', 1_048_576))
PREVIEW_HEX_BYTES = int(os.getenv('PREVIEW_HEX_BYTES', 512))
CSV_ROW_LIMIT = int(os.getenv('CSV_ROW_LIMIT', 100))
LFS_FETCH_ENABLED = os.getenv('GIT_LFS_FETCH', 'false').lower() in ('1','true','yes')

def run(cmd, capture=True):
    if capture:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    else:
        p = subprocess.run(cmd, shell=True)
    return p

def git_tracked_files():
    p = run('git ls-files -z')
    if p.returncode == 0:
        return [f for f in p.stdout.split('\0') if f]
    files=[]
    for root, dirs, fnames in os.walk('.'):
        if root.startswith('./.git') or root.startswith('./ai-previews'):
            continue
        for f in fnames:
            path = os.path.join(root, f)
            if path.startswith('./'): path = path[2:]
            files.append(path)
    return files

def file_sha1(path):
    h=hashlib.sha1()
    with open(path,'rb') as fh:
        while True:
            b=fh.read(8192)
            if not b: break
            h.update(b)
    return h.hexdigest()

def mime_type(path):
    try:
        p = run(f'file --brief --mime-type {shlex.quote(str(path))}')
        if p.returncode==0:
            return p.stdout.strip()
    except Exception:
        pass
    return 'unknown/unknown'

def is_lfs_pointer(path):
    try:
        with open(path,'r',errors='ignore') as fh:
            head=fh.read(4096)
            return 'version https://git-lfs.github.com/spec' in head
    except Exception:
        return False

def preview_text(path):
    out={}
    try:
        size=path.stat().st_size
        out['size']=size
        with open(path,'rb') as fh:
            chunk=fh.read(MAX_PREVIEW_BYTES)
        zeros=chunk.count(b'\x00')
        binary=(zeros>0) or any(b>127 for b in chunk[:200])
        if not binary:
            try:
                text=chunk.decode('utf-8',errors='replace')
            except:
                text=chunk.decode('latin1',errors='replace')
            out['preview_text']=text.splitlines(True)[:100]
        else:
            out['preview_hex']=chunk[:PREVIEW_HEX_BYTES].hex()
    except Exception as e:
        out['preview_error']=str(e)
    return out

def ensure_dirs():
    OUT.mkdir(exist_ok=True)
    CONVERTED.mkdir(parents=True, exist_ok=True)
    PREVIEW.mkdir(parents=True, exist_ok=True)

def convert_sqlite(path, outdir):
    try:
        p = run(f"sqlite3 {shlex.quote(str(path))} \".tables\"")
        if p.returncode!=0:
            return {'error':'sqlite-error','msg':p.stderr.strip()}
        tables=[t for t in p.stdout.strip().split() if t]
        exported=[]
        for t in tables:
            safe_t=t.replace('"','').replace("'",'')
            csv_out=outdir / f"{path.name}__{safe_t}.csv"
            cmd=f"sqlite3 -header -csv {shlex.quote(str(path))} \"select * from '{safe_t}' limit {CSV_ROW_LIMIT};\" > {shlex.quote(str(csv_out))}"
            r=run(cmd)
            if r.returncode==0:
                exported.append(str(csv_out))
        return {'tables':tables,'exported':exported}
    except Exception as e:
        return {'error':'exception','msg':str(e)}

def extract_mbtiles_metadata(path, outdir):
    try:
        txt = run(f"sqlite3 {shlex.quote(str(path))} \"select name, value from metadata;\"")
        if txt.returncode!=0:
            return {'error':'mbtiles-sqlite-error','msg':txt.stderr.strip()}
        outf = outdir / f"{path.name}.metadata.txt"
        with open(outf,'w',encoding='utf-8') as fh:
            fh.write(txt.stdout)
        return {'metadata':str(outf)}
    except Exception as e:
        return {'error':'exception','msg':str(e)}

def convert_gpx_kml(path, outdir):
    try:
        outf = outdir / f"{path.name}.geojson"
        cmd = f"ogr2ogr -f GeoJSON {shlex.quote(str(outf))} {shlex.quote(str(path))}"
        r = run(cmd)
        if r.returncode==0:
            return {'geojson':str(outf)}
        return {'error':'ogr2ogr-failed','msg':r.stderr.strip()}
    except Exception as e:
        return {'error':'exception','msg':str(e)}

def write_preview(path, meta):
    safe = path.replace('/','__')
    outf = PREVIEW / f"{safe}.json"
    with open(outf,'w',encoding='utf-8') as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    return outf

def maybe_fetch_lfs():
    if not LFS_FETCH_ENABLED: return
    try:
        run("git lfs version")
        run("git lfs pull --all")
    except Exception:
        pass

def main():
    ensure_dirs()
    if LFS_FETCH_ENABLED:
        maybe_fetch_lfs()
    files=git_tracked_files()
    metadata=[]
    ndjson=[]
    for f in files:
        p=Path(f)
        try:
            st=p.stat()
        except Exception:
            continue
        entry={
            'path':f,
            'size':st.st_size,
            'sha1':file_sha1(p),
            'mime':mime_type(p),
            'is_lfs_pointer':is_lfs_pointer(p),
            'scanned_at': datetime.utcnow().isoformat() + 'Z'
        }
        pv=preview_text(p)
        entry.update(pv)
        converted={}
        lower=f.lower()
        if lower.endswith(('.db','.sqlite')):
            outdir=CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted=convert_sqlite(p, outdir)
        elif lower.endswith('.mbtiles'):
            outdir=CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted=extract_mbtiles_metadata(p, outdir)
        elif lower.endswith(('.gpx','.kml')) :
            outdir=CONVERTED / p.name
            outdir.mkdir(parents=True, exist_ok=True)
            converted=convert_gpx_kml(p, outdir)
        if converted:
            entry['converted']=converted
        if entry.get('size',0) > BIG_FILE_THRESHOLD and 'preview_text' in entry:
            entry['preview_text']=entry['preview_text'][:50]
        write_preview(f, entry)
        metadata.append(entry)
        ndjson.append(json.dumps(entry, ensure_ascii=False))
    with open(OUT / 'ai-file-metadata.json','w',encoding='utf-8') as fh:
        json.dump(metadata, fh, ensure_ascii=False, indent=2)
    with open(OUT / 'ai-file-metadata.ndjson','w',encoding='utf-8') as fh:
        fh.write('\n'.join(ndjson))
    print(f"Generated previews in {OUT} - {len(metadata)} files indexed.")

if __name__=='__main__':
    main()
PY

# Create run_local wrapper
cat > tools/run_local.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --user --upgrade pip >/dev/null || true
python3 tools/generate_ai_previews.py
BASH

# Create README
cat > README_AI_PREVIEWS.md <<'MD'
AI Previews for Claude / Anthropic / MCP servers

Purpose:
- Provide AI-friendly metadata and small converted/preview artifacts so Claude/Anthropic or MCP search can index repository contents without fetching large binaries.

Where:
- ai-previews/
  - ai-file-metadata.json — array
  - ai-file-metadata.ndjson — newline-delimited for streaming ingestion
  - preview/*.json — per-file preview (text or hex excerpt)
  - converted/* — converted CSV/GeoJSON/metadata (limited exports)

How to use:
- Claude/Anthropic: ingest ai-file-metadata.ndjson (or upload the file to Anthropic Files). Use converted/ and preview/ for content retrieval.
- MCP servers: index ai-file-metadata.ndjson; use mime/size/sha1 fields for search and dedup.

Security:
- public repos: no secrets required.
- private repos: generate previews locally or configure workflows carefully to avoid exposing secrets in logs.
MD

# Create GitHub Action
cat > .github/workflows/generate-ai-previews.yml <<'YML'
name: Generate AI Previews (automated)

on:
  push:
    branches:
      - main
  schedule:
    - cron: '0 2 * * *'

jobs:
  generate:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install light deps
        run: |
          sudo apt-get update -y
          sudo apt-get install -y file sqlite3 zip
          python3 -m pip install --upgrade pip

      - name: Run generator
        run: |
          python3 tools/generate_ai_previews.py

      - name: Commit ai-previews branch
        env:
          GIT_AUTHOR_NAME: "ai-previews-bot"
          GIT_AUTHOR_EMAIL: "noreply@github"
        run: |
          git config user.name "$GIT_AUTHOR_NAME"
          git config user.email "$GIT_AUTHOR_EMAIL"
          if git rev-parse --verify ai-previews >/dev/null 2>&1; then
            git checkout ai-previews
          else
            git checkout -b ai-previews
          fi
          git add ai-previews || true
          if git diff --staged --quiet; then
            echo "No change to commit"
          else
            git commit -m "chore: update ai-previews (generated)"
            git push -u origin ai-previews --force
          fi

      - name: Create release asset (zip)
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          rm -f ai-previews.zip
          zip -r ai-previews.zip ai-previews || true
          if ! gh --version >/dev/null 2>&1; then
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            sudo apt-get update -y && sudo apt-get install -y gh
          fi
          gh auth setup-git
          TAG="ai-previews-latest"
          if gh release view $TAG >/dev/null 2>&1; then
            gh release upload $TAG ai-previews.zip --clobber || true
          else
            gh release create $TAG ai-previews.zip --title "AI Previews (latest)" --notes "Automated AI preview artifacts"
          fi

      - name: (Optional) Upload metadata to Anthropic files (for Claude)
        if: ${{ secrets.ANTHROPIC_API_KEY != '' }}
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          if [ -f ai-previews/ai-file-metadata.ndjson ]; then
            curl -s -X POST "https://api.anthropic.com/v1/files" \
              -H "x-api-key: $ANTHROPIC_API_KEY" \
              -F "purpose=training" \
              -F "file=@ai-previews/ai-file-metadata.ndjson" \
              | tee anthropic_upload.json
            cat anthropic_upload.json
          else
            echo "No ndjson metadata to upload"
          fi
YML

# Make executables
chmod +x tools/generate_ai_previews.py tools/run_local.sh

# Git add/commit/push
git add tools .github README_AI_PREVIEWS.md
git commit -m "chore: add automated AI preview generator and workflow" || echo "No changes to commit"
# Push to current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Pushing files to current branch: $CURRENT_BRANCH"
git push origin "$CURRENT_BRANCH"

# Optionally create PR if not main and user wants; we keep simple: push done.

# Install gh optionally and set secrets if provided
install_gh=false
if ! command -v gh >/dev/null 2>&1 || [ "$FORCE_GH_INSTALL" = true ]; then
  install_gh=true
fi

if [ "$install_gh" = true ]; then
  echo "Installing GitHub CLI (gh)..."
  # For Debian/Ubuntu runner; attempt generic install
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo apt-get update -y
    sudo apt-get install -y gh
  else
    echo "Please install GitHub CLI (gh) manually: https://cli.github.com/"
  fi
fi

# Authenticate gh if not already
if command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated. You will be prompted to authenticate via browser."
    gh auth login
  fi
  # Set repo context
  REPO_FULL="$(git remote get-url origin | sed -n 's#.*github.com[:/]\(.*\)\.git#\1#p')"
  if [ -z "$REPO_FULL" ]; then
    echo "Warning: couldn't parse repo owner/name from remote. Skipping secret set."
  else
    echo "Repo detected: $REPO_FULL"
    if [ -n "$GITHUB_PAT" ]; then
      echo "Setting repo secret GITHUB_PAT (for LFS fetch if needed)..."
      printf "%s" "$GITHUB_PAT" | gh secret set GITHUB_PAT -R "$REPO_FULL"
      echo "Set GITHUB_PAT"
    else
      echo "No GITHUB_PAT provided. To enable LFS fetch in Actions, run:"
      echo "  gh secret set GITHUB_PAT -R $REPO_FULL"
    fi
    if [ -n "$ANTHROPIC_KEY" ]; then
      echo "Setting repo secret ANTHROPIC_API_KEY..."
      printf "%s" "$ANTHROPIC_KEY" | gh secret set ANTHROPIC_API_KEY -R "$REPO_FULL"
      echo "Set ANTHROPIC_API_KEY"
    else
      echo "No ANTHROPIC_API_KEY provided. To enable Anthropic upload, run:"
      echo "  gh secret set ANTHROPIC_API_KEY -R $REPO_FULL"
    fi
  fi
else
  echo "gh CLI not available or not authenticated; skipping secret installation. You can install gh later and run:"
  echo "  gh auth login"
  echo "  gh secret set GITHUB_PAT -R owner/repo"
  echo "  gh secret set ANTHROPIC_API_KEY -R owner/repo"
fi

echo "Setup complete. Files added and pushed. The workflow is configured to run on push and daily schedule."
echo "If your default branch is not 'main', edit .github/workflows/generate-ai-previews.yml to change the branch, then commit & push."
echo "Action run URL (replace owner/repo): https://github.com/$(git remote get-url origin | sed -n 's#.*github.com[:/]\(.*\)\.git#\1#p')/actions"
echo "To run generator locally: ./tools/run_local.sh"

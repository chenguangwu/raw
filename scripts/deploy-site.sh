#!/usr/bin/env bash
# 一键完成：拆分 zip -> 提交推送 -> 合并内容并部署。
# 用法：
#   scripts/deploy-site.sh [zip路径] [--public] [--no-push] [--no-deploy]
# 说明见 AGENTS.md。
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${BRANCH:-main}"
GITHUB_LIMIT_BYTES=104857600
MAIN_ZIP="$REPO_ROOT/github-pages-main.zip"
ZHTW_ZIP="$REPO_ROOT/github-pages-zh-tw.zip"
SITE_NAME="${SITE_NAME:-ToolBox Online Tools}"
APP_TAGS="${APP_TAGS:-123,289,101}"
ACCESS_POLICY=""
PUSH=1
DEPLOY=1
ZIP_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --public) ACCESS_POLICY="public" ;;
    --no-push) PUSH=0 ;;
    --no-deploy) DEPLOY=0 ;;
    -h|--help)
      printf '%s\n' \
        "用法: scripts/deploy-site.sh [zip路径] [--public] [--no-push] [--no-deploy]" \
        "  zip路径      默认 ./github-pages.zip" \
        "  --public     站点设为所有人可见（默认仅自己可见）" \
        "  --no-push    只拆分并本地提交，不推送" \
        "  --no-deploy  只拆分并提交推送，不部署"
      exit 0
      ;;
    -*)
      echo "未知参数: $1" >&2
      exit 2
      ;;
    *)
      ZIP_PATH="$1"
      ;;
  esac
  shift
done

ZIP_PATH="${ZIP_PATH:-$REPO_ROOT/github-pages.zip}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

for bin in unzip zip tar node git; do
  command -v "$bin" >/dev/null 2>&1 || die "缺少命令: $bin"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-site.XXXXXX")"
PACK_DIR=""
cleanup() {
  [ -n "$PACK_DIR" ] && rm -rf "$PACK_DIR"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---------- 通用小工具 ----------
cat > "$TMP_DIR/jsonq.mjs" <<'EOF'
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => raw += c);
process.stdin.on('end', () => {
  const path = process.argv[2];
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    process.exit(2);
  }
  for (const part of path.split('.')) {
    if (value == null) break;
    value = value[part];
  }
  if (value === undefined || value === null) process.exit(3);
  process.stdout.write(typeof value === 'string' ? value : JSON.stringify(value));
});
EOF

cat > "$TMP_DIR/pick-site.mjs" <<'EOF'
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => raw += c);
process.stdin.on('end', () => {
  const marker = process.argv[2];
  const items = (JSON.parse(raw).data || {}).items || [];
  const hit = items.find(item => (item.description || '').includes(marker));
  if (hit) process.stdout.write(hit.deploy_target_id || '');
  else process.exit(4);
});
EOF

cat > "$TMP_DIR/has-active.mjs" <<'EOF'
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => raw += c);
process.stdin.on('end', () => {
  const items = (JSON.parse(raw).data || {}).items || [];
  const active = items.find(item => !item.ended_at);
  if (active) process.stdout.write(active.deployment_id || 'active');
});
EOF

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

# ---------- 1. 拆分 zip ----------
log "检查输入 zip: $ZIP_PATH"
[ -f "$ZIP_PATH" ] || die "找不到 zip: $ZIP_PATH"

RAW_DIR="$TMP_DIR/unzipped"
mkdir -p "$RAW_DIR"
unzip -q "$ZIP_PATH" -d "$RAW_DIR"

SITE_DIR="$TMP_DIR/site"
mkdir -p "$SITE_DIR"
if [ -f "$RAW_DIR/artifact.tar" ] && [ ! -f "$RAW_DIR/index.html" ]; then
  log "解包 artifact.tar"
  tar -xf "$RAW_DIR/artifact.tar" -C "$SITE_DIR"
else
  log "按普通站点 zip 处理"
  (cd "$RAW_DIR" && tar -cf - .) | (cd "$SITE_DIR" && tar -xf -)
fi

# 兼容站点被包在一层目录里的情况
if [ ! -f "$SITE_DIR/index.html" ]; then
  CANDIDATE="$(find "$SITE_DIR" -maxdepth 2 -name index.html -type f | head -1)"
  [ -n "$CANDIDATE" ] || die "zip 内未找到 index.html，无法确认站点根目录"
  SITE_DIR="$(dirname "$CANDIDATE")"
fi
[ -f "$SITE_DIR/index.html" ] || die "站点根目录缺少 index.html"
[ -f "$SITE_DIR/zh-tw/index.html" ] || die "站点缺少 zh-tw 目录，无法按约定拆分"

log "打包主包（排除 zh-tw）"
tar -cf "$TMP_DIR/main.tar" -C "$SITE_DIR" \
  --exclude=./zh-tw --exclude=__pycache__ --exclude=.DS_Store .
log "打包 zh-tw 包"
tar -cf "$TMP_DIR/zhtw.tar" -C "$SITE_DIR" \
  --exclude=__pycache__ --exclude=.DS_Store zh-tw

( cd "$TMP_DIR" && zip -q -X github-pages-main.zip main.tar && zip -q -X github-pages-zh-tw.zip zhtw.tar )

for pair in "$TMP_DIR/github-pages-main.zip:$MAIN_ZIP" "$TMP_DIR/github-pages-zh-tw.zip:$ZHTW_ZIP"; do
  src="${pair%%:*}"; dst="${pair#*:}"
  size="$(file_size "$src")"
  if [ "$size" -ge "$GITHUB_LIMIT_BYTES" ]; then
    die "$(basename "$dst") 为 $((size / 1048576)) MB，超过 GitHub 100 MB 单文件限制"
  fi
  mv -f "$src" "$dst"
  printf '    %s  %s MB\n' "$(basename "$dst")" "$((size / 1048576))"
done

# ---------- 2. 提交并推送 ----------
cd "$REPO_ROOT"
[ "$(git branch --show-current)" = "$BRANCH" ] || die "当前分支不是 $BRANCH"

# 源 zip 不应进入版本库
if git ls-files --error-unmatch github-pages.zip >/dev/null 2>&1; then
  log "从索引中移除 github-pages.zip（源包不入库）"
  git rm --cached -q github-pages.zip
fi

if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
  while read -r sha; do
    [ -n "$sha" ] || continue
    big="$(git ls-tree -r -l "$sha" | awk '$4 + 0 >= 104857600 { print $5; exit }')"
    if [ -n "$big" ]; then
      die "未推送提交 $sha 含超 100 MB 文件：$big。请先执行 git reset --mixed origin/$BRANCH 再重跑"
    fi
  done < <(git rev-list "origin/$BRANCH..HEAD")
fi

git add github-pages-main.zip github-pages-zh-tw.zip
if git diff --cached --quiet; then
  log "两个 zip 无变化，跳过提交"
else
  git commit -q -m "chore: update split github-pages archives ($(date '+%Y-%m-%d %H:%M'))"
  git log --oneline -1
fi

if [ "$PUSH" -eq 1 ]; then
  log "推送到 origin/$BRANCH"
  git push origin "$BRANCH"
else
  log "已跳过推送（--no-push）"
fi

if [ "$DEPLOY" -eq 0 ]; then
  log "已跳过部署（--no-deploy）"
  exit 0
fi

# ---------- 3. 合并内容并部署 ----------
CLI="$(ls -d "$HOME"/.trae-cn/plugins/trae-remote-official/deployment/*/skills/deployment/scripts/trae-deploy 2>/dev/null | sort -V | tail -1)"
[ -n "$CLI" ] || die "未找到 trae-deploy CLI，请确认 deployment 插件已安装"

PACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trae-pack.XXXXXX")"
log "打包站点为单文件数据包"

node - "$SITE_DIR" "$PACK_DIR" <<'EOF'
const fs = require('node:fs');
const path = require('node:path');
const [src, outDir] = process.argv.slice(2);
const index = {};
const out = fs.openSync(path.join(outDir, 'data.bin'), 'w');
let offset = 0;
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(full); continue; }
    if (!entry.isFile()) continue;
    const rel = '/' + path.relative(src, full).split(path.sep).join('/');
    const stat = fs.statSync(full);
    const buf = fs.readFileSync(full);
    fs.writeSync(out, buf, 0, buf.length, offset);
    index[rel] = [offset, buf.length, Math.trunc(stat.mtimeMs)];
    offset += buf.length;
  }
}
walk(src);
fs.closeSync(out);
fs.writeFileSync(path.join(outDir, 'index.json'), JSON.stringify(index));
console.log(`    文件 ${Object.keys(index).length} 个，数据 ${(offset / 1048576).toFixed(1)} MB`);
EOF

cat > "$PACK_DIR/server.mjs" <<'EOF'
import http from 'node:http';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('./', import.meta.url));
const index = JSON.parse(fs.readFileSync(root + 'index.json', 'utf8'));
const fd = fs.openSync(root + 'data.bin', 'r');

const mime = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json',
  '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8',
  '.gltf': 'model/gltf+json', '.glb': 'model/gltf-binary',
  '.bin': 'application/octet-stream', '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.avif': 'image/avif', '.ico': 'image/x-icon',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.mp3': 'audio/mpeg', '.ogg': 'audio/ogg', '.wav': 'audio/wav',
  '.mp4': 'video/mp4', '.webm': 'video/webm',
  '.pdf': 'application/pdf', '.zip': 'application/zip',
  '.csv': 'text/csv; charset=utf-8', '.md': 'text/markdown; charset=utf-8',
};

function resolveKey(pathname) {
  if (index[pathname]) return pathname;
  const candidates = pathname.endsWith('/')
    ? [pathname + 'index.html']
    : [pathname + '/index.html', pathname + '.html'];
  for (const candidate of candidates) {
    if (index[candidate]) return candidate;
  }
  return null;
}

function contentType(key) {
  const name = key.slice(key.lastIndexOf('/') + 1);
  const dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return mime[name.slice(dot).toLowerCase()] || 'application/octet-stream';
}

const server = http.createServer((request, response) => {
  if (!['GET', 'HEAD'].includes(request.method)) {
    response.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return;
  }
  try {
    const pathname = decodeURIComponent(request.url.split('?')[0]);
    if (pathname.includes('\0') || pathname.includes('\\')
        || pathname.split('/').some(part => part === '..')) {
      response.writeHead(403).end();
      return;
    }
    const key = resolveKey(pathname);
    if (!key) {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not Found');
      return;
    }
    const [offset, size, mtimeMs] = index[key];
    const etag = `"${size.toString(16)}-${mtimeMs.toString(16)}"`;
    const headers = {
      'Content-Type': contentType(key),
      'Cache-Control': 'public, max-age=0, must-revalidate',
      'X-Content-Type-Options': 'nosniff', 'Accept-Ranges': 'bytes',
      ETag: etag, 'Last-Modified': new Date(mtimeMs).toUTCString(),
    };
    if (request.headers['if-none-match'] === etag) {
      response.writeHead(304, headers).end();
      return;
    }
    let start = 0;
    let end = size - 1;
    let status = 200;
    const range = request.headers.range;
    if (range && (!request.headers['if-range'] || request.headers['if-range'] === etag)) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!match || (!match[1] && !match[2])) {
        response.writeHead(416, { 'Content-Range': `bytes */${size}` }).end();
        return;
      }
      if (!match[1]) start = Math.max(0, size - Number(match[2]));
      else {
        start = Number(match[1]);
        if (match[2]) end = Math.min(end, Number(match[2]));
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || end < 0) {
        response.writeHead(416, { 'Content-Range': `bytes */${size}` }).end();
        return;
      }
      status = 206;
      headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
    }
    headers['Content-Length'] = Math.max(0, end - start + 1);
    response.writeHead(status, headers);
    if (request.method === 'HEAD' || size === 0) {
      response.end();
      return;
    }
    const stream = fs.createReadStream(null, {
      fd, start: offset + start, end: offset + end, autoClose: false,
    });
    stream.on('error', () => response.destroy());
    stream.pipe(response);
  } catch (error) {
    response.writeHead(error instanceof URIError ? 400 : 500).end();
  }
});

server.listen(Number(process.env.PORT || 8000), '0.0.0.0', () => {
  console.log(`Packed static service listening on ${server.address().port}, ${Object.keys(index).length} files`);
});
EOF

cat > "$PACK_DIR/package.json" <<'EOF'
{
  "name": "toolbox-packed-static",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": { "start": "node server.mjs" }
}
EOF

printf '#!/bin/sh\nset -eu\nexec node server.mjs\n' > "$PACK_DIR/run.sh"
printf '#!/bin/sh\nset -eu\nmkdir -p dist\ncp server.mjs run.sh package.json index.json data.bin dist/\nchmod 755 dist/run.sh\n' > "$PACK_DIR/build.sh"
cat > "$PACK_DIR/execution-config.json" <<'EOF'
{
  "schema_version": 1,
  "build": {
    "runtime_key": "nodejs20",
    "build_script": "build.sh",
    "output_dir": "dist",
    "environment": {},
    "timeout_seconds": 3600
  },
  "runtime": {
    "runtime_key": "nodejs20",
    "start_script": "run.sh",
    "port": 8000,
    "environment": { "PORT": "8000" }
  }
}
EOF
chmod 755 "$PACK_DIR/run.sh" "$PACK_DIR/build.sh"

REMOTE_URL="$(git remote get-url origin)"
REPO_SLUG="$(printf '%s' "$REMOTE_URL" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
MARKER="Source: GitHub repo $REPO_SLUG"
DESC="$MARKER, application directory: repository root. Static multi-language ToolBox site assembled by merging github-pages-main.zip and github-pages-zh-tw.zip. Entrypoint: index.html."

log "查找已有站点"
SITE_ID="${SITE_ID:-}"
if [ -z "$SITE_ID" ] && git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
  SITE_ID="$(sh "$CLI" sites list 2>/dev/null | node "$TMP_DIR/pick-site.mjs" "$MARKER" || true)"
fi
if [ -z "$SITE_ID" ]; then
  log "未找到匹配站点，创建新站点"
  if [ "$ACCESS_POLICY" = "public" ]; then
    CREATE_OUT="$(sh "$CLI" sites create --name "$SITE_NAME" --description "$DESC" --access-policy public 2>/dev/null)"
  else
    CREATE_OUT="$(sh "$CLI" sites create --name "$SITE_NAME" --description "$DESC" 2>/dev/null)"
  fi
  SITE_ID="$(printf '%s' "$CREATE_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.deploy_target_id')" || die "创建站点失败: $CREATE_OUT"
else
  log "复用站点: $SITE_ID"
  if [ "$ACCESS_POLICY" = "public" ]; then
    sh "$CLI" sites update-config --site-id "$SITE_ID" --access-policy public >/dev/null 2>&1 || true
  fi
fi

ACTIVE="$(sh "$CLI" deployments list --site-id "$SITE_ID" 2>/dev/null | node "$TMP_DIR/has-active.mjs" || true)"
[ -z "$ACTIVE" ] || die "站点仍有进行中的部署 $ACTIVE，请等待或取消后重试"

TITLE="ToolBox 站点部署 $(date '+%Y-%m-%d %H:%M')"
DETAIL="Deploy merged site from github-pages-main.zip and github-pages-zh-tw.zip (repo $REPO_SLUG). Includes zh-tw locale, tools, guides and assets. Entrypoint: index.html."

log "创建部署"
CREATE_OUT="$(sh "$CLI" deployments create \
  --site-id "$SITE_ID" \
  --title "$TITLE" \
  --description "$DETAIL" \
  --type function-web \
  --source-dir "$PACK_DIR" \
  --execution-config "$PACK_DIR/execution-config.json" \
  --app-tags "$APP_TAGS" 2>/dev/null)" || die "创建部署失败"

DEPLOY_ID="$(printf '%s' "$CREATE_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.deployment_id')" || die "解析部署 ID 失败"
log "部署 ID: $DEPLOY_ID，等待完成"
WAIT_OUT=""
while :; do
  WAIT_OUT="$(sh "$CLI" deployments wait --deployment-id "$DEPLOY_ID" 2>/dev/null)" || break
  REASON="$(printf '%s' "$WAIT_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.wait_reason' 2>/dev/null || true)"
  # terminal 表示已结束；取不到 wait_reason 时退出循环，避免死等
  if [ "$REASON" = "terminal" ] || [ -z "$REASON" ]; then break; fi
done

STATUS="$(printf '%s' "$WAIT_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.deployment.status' 2>/dev/null || true)"
HOST="$(printf '%s' "$WAIT_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.deployment.resource_data.domain' 2>/dev/null || true)"
SHOT="$(printf '%s' "$WAIT_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.screenshot_refresh.status' 2>/dev/null || true)"

if [ "$STATUS" != "9" ]; then
  printf '%s\n' "$WAIT_OUT" | node "$TMP_DIR/jsonq.mjs" 'data.deployment.failure' 2>/dev/null || true
  die "部署未成功（status=$STATUS）"
fi

printf '\n部署成功\n  站点: %s\n  地址: https://%s\n  部署: %s\n  截图: %s\n' "$SITE_NAME" "$HOST" "$DEPLOY_ID" "${SHOT:-unknown}"

#!/usr/bin/env bash
# generate_manifest.sh — 扫 build/out/ 生成 manifest.json。
# AML 端拉远程 JRE 时下载这个文件,用 sha256 校验 tar.xz 完整性。
#
# 输入:
#   build/out/jre<major>-<arch>.tar.xz
#   build/deb-version.txt          (fetch 阶段写入)
# 输出:
#   build/out/manifest.json
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OUT="$BUILD/out"
DEB_VERSION="$(cat "$BUILD/deb-version.txt" 2>/dev/null || echo unknown)"

if [[ ! -d "$OUT" ]]; then
  echo "!! $OUT 不存在" >&2
  exit 1
fi

MANIFEST="$OUT/manifest.json"
TMP="$OUT/manifest.tmp.json"

# 用 jq 拼,没 jq 就用 awk 兜底
if command -v jq >/dev/null 2>&1; then
  entries=()
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    [[ "$name" == "manifest.json" || "$name" == "manifest.tmp.json" ]] && continue
    sha=$(shasum -a 256 "$f" | cut -d' ' -f1)
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
    major=$(echo "$name" | sed -nE 's/^jre([0-9]+)-.*/\1/p')
    arch=$(echo "$name" | sed -nE 's/^jre[0-9]+-(.+)\.tar\.xz$/\1/p')
    entries+=("{\"name\":\"$name\",\"major\":$major,\"arch\":\"$arch\",\"size\":$size,\"sha256\":\"$sha\",\"termux_version\":\"$DEB_VERSION\"}")
  done < <(find "$OUT" -name '*.tar.xz' -print0)

  join_arr=$(
    for i in "${!entries[@]}"; do
      printf '%s' "${entries[i]}"
      (( i < ${#entries[@]} - 1 )) && printf ','
    done
  )

  cat > "$MANIFEST" <<EOF
{
  "schema": 1,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "termux_version": "$DEB_VERSION",
  "files": [$join_arr]
}
EOF
  # 用 jq 重格式化
  jq . "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
else
  # 无 jq 的简单 fallback(GitHub Actions 一定有 jq,本地缺也能跑)
  python3 - "$OUT" "$DEB_VERSION" > "$MANIFEST" <<'PY'
import hashlib, json, os, sys, datetime
out_dir, deb_v = sys.argv[1], sys.argv[2]
files = []
for name in sorted(os.listdir(out_dir)):
    if not name.endswith('.tar.xz'): continue
    p = os.path.join(out_dir, name)
    sha = hashlib.sha256(open(p,'rb').read()).hexdigest()
    size = os.path.getsize(p)
    major = name.split('-')[0].replace('jre','')
    arch = name.replace('.tar.xz','').split('-',1)[1]
    files.append({"name":name,"major":int(major),"arch":arch,"size":size,"sha256":sha,"termux_version":deb_v})
print(json.dumps({"schema":1,"generated_at":datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),"termux_version":deb_v,"files":files},indent=2))
PY
fi

echo ">> manifest 生成: $MANIFEST"
cat "$MANIFEST"

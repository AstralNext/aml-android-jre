#!/usr/bin/env bash
# fetch_termux_jdk.sh — 从 Termux APT 仓库拉取 openjdk-$MAJOR 的 deb 并解出 JRE 树。
#
# 环境变量:
#   MAJOR  Java 主版本 (8 | 11 | 17 | 21 | 25)
#   ARCH   目标架构 (aarch64 | x86_64 | arm | i686)
#
# 产出:
#   build/deb/openjdk-${MAJOR}_${ARCH}.deb  原始 deb
#   build/extract/data.tar.xz               deb 解出的 data
#   build/extract/...                        data 解出的 Termux 文件树
#   build/termux-jvm/                        抽出的 JRE 根 (路径 Termux 原样)
#
set -euo pipefail

: "${MAJOR:?MAJOR is required (8|11|17|21|25)}"
: "${ARCH:?ARCH is required (aarch64|x86_64|arm|i686)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DEB_DIR="$BUILD/deb"
EXTRACT="$BUILD/extract"
JVM_OUT="$BUILD/termux-jvm"

mkdir -p "$DEB_DIR" "$EXTRACT"
rm -rf "$JVM_OUT"
mkdir -p "$JVM_OUT"

# ---- 1. 在 Termux 多个 suite 里找 openjdk-$MAJOR 的 deb ----------------------
# Termux 把 JDK 散布在 termux-main / termux-x11 / termux-root,逐个试。
REPOS=(
  "https://packages.termux.dev/apt/termux-main"
  "https://packages.termux.dev/apt/termux-x11"
  "https://packages.termux.dev/apt/termux-root"
)

DEB_URL=""
DEB_VERSION=""
for REPO in "${REPOS[@]}"; do
  PKG_URL="$REPO/dists/stable/main/binary-$ARCH/Packages.gz"
  echo ">> 拉取索引: $PKG_URL"
  if ! curl -fsS "$PKG_URL" -o "$EXTRACT/Packages.gz"; then
    continue
  fi
  gunzip -f "$EXTRACT/Packages.gz"
  # 列表里同一个 Package 名可能重复(gnupg 等),要按字段分段解析
  # 注意: 不能用 $0 ~ "^Package: " pkg "$" —— RS="" 段落模式下 $0 是整段
  # 多行记录,^...$ 锚定整段首尾,永远匹配不到多字段 stanza。
  # 改为逐字段精确匹配 Package: 行,命中后再取 Filename / Version。
  awk -v pkg="openjdk-$MAJOR" '
    BEGIN { RS=""; FS="\n" }
    {
      want = 0
      for (i = 1; i <= NF; i++) if ($i == "Package: " pkg) want = 1
      if (!want) next
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Filename:/) f = $i
        if ($i ~ /^Version:/)  v = $i
      }
      sub(/^Filename: /, "", f)
      sub(/^Version: /,  "", v)
      print f
      print v
      exit
    }
  ' "$EXTRACT/Packages" > "$EXTRACT/pkg-meta.txt"

  DEB_PATH="$(sed -n 1p "$EXTRACT/pkg-meta.txt" 2>/dev/null || true)"
  DEB_VERSION="$(sed -n 2p "$EXTRACT/pkg-meta.txt" 2>/dev/null || true)"
  if [[ -n "$DEB_PATH" ]]; then
    DEB_URL="$REPO/$DEB_PATH"
    break
  fi
done

if [[ -z "$DEB_URL" ]]; then
  echo "!! 未在 Termux 仓库找到 openjdk-$MAJOR ($ARCH)" >&2
  exit 1
fi
echo ">> 找到: $DEB_URL  (version: $DEB_VERSION)"

# ---- 2. 下载 deb ------------------------------------------------------------
DEB_FILE="$DEB_DIR/openjdk-${MAJOR}_${ARCH}.deb"
echo ">> 下载 deb → $DEB_FILE"
curl -fSL "$DEB_URL" -o "$DEB_FILE"

# ---- 3. 解 deb (ar x → data.tar.xz) -----------------------------------------
echo ">> 解 deb"
( cd "$EXTRACT" && ar x "$DEB_FILE" )

# ar 解出 control.tar.* 和 data.tar.*;数据可能压缩成 xz / gz / zst
DATA_TAR=""
for candidate in data.tar.xz data.tar.gz data.tar.zst data.tar; do
  if [[ -f "$EXTRACT/$candidate" ]]; then
    DATA_TAR="$EXTRACT/$candidate"
    break
  fi
done
: "${DATA_TAR:?data.tar not found in deb}"

case "$DATA_TAR" in
  *.xz)  ( cd "$EXTRACT" && xz -dc "$(basename "$DATA_TAR")" | tar -xf - ) ;;
  *.gz)  ( cd "$EXTRACT" && gzip -dc "$(basename "$DATA_TAR")" | tar -xf - ) ;;
  *.zst) ( cd "$EXTRACT" && zstd -dc "$(basename "$DATA_TAR")" | tar -xf - ) ;;
  *)     ( cd "$EXTRACT" && tar -xf "$(basename "$DATA_TAR")" ) ;;
esac

# ---- 4. 把 Termux 的 /data/data/com.termux/.../jvm/<pkg> 搬到 build/termux-jvm/
JVM_SRC="$EXTRACT/data/data/com.termux/files/usr/lib/jvm"
if [[ ! -d "$JVM_SRC" ]]; then
  echo "!! deb 内无 $JVM_SRC 路径" >&2
  exit 1
fi
# 多数情况下目录名是 openjdk-$MAJOR,但 JRE8 可能叫 openjdk-8 之类
JVM_DIR=$(find "$JVM_SRC" -mindepth 1 -maxdepth 1 -type d | head -1)
if [[ -z "$JVM_DIR" ]]; then
  echo "!! $JVM_SRC 下无 jvm 目录" >&2
  exit 1
fi
echo ">> 找到 JRE: $JVM_DIR"
cp -a "$JVM_DIR/." "$JVM_OUT/"

# 顺便把 deb 元信息保存下来,后续 normalize 要读 Version 字段
echo "$DEB_VERSION" > "$BUILD/deb-version.txt"
echo ">> fetch 完成,产物在 $JVM_OUT"

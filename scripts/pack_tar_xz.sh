#!/usr/bin/env bash
# pack_tar_xz.sh — 把 staging JRE 树打成 AML 期望的 ./ 前缀 tar.xz。
#
# 输入:
#   build/staging/   normalize 后的标准 JRE 根
# 环境变量:
#   MAJOR  Java 主版本
#   ARCH   架构 (aarch64 | x86_64 | arm | i686)
# 产出:
#   build/out/jre<major>-<arch>.tar.xz
#
# 注:tar 条目以 "./" 开头、无顶层目录,匹配 AML 的 extract_tar_xz_blocking
# (rust/src/api/java_download.rs:625) 剥离 ./ 前缀的逻辑。
#
set -euo pipefail

: "${MAJOR:?MAJOR is required}"
: "${ARCH:?ARCH is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/staging"
OUT="$BUILD/out"
mkdir -p "$OUT"

if [[ ! -d "$STAGE" ]]; then
  echo "!! $STAGE 不存在,请先跑 normalize_jre.sh" >&2
  exit 1
fi

# AML 校验关键文件:
#   lib/server/libjvm.so      (Java 17+,见 jre.rs:119)
#   lib/modules               (Java 9+,见 jre.rs:128)
# 缺一不可,先把关
if [[ ! -f "$STAGE/lib/server/libjvm.so" ]] && \
   [[ ! -f "$STAGE/lib/aarch64/server/libjvm.so" ]] && \
   [[ ! -f "$STAGE/lib/arm/server/libjvm.so" ]] && \
   [[ ! -f "$STAGE/lib/arm64/server/libjvm.so" ]] && \
   [[ ! -f "$STAGE/lib/aarch32/server/libjvm.so" ]]; then
  echo "!! 校验失败:libjvm.so 不存在" >&2
  exit 1
fi
# JRE8 用 lib/rt.jar,JRE9+ 用 lib/modules
if [[ "$MAJOR" == "8" ]]; then
  [[ -f "$STAGE/lib/rt.jar" ]] || { echo "!! JRE8 缺 lib/rt.jar" >&2; exit 1; }
else
  [[ -f "$STAGE/lib/modules" ]] || { echo "!! JRE$MAJOR 缺 lib/modules" >&2; exit 1; }
fi

OUT_FILE="$OUT/jre${MAJOR}-${ARCH}.tar.xz"
echo ">> 打包: $STAGE → $OUT_FILE"

# GNU tar 默认会让条目以 ./ 开头,匹配 AML 的 extract_tar_xz_blocking
# (rust/src/api/java_download.rs:625) 剥离 ./ 前缀的逻辑。
# --sort=name 让输出顺序稳定,有利于 reproducible build。
tar --create --xz \
    --file="$OUT_FILE" \
    --numeric-owner --owner=0 --group=0 \
    --sort=name \
    -C "$STAGE" .

# 校验产出
if [[ ! -s "$OUT_FILE" ]]; then
  echo "!! 打包后 $OUT_FILE 为空" >&2
  exit 1
fi

echo ">> pack 完成: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"

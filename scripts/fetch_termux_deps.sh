#!/usr/bin/env bash
# fetch_termux_deps.sh — 把 Termux 运行库注入 staging JRE。
#
# 为什么需要：17/21/25 的 JRE 来自 Termux prebuilt，其 .so 的 DT_NEEDED 指向
# Termux 自己的运行库，而这些库放在 Termux prefix 的 usr/lib 下、不在 JVM 目录里：
#   libjli.so / libzip.so            → libz.so.1（带 ZLIB_1.2.x 版本符号，
#                                      Android 系统的 libz.so 无版本符号，不能替代）
#   libjvm.so / libjava.so           → libandroid-spawn.so / libandroid-shmem.so
#   libjsound / libjavajpeg / liblcms → libasound.so / libjpeg.so.8 / liblcms2.so
#   libinstrument / libjdwp          → libiconv.so
# 缺任何一个，dlopen 阶段就会失败（AML 的 jre.rs / loader.rs 也按这套约定校验）。
#
# 本脚本扫描 staging 内所有 ELF 的 DT_NEEDED，取出 staging 未提供、也不是
# Android 系统库的 soname，从 Termux APT 仓库拉对应 deb，把库拷进 staging/lib，
# 并用 patchelf 补齐 SONAME —— Termux 的 libandroid-* 编译时没写 SONAME，
# 没有 SONAME 的库无法被别的库按 DT_NEEDED 名字命中（libjvm.so 的 RUNPATH
# 没有 $ORIGIN，全靠 AML 侧按 soname 预加载）。
#
# 环境变量：
#   MAJOR  Java 主版本
#   ARCH   目标架构（aarch64 | x86_64 | arm | i686）
#
# 产出：build/staging/lib/<soname>（就地补全依赖）
set -euo pipefail

: "${MAJOR:?MAJOR is required}"
: "${ARCH:?ARCH is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/staging"
DEPTREE="$BUILD/termux-deps"
DEB_DIR="$BUILD/deb"
INDEX="$BUILD/termux-deps-Packages"
REPO="https://packages.termux.dev/apt/termux-main"

if [[ ! -d "$STAGE" ]]; then
  echo "!! $STAGE 不存在：请先跑 normalize_jre.sh / build_openjdk_source.sh" >&2
  exit 1
fi

# ---- 工具 ------------------------------------------------------------------
READELF=""
for candidate in llvm-readelf readelf; do
  if command -v "$candidate" >/dev/null 2>&1; then
    READELF="$candidate"
    break
  fi
done
[[ -n "$READELF" ]] || {
  echo "!! 找不到 readelf / llvm-readelf" >&2
  exit 1
}
PATCHELF="$(command -v patchelf || true)"

# ---- 规则 ------------------------------------------------------------------
# 由 bionic / App 侧提供，不进 JRE 包。
SYSTEM_SONAMES=(
  libc.so
  libdl.so
  libm.so
  liblog.so
  libstdc++.so
  libandroid.so
  libEGL.so
  libGLESv2.so
  libvulkan.so
  libOpenSLES.so
  # Java 8 的 libfontmanager 要 freetype：由 App 的 GL4ES/LWJGL 桥提供，
  # 塞一份 JRE 自带的进去反而会和渲染链路里的那份打架（见 AML loader.rs）。
  libfreetype.so
)

# soname → Termux 包名。Termux 的库文件名与 JDK 的 DT_NEEDED 名字一致。
declare -A PACKAGE=(
  [libz.so.1]=zlib
  [libc++_shared.so]=libc++
  [libandroid-spawn.so]=libandroid-spawn
  [libandroid-shmem.so]=libandroid-shmem
  [libandroid-sysv-semaphore.so]=libandroid-sysv-semaphore
  [libiconv.so]=libiconv
  [libjpeg.so.8]=libjpeg-turbo
  [liblcms2.so]=littlecms
  [libasound.so]=alsa-lib
)

is_system() {
  local n="$1" s
  for s in "${SYSTEM_SONAMES[@]}"; do
    [[ "$s" == "$n" ]] && return 0
  done
  return 1
}

soname_of() {
  "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -1
}

needed_of() {
  "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p'
}

elf_files() {
  find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' \) -print0
}

# ---- Termux deb ------------------------------------------------------------
fetch_index() {
  [[ -s "$INDEX" ]] && return 0
  echo ">> 拉取 Termux 包索引（$ARCH）"
  curl -fsSL "$REPO/dists/stable/main/binary-$ARCH/Packages.gz" | gunzip > "$INDEX"
}

# 解出 deb 的数据到 $DEPTREE/$pkg/files（保留 Termux 原始路径）
extract_deb() {
  local pkg="$1" deb="$2" dir="$DEPTREE/$pkg"
  mkdir -p "$dir/files"
  local data=""
  if command -v ar >/dev/null 2>&1; then
    ( cd "$dir" && ar x "$deb" )
  else
    # bsdtar 能直接读 ar 归档（dev 机器上通常没有 binutils 的 ar）
    ( cd "$dir" && tar -xf "$deb" )
  fi
  data="$(find "$dir" -maxdepth 1 -name 'data.tar.*' | head -1)"
  [[ -n "$data" ]] || {
    echo "!! $deb 里没有 data.tar.*" >&2
    exit 1
  }
  case "$data" in
    *.xz) xz -dc "$data" | tar -xf - -C "$dir/files" ;;
    *.gz) gzip -dc "$data" | tar -xf - -C "$dir/files" ;;
    *.zst) zstd -dc "$data" | tar -xf - -C "$dir/files" ;;
    *) tar -xf "$data" -C "$dir/files" ;;
  esac
  touch "$dir/.extracted"
}

fetch_package() {
  local pkg="$1" dir="$DEPTREE/$pkg"
  [[ -f "$dir/.extracted" ]] && return 0
  fetch_index
  local fn ver deb
  read -r fn ver < <(awk -v pkg="$pkg" '
    BEGIN { RS=""; FS="\n" }
    {
      want = 0
      for (i = 1; i <= NF; i++) if ($i == "Package: " pkg) want = 1
      if (!want) next
      f = ""; v = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Filename:/) f = $i
        if ($i ~ /^Version:/)  v = $i
      }
      sub(/^Filename: /, "", f)
      sub(/^Version: /,  "", v)
      print f, v
      exit
    }
  ' "$INDEX") || true
  [[ -n "${fn:-}" ]] || {
    echo "!! Termux 仓库（$REPO）里没有包 $pkg" >&2
    exit 1
  }
  mkdir -p "$DEB_DIR"
  deb="$DEB_DIR/${pkg}_${ver:-unknown}_${ARCH}.deb"
  if [[ ! -f "$deb" ]]; then
    echo ">> 下载 $pkg ${ver:-} → $deb"
    curl -fsSL "$REPO/$fn" -o "$deb"
  fi
  extract_deb "$pkg" "$deb"
}

# 把一个 soname 注入 staging/lib
inject() {
  local soname="$1" pkg="${PACKAGE[$soname]:-}"
  if [[ -z "$pkg" ]]; then
    echo "!! 缺少 soname「$soname」的 Termux 包映射（见本脚本 PACKAGE 表）" >&2
    exit 1
  fi
  fetch_package "$pkg"

  local libdir src
  libdir="$(find "$DEPTREE/$pkg/files" -type d -path '*com.termux/files/usr/lib' | head -1)"
  [[ -n "$libdir" ]] || {
    echo "!! $pkg 里没有 usr/lib" >&2
    exit 1
  }
  src="$libdir/$soname"
  if [[ ! -f "$src" ]]; then
    # 文件名带版本号时按 SONAME 反查
    local f
    for f in "$libdir"/*.so*; do
      [[ -f "$f" ]] || continue
      if [[ "$(soname_of "$f")" == "$soname" ]]; then
        src="$f"
        break
      fi
    done
  fi
  [[ -f "$src" ]] || {
    echo "!! $pkg 里找不到 $soname" >&2
    exit 1
  }

  install -m 0644 "$src" "$STAGE/lib/$soname"

  local cur
  cur="$(soname_of "$STAGE/lib/$soname")"
  if [[ "$cur" != "$soname" ]]; then
    [[ -n "$PATCHELF" ]] || {
      echo "!! 需要 patchelf 给 $soname 补 SONAME（当前为「${cur:-无}」）" >&2
      exit 1
    }
    "$PATCHELF" --set-soname "$soname" "$STAGE/lib/$soname"
    echo ">> $soname: SONAME「${cur:-无}」→「$soname」"
  fi
  echo ">> 注入 $soname（$pkg）"
}

# ---- 主循环：直到 staging 的 DT_NEEDED 闭包全部解析 ------------------------
declare -A PROVIDED=()
declare -A ATTEMPTED=()

while :; do
  PROVIDED=()
  while IFS= read -r -d '' so; do
    PROVIDED["$(basename "$so")"]=1
    sn="$(soname_of "$so")"
    if [[ -n "$sn" ]]; then
      PROVIDED["$sn"]=1
    fi
  done < <(elf_files)

  missing=()
  while IFS= read -r -d '' so; do
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      [[ -n "${PROVIDED[$n]:-}" ]] && continue
      is_system "$n" && continue
      if [[ -n "${ATTEMPTED[$n]:-}" ]]; then
        echo "!! $n 注入后依然对不上（检查 SONAME 是否被保留）" >&2
        exit 1
      fi
      missing+=("$n")
    done < <(needed_of "$so")
  done < <(elf_files)

  [[ ${#missing[@]} -eq 0 ]] && break

  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  for n in "${missing[@]}"; do
    ATTEMPTED["$n"]=1
    inject "$n"
  done
done

# ---- 收尾校验：17+ 必须带齐 libz.so.1（AML 的 jre.rs 会按它判有效性）------
if [[ "$MAJOR" != "8" && ! -f "$STAGE/lib/libz.so.1" ]]; then
  echo "!! Java $MAJOR 的 staging 缺少 lib/libz.so.1" >&2
  exit 1
fi

echo ">> 依赖注入完成：staging 内所有 DT_NEEDED 均已解析（Java $MAJOR / $ARCH）"

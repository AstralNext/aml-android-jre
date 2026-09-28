#!/usr/bin/env bash
# normalize_jre.sh — 把 Termux 原生 JRE 树重整成 AML 期望的标准结构。
#
# 输入:
#   build/termux-jvm/          fetch_termux_jdk.sh 的产物
#   build/deb-version.txt      Termux deb 版本号 (e.g. "21.0.5-1")
# 环境变量:
#   MAJOR  Java 主版本
#   ARCH   架构 (aarch64 | x86_64 | arm | i686)
# 产出:
#   build/staging/             标准化后的 JRE 根
#       ├── bin/  conf/  lib/  legal/  release  ASSEMBLY_EXCEPTION  LICENSE
#
set -euo pipefail

: "${MAJOR:?MAJOR is required}"
: "${ARCH:?ARCH is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/termux-jvm"
STAGE="$BUILD/staging"
DEB_VERSION="$(cat "$BUILD/deb-version.txt" 2>/dev/null || echo unknown)"

rm -rf "$STAGE"
mkdir -p "$STAGE"

if [[ ! -d "$SRC" ]]; then
  echo "!! $SRC 不存在,请先跑 fetch_termux_jdk.sh" >&2
  exit 1
fi

# ---- 1. 直接全量拷过去,Termux 的 JRE 树已经基本是标准结构 ---------------
# Termux 安装路径是 /data/data/com.termux/files/usr/lib/jvm/openjdk-XX/,
# 内部 bin/ conf/ lib/ legal/ release 已经是 OpenJDK 标准布局,只是部分
# 路径在 release / java.properties 里被写成 Termux 的 prefix。
cp -a "$SRC/." "$STAGE/"

# 清掉 Termux 的 man / demo / src.zip 等无关产物(MC 跑起来用不到)
rm -rf "$STAGE/man" "$STAGE/demo" "$STAGE/sample" "$STAGE/src.zip" 2>/dev/null || true

# ---- 2. 修 release 文件:OS_ARCH / JAVA_HOME -------------------------------
# AML 的 probe_home (jre.rs:147) 读 JAVA_VERSION 和 OS_ARCH 两个字段。
# Termux deb 里的 OS_ARCH 字符串有时候是 "aarch64" 也有写成 "arm64" 的,
# 统一改成 aarch64/x86_64/arm/i686,跟 AML 的 has_jvm 校验 (jre.rs:120-123) 对齐。
OS_ARCH_NORMAL="$ARCH"
if [[ "$ARCH" == "i686" ]]; then OS_ARCH_NORMAL="x86"; fi
if [[ "$ARCH" == "arm" ]];   then OS_ARCH_NORMAL="aarch32"; fi

RELEASE="$STAGE/release"
# OpenJDK release 文件是 KEY="VALUE" 行格式,Termux 可能没有这文件,fallback 生成
if [[ ! -f "$RELEASE" ]]; then
  JAVA_META=$(awk -F= '/^JAVA_VERSION/ {print $2}' "$STAGE/lib/java.properties" 2>/dev/null \
              | tr -d '"' | head -1 || true)
  : "${JAVA_META:=${MAJOR}.0.0+termux}"
  cat > "$RELEASE" <<EOF
JAVA_VERSION="$JAVA_META"
OS_NAME="Linux"
OS_ARCH="$OS_ARCH_NORMAL"
OS_VERSION="2.11"
SOURCE=" .openjdk-temurin"
BUILD_SOURCE="termux"
BUILD_INFO="termux $DEB_VERSION"
EOF
else
  # 改写 OS_ARCH
  sed -i "s|^OS_ARCH=.*|OS_ARCH=\"$OS_ARCH_NORMAL\"|" "$RELEASE"
  # Termux 偶尔把 JAVA_HOME 写死进 release,删掉这种行
  sed -i '/^JAVA_HOME=/d' "$RELEASE"
fi

# ---- 3. JRE8 的 pack200 预解包 -------------------------------------------
# OpenJDK 8 的 rt.jar / tools.jar 等可能以 .pack 形式存在,AML 在打包前
# 必须展开成 .jar(java_download.rs:121 已注明这一点)。
# 优先用 JRE8 自带的 unpack200;没有则用宿主系统的(unpack200 在 host JDK8 / JDK17 都常见)。
if [[ "$MAJOR" == "8" ]]; then
  UNPACK200=""
  # 优先用 JRE8 自带的 unpack200,没有则用宿主系统的:
  #   - $JAVA_HOME8/bin/unpack200 (CI 注入的 OpenJDK 8)
  #   - /usr/lib/jvm/*/bin/unpack200 (Ubuntu 默认位置)
  #   - /opt/homebrew/opt/openjdk@8/bin/unpack200 (macOS Homebrew)
  for candidate in \
      "$STAGE/bin/unpack200" \
      "$STAGE/lib/unpack200" \
      "${JAVA_HOME8:-}/bin/unpack200" \
      /usr/lib/jvm/*/bin/unpack200 \
      /opt/homebrew/opt/openjdk@8/bin/unpack200; do
    if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
      UNPACK200="$candidate"
      break
    fi
  done
  if [[ -z "$UNPACK200" ]]; then
    echo "!! 找不到 unpack200,无法处理 JRE8 .pack 文件" >&2
    exit 1
  fi
  echo ">> 使用 unpack200: $UNPACK200"
  # JRE8 的 .pack 通常在 lib/<arch>/ 和 lib/ 下
  find "$STAGE/lib" -name "*.pack" -print0 | while IFS= read -r -d '' pack; do
    jar="${pack%.pack}.jar"
    "$UNPACK200" "$pack" "$jar"
    rm -f "$pack"
  done
fi

# ---- 3b. 裁剪: 只保留运行游戏所需的 JRE 内容 ------------------------------
# Termux 的 openjdk-XX 是完整 JDK(openjdk-17 安装后 ~213MB),原样打包会让
# AML 的内置资产膨胀到 ~320MB。AML 只做 JNI_CreateJavaVM + 跑 Minecraft:
#   bin/      开发工具(javac/jar/jshell/jlink/jmod/jdeps/jpackage/...) 用不到
#   include/  C 头文件
#   jmods/    jlink 用的模块包(Termux 若提供)
#   lib/      工具用归档 src.zip / jrt-fs.jar / ct.sym(javac --release 用)
# 注意别动 lib/jspawnhelper:HotSpot 的 ProcessBuilder 子进程要 exec 它。
rm -rf "$STAGE/include" "$STAGE/jmods" 2>/dev/null || true
if [[ -d "$STAGE/bin" ]]; then
  find "$STAGE/bin" -maxdepth 1 -type f ! -name java ! -name keytool -delete 2>/dev/null || true
fi
find "$STAGE/lib" -maxdepth 1 \
  \( -name 'src.zip' -o -name 'jrt-fs.jar' -o -name 'ct.sym' \) -delete 2>/dev/null || true

# ---- 4. 修正 bin/ 下可执行文件的权限位 (Termux deb 偶发丢 x) -------------
find "$STAGE/bin" -type f -exec chmod +x {} \; 2>/dev/null || true

# ---- 4b. strip 动态库 ------------------------------------------------------
# JRE8 走源码构建(build_openjdk_source.sh)时已经 strip;Termux deb 这条链路
# 之前漏了,调试符号白占体积。--strip-unneeded 只去掉链接不需要的符号表,
# 动态符号(JVM_* 这些 dlsym 目标)会保留。
STRIP_BIN=""
for candidate in llvm-strip strip aarch64-linux-gnu-strip; do
  if command -v "$candidate" >/dev/null 2>&1; then
    STRIP_BIN="$candidate"
    break
  fi
done
if [[ -n "$STRIP_BIN" ]]; then
  echo ">> strip 动态库: $STRIP_BIN"
  find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' \) \
    -exec "$STRIP_BIN" --strip-unneeded {} + 2>/dev/null || true
else
  echo ">> !! 未找到 strip 工具,体积会偏大" >&2
fi

# ---- 5. 修 lib/java.properties 里的 java.home 路径 -----------------------
# Termux 把 java.home 写死成 /data/data/com.termux/...,AML 用相对路径加载,
# 删掉这两行让它走运行时传入的 -Djava.home。
if [[ -f "$STAGE/lib/java.properties" ]]; then
  sed -i '/^java\.home=/d; /^java\.library\.path=/d' "$STAGE/lib/java.properties" 2>/dev/null || true
fi

echo ">> normalize 完成,产物在 $STAGE"

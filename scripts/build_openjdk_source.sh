#!/usr/bin/env bash
# build_openjdk_source.sh — 从源码交叉编译 OpenJDK 8 for Android (bionic)
#
# JRE 8 是矩阵里唯一从源码构建的版本(17/21/25 直接取 Termux prebuilt deb)。
# 参考 OpenJDK mobile/android 官方移植:
#   http://openjdk.java.net/projects/mobile/android.html
# bionic 适配 patch 取自上游 OpenJDK mobile/android 移植,经社区构建仓库分发。
#
# 环境变量:
#   MAJOR  固定 8
#   ARCH   固定 aarch64
#
# 产出:
#   build/staging/   标准化后的 JRE 根,直接对接 pack_tar_xz.sh
#
# 流程:
#   1. 下载 NDK r10e,构建 standalone toolchain
#   2. 交叉编译 freetype 2.10.0
#   3. 准备 cups 2.2.4 headers
#   4. clone jdk8u 源码
#   5. 应用 bionic 适配 patch
#   6. configure + make images
#   7. termux-elf-cleaner 清理 + strip
#   8. 重整成标准 JRE 结构 + pack200 预解包
#
set -euo pipefail

: "${MAJOR:?MAJOR is required}"
: "${ARCH:?ARCH is required}"
[[ "$MAJOR" == "8" ]] || { echo "!! build_openjdk_source.sh 仅支持 MAJOR=8,收到: $MAJOR" >&2; exit 1; }
[[ "$ARCH" == "aarch64" ]] || { echo "!! 仅支持 ARCH=aarch64 (NDK r10e 限制),收到: $ARCH" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/staging"
WORK="$BUILD/openjdk-build"

# ---- 配置常量 ----
NDK_VERSION=r10e
FREETYPE_VERSION=2.10.0
CUPS_VERSION=2.2.4
API=21                       # Android 5.0 (minSdk)
JOBS="$(nproc)"

# ---- 目标(固定 aarch64) ----
TARGET=aarch64-linux-android
TARGET_JDK=aarch64
TARGET_SHORT=arm64
JVM_VARIANTS=server
JVM_PLATFORM=linux

NDK="$WORK/android-ndk-$NDK_VERSION"
TOOLCHAIN="$NDK/generated-toolchains/android-${TARGET_SHORT}-toolchain"
ANDROID_INCLUDE="$TOOLCHAIN/sysroot/usr/include"

mkdir -p "$WORK"
cd "$WORK"

# =====================================================================
# 1. 下载并解压 NDK r10e
# =====================================================================
if [[ ! -d "$NDK" ]]; then
  NDK_ZIP="android-ndk-$NDK_VERSION-linux-x86_64.zip"
  echo ">> 下载 NDK $NDK_VERSION (~1GB)..."
  if [[ ! -f "$NDK_ZIP" ]]; then
    wget -q -O "$NDK_ZIP" \
      "https://dl.google.com/android/repository/$NDK_ZIP"
  fi
  unzip -q "$NDK_ZIP"
fi

# =====================================================================
# 2. 构建 standalone toolchain
# =====================================================================
# make-standalone-toolchain.sh 需要 ANDROID_NDK_ROOT 指向 NDK 根目录
export ANDROID_NDK_ROOT="$NDK"

if [[ ! -d "$TOOLCHAIN" ]]; then
  echo ">> 构建 standalone toolchain ($TARGET_SHORT, API=$API)..."
  "$NDK/build/tools/make-standalone-toolchain.sh" \
    --arch="$TARGET_SHORT" \
    --platform="android-$API" \
    --install-dir="$TOOLCHAIN"
fi

# 设置交叉编译环境
export PATH="$TOOLCHAIN/bin:$PATH"
export AR="$TOOLCHAIN/bin/$TARGET-ar"
export AS="$TOOLCHAIN/bin/$TARGET-as"
export CC="$TOOLCHAIN/bin/$TARGET-gcc"
export CXX="$TOOLCHAIN/bin/$TARGET-g++"
export LD="$TOOLCHAIN/bin/$TARGET-ld"
export OBJCOPY="$TOOLCHAIN/bin/$TARGET-objcopy"
export RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
export STRIP="$TOOLCHAIN/bin/$TARGET-strip"
export CPPFLAGS="-I$ANDROID_INCLUDE -I$ANDROID_INCLUDE/$TARGET"
export LDFLAGS="-L$NDK/platforms/android-$API/arch-$TARGET_SHORT/usr/lib"

# =====================================================================
# 3. 下载并交叉编译 freetype
# =====================================================================
FT="freetype-$FREETYPE_VERSION"
FT_PREFIX="$WORK/$FT/build_android-$TARGET_SHORT"

if [[ ! -d "$WORK/$FT" ]]; then
  echo ">> 下载 freetype $FREETYPE_VERSION..."
  wget -q -O "$FT.tar.gz" \
    "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/$FT.tar.gz" || \
  wget -q -O "$FT.tar.gz" \
    "https://download.savannah.gnu.org/releases/freetype/$FT.tar.gz"
  tar xf "$FT.tar.gz"
fi

if [[ ! -f "$FT_PREFIX/lib/libfreetype.a" ]]; then
  echo ">> 交叉编译 freetype..."
  cd "$WORK/$FT"
  ./configure \
    --host="$TARGET" \
    --prefix="$FT_PREFIX" \
    --without-zlib \
    --with-brotli=no \
    --with-png=no \
    --with-harfbuzz=no
  CFLAGS="-fno-rtti" CXXFLAGS="-fno-rtti" make -j"$JOBS"
  make install
  cd "$WORK"
fi

# =====================================================================
# 4. 准备 cups headers
# =====================================================================
CUPS="cups-$CUPS_VERSION"
if [[ ! -d "$WORK/$CUPS" ]]; then
  echo ">> 下载 cups $CUPS_VERSION headers..."
  wget -q -O "$CUPS.tar.gz" \
    "https://github.com/apple/cups/releases/download/v$CUPS_VERSION/$CUPS-source.tar.gz" || true
  if [[ -f "$CUPS.tar.gz" ]] && [[ -s "$CUPS.tar.gz" ]]; then
    tar xf "$CUPS.tar.gz"
  else
    # fallback: 用系统 cups headers
    echo ">> cups 源码下载失败,使用系统 libcups2-dev headers"
    mkdir -p "$WORK/$CUPS"
    ln -sf /usr/include/cups "$WORK/$CUPS/cups"
  fi
fi

# =====================================================================
# 5. clone OpenJDK 8 源码
# =====================================================================
OPENJDK="$WORK/openjdk"
if [[ ! -d "$OPENJDK/.git" ]]; then
  echo ">> clone jdk8u 源码..."
  git clone --depth 1 https://github.com/openjdk/jdk8u "$OPENJDK"
fi

# =====================================================================
# 6. 获取并应用 bionic 适配 patch
# =====================================================================
PATCHES="$WORK/patches"
mkdir -p "$PATCHES"

# patch 取自上游 OpenJDK mobile/android 移植,经社区构建仓库分发
PATCH_URL="https://raw.githubusercontent.com/FCL-Team/Android-OpenJDK-Build/Build_JRE_8/patches"

if [[ ! -s "$PATCHES/jdk8u_android.diff" ]]; then
  echo ">> 下载 jdk8u_android.diff (核心 bionic 适配)..."
  wget -q -O "$PATCHES/jdk8u_android.diff" "$PATCH_URL/jdk8u_android.diff"
fi
if [[ ! -s "$PATCHES/jdk8u_android_main.diff" ]]; then
  wget -q -O "$PATCHES/jdk8u_android_main.diff" "$PATCH_URL/jdk8u_android_main.diff"
fi

cd "$OPENJDK"
git reset --hard
echo ">> 应用 bionic 适配 patch..."
git apply --reject --whitespace=fix "$PATCHES/jdk8u_android.diff" || \
  echo "!! (预期) jdk8u_android.diff 部分应用失败,检查 .rej 文件"
git apply --reject --whitespace=fix "$PATCHES/jdk8u_android_main.diff" || \
  echo "!! jdk8u_android_main.diff 应用失败"
cd "$WORK"

# =====================================================================
# 7. 准备 X11/fontconfig headers + dummy libs
# =====================================================================
# OpenJDK makefile 会找 X11/fontconfig/cups headers,链接到 sysroot
ln -sf /usr/include/X11 "$ANDROID_INCLUDE/X11" 2>/dev/null || true
ln -sf /usr/include/fontconfig "$ANDROID_INCLUDE/fontconfig" 2>/dev/null || true
ln -sf "$WORK/$CUPS/cups" "$ANDROID_INCLUDE/cups" 2>/dev/null || true

# bionic 不需要 pthread/thread_db,但 OpenJDK makefile 会找,创建空 .a 占位
mkdir -p "$WORK/dummy_libs"
ar cru "$WORK/dummy_libs/libpthread.a" 2>/dev/null || true
ar cru "$WORK/dummy_libs/libthread_db.a" 2>/dev/null || true

# =====================================================================
# 8. configure
# =====================================================================
FT_LIB="$FT_PREFIX/lib"
FT_INC="$FT_PREFIX/include/freetype2"

# CFLAGS: JRE8 用 -D__ANDROID__ (社区实践)
CFLAGS_X="-DLE_STANDALONE -O3 -D__ANDROID__"
LDFLAGS_X="-L$WORK/dummy_libs"

# boot JDK: 用宿主 openjdk-8
BOOT_JDK=$(ls -d /usr/lib/jvm/java-8-openjdk-* 2>/dev/null | head -1 || true)
BOOT_ARG=()
[[ -n "$BOOT_JDK" ]] && BOOT_ARG=(--with-boot-jdk="$BOOT_JDK")

cd "$OPENJDK"

# 新版 jdk8u 加了 JDK-8360869 检测:GCC < 5 拒绝编译 aarch64 HotSpot,
# 但 NDK r10e aarch64 只有 gcc 4.9。仓库根 configure 是 wrapper,真正的
# 检查在 common/autoconf/generated-configure.sh,patch 那个文件才生效。
GEN_CONF="$OPENJDK/common/autoconf/generated-configure.sh"
if grep -q "broken aarch64 gcc 4.x" "$GEN_CONF" 2>/dev/null; then
  echo ">> 绕过 JDK-8360869 GCC<5 aarch64 检测..."
  # 替换成 no-op ':' 保持 if/fi 结构合法(直接删行会让 if...then 空体)
  sed -i 's|.*as_fn_error.*GCC < 5 may incorrectly compile HotSpot on aarch64.*|        :  # bypassed JDK-8360869 (NDK r10e gcc 4.9)|' "$GEN_CONF"
fi

echo ">> configure OpenJDK 8 (target=$TARGET, boot_jdk=${BOOT_JDK:-auto})..."

bash ./configure \
  --openjdk-target="$TARGET" \
  --with-extra-cflags="$CFLAGS_X" \
  --with-extra-cxxflags="$CFLAGS_X" \
  --with-extra-ldflags="$LDFLAGS_X" \
  --enable-option-checking=fatal \
  --with-jvm-variants="$JVM_VARIANTS" \
  --with-cups-include="$WORK/$CUPS" \
  --with-devkit="$TOOLCHAIN" \
  --with-debug-level=release \
  --with-fontconfig-include="$ANDROID_INCLUDE" \
  --with-freetype-lib="$FT_LIB" \
  --with-freetype-include="$FT_INC" \
  --x-includes="$ANDROID_INCLUDE/X11" \
  --x-libraries=/usr/lib \
  --with-jdk-variant=normal \
  "${BOOT_ARG[@]}" || {
  echo "!! configure 失败,config.log 中的 error 行:" >&2
  grep -E "^configure: error|as_fn_error" "$OPENJDK/config.log" 2>/dev/null | tail -30 >&2 || true
  echo "!! config.log 末尾 50 行:" >&2
  tail -50 "$OPENJDK/config.log" 2>/dev/null >&2 || true
  exit 1
}

# =====================================================================
# 9. make images
# =====================================================================
BUILD_DIR="$OPENJDK/build/${JVM_PLATFORM}-${TARGET_JDK}-normal-${JVM_VARIANTS}-release"
echo ">> make images (JOBS=$JOBS)... -> $BUILD_DIR"
cd "$BUILD_DIR"
make JOBS="$JOBS" images || {
  echo "!! 首次 make 失败,重试..."
  make JOBS="$JOBS" images
}
cd "$WORK"

# =====================================================================
# 10. 定位编译产物 (JRE8 -> images/j2re-image)
# =====================================================================
IMG="$BUILD_DIR/images/j2re-image"
if [[ ! -d "$IMG" ]]; then
  echo "!! 编译产物目录不存在: $IMG" >&2
  echo "   检查 $BUILD_DIR/images/ 下的内容:" >&2
  ls -la "$BUILD_DIR/images/" 2>/dev/null >&2 || true
  exit 1
fi
echo ">> 编译产物: $IMG"

# =====================================================================
# 11. termux-elf-cleaner: 清理 ELF 中 Android 不支持的 section
# =====================================================================
CLEANER="$WORK/termux-elf-cleaner"
if [[ ! -d "$CLEANER/.git" ]]; then
  git clone --depth 1 -b v2.2.0 \
    https://github.com/termux/termux-elf-cleaner "$CLEANER"
fi
if [[ ! -x "$CLEANER/termux-elf-cleaner" ]]; then
  cd "$CLEANER"
  autoreconf --install
  # cleaner 跑在宿主上清理目标 ELF,必须用宿主 gcc 编。但前面 export 的
  # CC/CXX/LDFLAGS 是 aarch64 交叉工具链,会让 configure 报
  # "cannot run C compiled programs"(编出 Android 二进制宿主跑不了)。
  # 用 env -u 剥掉交叉变量,让 configure 退回宿主默认 gcc。
  env -u CC -u CXX -u CPPFLAGS -u LDFLAGS -u CFLAGS -u CXXFLAGS \
      -u AR -u AS -u LD -u OBJCOPY -u RANLIB -u STRIP \
      bash configure
  env -u CC -u CXX -u CPPFLAGS -u LDFLAGS -u AR -u AS -u LD \
      -u OBJCOPY -u RANLIB -u STRIP \
      make CFLAGS=-D__ANDROID_API__=24
  cd "$WORK"
fi

echo ">> 清理 ELF (termux-elf-cleaner)..."
# 找出所有 ELF 文件,喂给 cleaner
find "$IMG" -type f -not -name "*.o" -print0 \
  | xargs -0 -r sh -c '
    for f; do
      case "$(head -c4 "$f" 2>/dev/null)" in
        ?ELF*) printf "%s\0" "$f";;
      esac
    done
  ' sh \
  | xargs -0 -r "$CLEANER/termux-elf-cleaner"

echo ">> strip .so..."
find "$IMG" -name "*.so" -execdir "$STRIP" {} \; 2>/dev/null || true

# =====================================================================
# 12. 重整到 staging (AML 期望的标准 JRE 结构)
# =====================================================================
echo ">> 重整到 $STAGE..."
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$IMG/." "$STAGE/"

# 删除无关产物
rm -rf "$STAGE/man" "$STAGE/demo" "$STAGE/sample" "$STAGE/src.zip" 2>/dev/null || true

# freetype: .so.6 -> .so (OpenJDK makefile 产出 .so.6)
find "$STAGE" -name "libfreetype.so.6" -execdir sh -c 'mv -f "$0" libfreetype.so' {} \; 2>/dev/null || true

# release 文件 (AML probe_home 读 JAVA_VERSION / OS_ARCH)
RELEASE="$STAGE/release"
if [[ ! -f "$RELEASE" ]]; then
  cat > "$RELEASE" <<EOF
JAVA_VERSION="$MAJOR"
OS_NAME="Linux"
OS_ARCH="aarch64"
OS_VERSION="2.11"
SOURCE=" .openjdk-$MAJOR"
BUILD_SOURCE="aml-android-jre"
BUILD_INFO="source-build"
EOF
else
  sed -i 's|^OS_ARCH=.*|OS_ARCH="aarch64"|' "$RELEASE"
  sed -i '/^JAVA_HOME=/d' "$RELEASE"
fi

# JRE8 pack200 预解包:rt.jar / tools.jar 等可能以 .pack 形式存在
UNPACK200=""
for cand in \
    "$STAGE/bin/unpack200" \
    "$STAGE/lib/unpack200" \
    "${JAVA_HOME8:-}/bin/unpack200" \
    /usr/lib/jvm/*/bin/unpack200; do
  if [[ -x "$cand" ]] || command -v "$cand" >/dev/null 2>&1; then
    UNPACK200="$cand"
    break
  fi
done
if [[ -n "$UNPACK200" ]]; then
  echo ">> pack200 解包: $UNPACK200"
  find "$STAGE/lib" -name "*.pack" -print0 | while IFS= read -r -d '' pack; do
    jar="${pack%.pack}.jar"
    "$UNPACK200" "$pack" "$jar"
    rm -f "$pack"
  done
else
  echo "!! 找不到 unpack200,JRE8 .pack 文件未解包" >&2
fi

# 修正 bin/ 权限
find "$STAGE/bin" -type f -exec chmod +x {} \; 2>/dev/null || true

# 清理 debug info 文件
find "$STAGE" -name "*.diz" -delete 2>/dev/null || true

echo ">> build_openjdk_source 完成,产物在 $STAGE"

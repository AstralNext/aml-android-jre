# aml-android-jre

为 [AML](https://github.com/keevin/AMLl) 的 Android 端打包 Bionic（aarch64）版 OpenJDK 运行时。
JRE 8 从 OpenJDK 源码交叉编译，17/21/25 取自 [Termux](https://termux.dev) 的 prebuilt openjdk deb。

## 产物

每次 release 产出 **4 个 tar.xz**（均为 aarch64，覆盖全部 Minecraft 版本）：

```
jre8-aarch64.tar.xz       # Minecraft 1.0 – 1.16.5
jre17-aarch64.tar.xz      # Minecraft 1.17 – 1.20.4
jre21-aarch64.tar.xz      # Minecraft 1.20.5 – 1.21.11
jre25-aarch64.tar.xz      # Minecraft 26.1+
```

外加一份 `manifest.json`，列出每个产物的 sha256 / size / version。AML 端拉远程 JRE 时用它校验。

### tar.xz 内部布局

条目以 `./` 开头，无顶层目录（符合 [AML `extract_tar_xz_blocking`](https://github.com/keevin/AMLl/blob/main/rust/src/api/java_download.rs) 的预期）：

```
./bin/java                ./bin/keytool           ...
./conf/security/...       ./lib/server/libjvm.so  ./lib/modules
./lib/java.properties     ./lib/tzdb.dat
./release                 ./ASSEMBLY_EXCEPTION     ./LICENSE
./legal/...
```

`release` 文件里 `OS_ARCH` 固定为 `aarch64`，不是 Termux 原值。

## 用法

### 本地复现
```bash
# 17/21/25: Termux deb
MAJOR=21 ARCH=aarch64 ./scripts/fetch_termux_jdk.sh
MAJOR=21 ARCH=aarch64 ./scripts/normalize_jre.sh
MAJOR=21 ARCH=aarch64 ./scripts/pack_tar_xz.sh

# 8: 源码交叉编译
MAJOR=8 ARCH=aarch64 ./scripts/build_openjdk_source.sh
MAJOR=8 ARCH=aarch64 ./scripts/pack_tar_xz.sh
```
脚本依次产出 `build/deb/`、`build/staging/`、`build/out/jre<major>-aarch64.tar.xz`。

### 触发 release
推一个 `vN` tag，GitHub Actions 跑全量构建，自动 publish release。
JRE8 走 Pack200 预解包（脚本内部处理）。

## 许可

OpenJDK 本身为 [GPL-2.0 + CPE](https://openjdk.org/legal/gplv2+ce.html)，
Termux 的构建保留同一许可。每个 tar.xz 内含 `legal/`、`ASSEMBLY_EXCEPTION`、`LICENSE`，
分发时不准 strip。本仓库自身脚本与 workflow 为 MIT。

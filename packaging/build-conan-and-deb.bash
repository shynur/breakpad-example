#!/usr/bin/env bash
#===============================================================================
# build-conan-and-deb.bash — 构建 Google Breakpad, 并打包为 Conan package 与
# Debian package (二者包含完全相同的安装目录, 布局见 AGENTS.md).
#
# 用法:
#   build-conan-and-deb.bash -t <breakpad tag> -b <build metadata> -o <输出目录>
#
# 产物 (ISA 后缀由构建机决定: x86_64→x64, aarch64→arm64):
#   <输出目录>/breakpad-<MY_BREAKPAD_VERSION>-<ISA>.deb
#   <输出目录>/breakpad-<MY_BREAKPAD_VERSION>-<ISA>.conan.tar.gz
# 其中 MY_BREAKPAD_VERSION = <tag 去掉前导 v>+<build metadata>,
# 例如 2024.02.16+201212311200.
#
# 直接在本机环境构建 (不借助 docker). 依赖:
#   git, make, tar, grep, ldd, dpkg-deb, conan (1.x, 如 1.57), C/C++ 编译器
#   (默认依次尝试 clang/clang-6.0/gcc, 可用 CC/CXX 环境变量覆盖),
#   以及编译 breakpad 所需的 libzstd 开发文件 (如 Ubuntu 的 libzstd-dev).
# conan 相关操作在隔离的临时 CONAN_USER_HOME 中进行, 不影响 ~/.conan.
#
# 安装目录布局 (configure --prefix=/opt/breakpad, 打包前经 DESTDIR 暂存):
#   bin/   core2md dump_syms minidump-2-core minidump_dump minidump_stackwalk
#          pid2md 等工具, 以及每个工具对应的 <name>.bash 启动脚本
#          (把安装前缀下的 lib/ 加入 LD_LIBRARY_PATH 后 exec 同名工具)
#   include/breakpad/
#   lib/   libbreakpad*.a, pkgconfig/breakpad-client.pc, 以及基础系统不保证
#          提供而 bin/ 工具需要的 .so (如 libzstd.so.1)
#
# Conan package 的使用 (JFrog Conan 1.x):
#   tar xf breakpad-<VERSION>-<ISA>.conan.tar.gz
#   cd breakpad-<VERSION>-<ISA>-conan
#   conan export-pkg . breakpad/<VERSION>@ -pf package
#===============================================================================
set -euo pipefail

usage() { sed -n '/^#====/,/^#====/p' "$0" | sed 's/^#//; s/^ //; 1d; $d'; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

#-------------------------------------------------------------------------------
# 参数
#-------------------------------------------------------------------------------
TAG='' BUILD_META='' OUT_DIR=''
while getopts 't:b:o:h' opt; do
    case "$opt" in
        t) TAG=$OPTARG ;;
        b) BUILD_META=$OPTARG ;;
        o) OUT_DIR=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
(($# == 0)) || { usage >&2; exit 2; }
[[ -n $TAG && -n $BUILD_META && -n $OUT_DIR ]] || { usage >&2; exit 2; }
[[ $BUILD_META =~ ^[0-9A-Za-z.-]+$ ]] || die "-b (build metadata) 含非法字符: '$BUILD_META'"

MY_BREAKPAD_VERSION="${TAG#v}+${BUILD_META}"
# 需同时满足 Debian upstream version (数字开头) 与 conan 1.x reference (字符集/长度)
[[ $MY_BREAKPAD_VERSION =~ ^[0-9][0-9A-Za-z.+-]{0,50}$ ]] \
    || die "MY_BREAKPAD_VERSION='$MY_BREAKPAD_VERSION' 不合法 (tag 部分只允许 [0-9A-Za-z.-], 且须以数字开头)"

case $(uname -m) in
    x86_64)        ISA_SUFFIX=x64;   DEB_ARCH=amd64 ;;
    aarch64|arm64) ISA_SUFFIX=arm64; DEB_ARCH=arm64 ;;
    *) die "不支持的机器架构: $(uname -m)" ;;
esac

#-------------------------------------------------------------------------------
# 依赖检查
#-------------------------------------------------------------------------------
pick() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { printf %s "$c"; return 0; }; done; return 1; }
: "${CC:=$(pick clang clang-6.0 gcc || true)}"
: "${CXX:=$(pick clang++ clang++-6.0 g++ || true)}"
[[ -n $CC && -n $CXX ]] || die "未找到 C/C++ 编译器 (可用 CC/CXX 环境变量指定)"
command -v "$CC"  >/dev/null 2>&1 || die "CC='$CC' 不可执行"
command -v "$CXX" >/dev/null 2>&1 || die "CXX='$CXX' 不可执行"
export CC CXX  # conan profile 探测编译器时 CC/CXX 优先级最高
for cmd in git make tar grep ldd dpkg-deb conan; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

run_logged() { # <日志名> <命令...>; 失败时回显日志尾部
    local name=$1; shift
    if ! "$@" >"$WORK/$name.log" 2>&1; then
        tail -n 50 "$WORK/$name.log" >&2 || true
        die "步骤 '$name' 失败 (以上为日志尾部)"
    fi
    echo "==> $name 完成"
}

echo "==> MY_BREAKPAD_VERSION = $MY_BREAKPAD_VERSION  (ISA: $ISA_SUFFIX)"
echo "==> CC=$CC  CXX=$CXX  JOBS=$JOBS"

#-------------------------------------------------------------------------------
# 获取源码 (breakpad 及其 DEPS 中钉住的 linux-syscall-support)
#-------------------------------------------------------------------------------
SRC=$WORK/src/breakpad
run_logged clone-breakpad git clone --depth 1 --branch "$TAG" https://github.com/google/breakpad "$SRC"
LSS_SNIPPET=$(grep -A5 -m1 'third_party/lss' "$SRC/DEPS") \
    || die "无法从 breakpad DEPS 解析 linux-syscall-support 的 commit"
LSS_REV=$(grep -oE -m1 '[0-9a-f]{40}' <<<"$LSS_SNIPPET" || true)
[[ -n $LSS_REV ]] || die "无法从 breakpad DEPS 解析 linux-syscall-support 的 commit"
run_logged clone-lss git clone https://chromium.googlesource.com/linux-syscall-support "$SRC/src/third_party/lss"
run_logged checkout-lss git -C "$SRC/src/third_party/lss" checkout "$LSS_REV"

#-------------------------------------------------------------------------------
# 构建并暂存安装 (prefix 直接写 /opt/breakpad, 使 .pc 等文件内容正确)
#-------------------------------------------------------------------------------
cd "$SRC"
run_logged configure ./configure --prefix=/opt/breakpad --enable-zstd "CC=$CC" "CXX=$CXX"
run_logged make make -j"$JOBS"
run_logged make-install make install DESTDIR="$WORK/dest"
STAGE=$WORK/dest/opt/breakpad

# 安装目录必须符合 AGENTS.md 约定的布局
for f in \
    bin/core2md bin/dump_syms bin/minidump-2-core bin/minidump_dump \
    bin/minidump_stackwalk bin/pid2md \
    include/breakpad/client/linux/handler/exception_handler.h \
    lib/libbreakpad_client.a lib/pkgconfig/breakpad-client.pc; do
    [[ -e $STAGE/$f ]] || die "安装目录缺少预期组件: $f"
done

#-------------------------------------------------------------------------------
# 安装目录后处理
#-------------------------------------------------------------------------------
# 1) 为每个可执行文件生成 <name>.bash 启动脚本
for prog in "$STAGE"/bin/*; do
    [[ -f $prog && -x $prog && $prog != *.bash ]] || continue
    cat >"$prog.bash" <<'EOF'
#!/usr/bin/env bash
# 由 packaging/build-conan-and-deb.bash 自动生成:
# 启动同目录下同名的 breakpad 工具, 并把安装前缀下的 lib/ 加入动态链接库查找路径.
set -e
[[ ${BASH_SOURCE[0]} == *.bash ]] || { echo "本脚本须以 <工具名>.bash 命名" >&2; exit 1; }
self=$(readlink -f -- "${BASH_SOURCE[0]}")  # 解析符号链接, 找到真实安装位置
bin_dir=$(cd -- "$(dirname -- "$self")" && pwd)
prefix=$(cd -- "$bin_dir/.." && pwd)
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "$bin_dir/$(basename -- "$self" .bash)" "$@"
EOF
    chmod +x "$prog.bash"
done

# 2) bin/ 工具依赖、而基础系统不保证提供的 .so —— 预期只有 libzstd
#    (libc/libm/libstdc++/libgcc_s/libz 等在任一目标 Ubuntu 上必有).
#    以 SONAME 为文件名拷入 lib/, 由 bin/*.bash 在运行时加入 LD_LIBRARY_PATH.
bundled=()
for prog in "$STAGE"/bin/*; do
    [[ -f $prog && -x $prog && $prog != *.bash ]] || continue
    while read -r soname libpath; do
        case $soname in
            libzstd.so.*) ;;
            *) continue ;;
        esac
        cp -L "$libpath" "$STAGE/lib/$soname"
        bundled+=("$soname")
    done < <(ldd "$prog" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}')
done
# --enable-zstd 必须真实生效 (至少有工具链接 libzstd)
((${#bundled[@]})) || die "--enable-zstd 未生效: bin/ 下没有二进制链接 libzstd"
echo "==> 已捆绑进 lib/ 的 .so: $(printf '%s\n' "${bundled[@]}" | sort -u | tr '\n' ' ')"
# 捆绑后, 所有工具的运行时依赖必须全部可解析
for prog in "$STAGE"/bin/*; do
    [[ -f $prog && -x $prog && $prog != *.bash ]] || continue
    missing=$(LD_LIBRARY_PATH="$STAGE/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        ldd "$prog" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ' || true)
    [[ -z $missing ]] || die "$(basename "$prog") 存在未解析的动态库: $missing"
done

#-------------------------------------------------------------------------------
# Debian package (安装到 /opt/breakpad)
#-------------------------------------------------------------------------------
DEB_ROOT=$WORK/deb
mkdir -p "$DEB_ROOT/opt"
cp -a "$STAGE" "$DEB_ROOT/opt/breakpad"
mkdir -p "$DEB_ROOT/DEBIAN"
cat >"$DEB_ROOT/DEBIAN/control" <<EOF
Package: breakpad
Version: $MY_BREAKPAD_VERSION
Architecture: $DEB_ARCH
Maintainer: shynur <shynur@users.noreply.github.com>
Installed-Size: $(du -sk "$DEB_ROOT/opt/breakpad" | cut -f1)
Depends: libc6 (>= 2.27), libstdc++6 (>= 7), zlib1g
Section: devel
Priority: optional
Homepage: https://github.com/google/breakpad
Description: Google Breakpad crash-reporting tools and client library (zstd enabled)
 Breakpad client library (headers, static library, pkg-config file) and tools
 (core2md, dump_syms, minidump-2-core, minidump_dump, minidump_stackwalk,
 pid2md), installed under /opt/breakpad.  Built from tag $TAG with
 --enable-zstd; 运行工具所需的额外 .so 已捆绑进 /opt/breakpad/lib,
 /opt/breakpad/bin/ 下每个工具均有同名 .bash 启动脚本负责设置
 LD_LIBRARY_PATH.
EOF
dpkg_opts=()
[[ $(dpkg-deb --help 2>&1) == *--root-owner-group* ]] && dpkg_opts+=(--root-owner-group)
ART_OUT=$WORK/out  # 产物先落在临时目录, 全部成功后再 mv 进输出目录
mkdir -p "$ART_OUT"
DEB_FILE=$ART_OUT/breakpad-$MY_BREAKPAD_VERSION-$ISA_SUFFIX.deb
dpkg-deb "${dpkg_opts[@]}" --build "$DEB_ROOT" "$DEB_FILE"

#-------------------------------------------------------------------------------
# Conan package (与 Debian package 共用同一安装目录)
#-------------------------------------------------------------------------------
CONAN_DIR=$WORK/conan
mkdir -p "$CONAN_DIR"
cp -a "$STAGE" "$CONAN_DIR/package"
cat >"$CONAN_DIR/conanfile.py" <<'EOF'
import os

from conans import ConanFile


class BreakpadConan(ConanFile):
    name = "breakpad"
    # version 由打包脚本通过命令行 `conan create <path> breakpad/<version>@` 提供.
    description = "Google Breakpad crash-reporting tools and client library (prebuilt, zstd enabled)"
    url = "https://github.com/shynur/breakpad-example"
    homepage = "https://github.com/google/breakpad"
    license = "BSD-3-Clause"
    settings = "os", "arch", "compiler", "build_type"
    exports_sources = "package/*"

    def package_id(self):
        # 预编译包: 同一份二进制面向各种 compiler/build_type 的消费者
        # (以 Ubuntu 18.04 + libstdc++-7 构建, 兼容更新的工具链运行时).
        del self.info.settings.compiler
        del self.info.settings.build_type

    def package(self):
        self.copy("*", src=os.path.join(self.source_folder, "package"),
                  dst="", keep_path=True)

    def package_info(self):
        # 头文件同时支持 "breakpad/client/linux/..." 与
        # "client/linux/..." (同 breakpad-client.pc 一致) 两种包含方式.
        self.cpp_info.includedirs = ["include", "include/breakpad"]
        self.cpp_info.libs = ["breakpad_client"]
        if self.settings.os == "Linux":
            self.cpp_info.system_libs = ["pthread"]
EOF
# 在隔离的 conan home 中实际创建一次, 验证 recipe 可用且 package 能生成
# (不碰用户 ~/.conan; $WORK 退出时由 trap 清理). 编译器依据已 export 的
# CC/CXX 探测; libcxx 修正为 libstdc++11 (libstdc++ >= 5.1 的实际默认 ABI).
export CONAN_USER_HOME=$WORK/conan-home
conan profile new default --detect --force >/dev/null
conan profile get settings.compiler default >/dev/null 2>&1 \
    || die "conan 未能依据 CC=$CC/CXX=$CXX 探测到编译器"
conan profile update settings.compiler.libcxx=libstdc++11 default >/dev/null
conan create "$CONAN_DIR" "breakpad/$MY_BREAKPAD_VERSION@"

ART_DIR=$WORK/artifact/breakpad-$MY_BREAKPAD_VERSION-$ISA_SUFFIX-conan
mkdir -p "$ART_DIR"
cp "$CONAN_DIR/conanfile.py" "$ART_DIR/"
cp -a "$CONAN_DIR/package" "$ART_DIR/"
CONAN_FILE=$ART_OUT/breakpad-$MY_BREAKPAD_VERSION-$ISA_SUFFIX.conan.tar.gz
tar -czf "$CONAN_FILE" -C "$WORK/artifact" "$(basename "$ART_DIR")"

# 全部成功, 移交产物到输出目录
mv "$DEB_FILE" "$CONAN_FILE" "$OUT_DIR/" || die "无法将产物移动到 $OUT_DIR"
DEB_FILE=$OUT_DIR/$(basename "$DEB_FILE")
CONAN_FILE=$OUT_DIR/$(basename "$CONAN_FILE")

#-------------------------------------------------------------------------------
cat <<EOF

========================================
构建完成:  MY_BREAKPAD_VERSION = $MY_BREAKPAD_VERSION
  Debian package:  $DEB_FILE
  Conan package:   $CONAN_FILE

Debian package: 安装到 /opt/breakpad; 直接运行 bin/<tool>,
或用 bin/<tool>.bash (自动把 /opt/breakpad/lib 加入 LD_LIBRARY_PATH).

Conan package 导入本地 cache (JFrog Conan 1.x):
  tar xf $(basename "$CONAN_FILE")
  cd breakpad-$MY_BREAKPAD_VERSION-$ISA_SUFFIX-conan
  conan export-pkg . breakpad/$MY_BREAKPAD_VERSION@ -pf package
========================================
EOF

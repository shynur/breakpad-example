## 当前环境

当前环境是由 `172.17.0.1` 上的 Docker Engine 创建的一个 docker container.

当前环境仅供我们对话或访问仓库.

本环境运行着 mihomo 代理服务, 监听在 `7890` 端口.
本环境启动时向 `docker` 传递了 `-p <宿主机的port>:7890`, 请你自行查看.
其它环境 (宿主机, 以及宿主机所创建的任何容器) 可通过 `{http{,s},all}_proxy` 环境变量设置代理加速网络访问.

⚠  绝不能影响当前容器!  禁止重启 dockerd!  禁止执行任何会对宿主机和本环境有影响的命令!

## 构建/测试环境

### 如何创建

你可用 `ssh root@172.17.0.1` 访问 Docker 宿主机.

只允许使用 Docker Engine 新建所需的环境.
所使用的环境必须是全新的, 不允许复用任何原先就存在的环境.

若 Docker Hub 无法访问, 请考虑使用 mirror site.

### 环境信息

- Arch: x64 or arm64 (反正一定是 64-bit)
- 操作系统: Ubuntu 18.04
- 编译器工具链: `clang++-6` + `libstdc++-7`
- CMake: 使用 Kitware 官方脚本安装 CMake `3.23.5`

## Breakpad

### Source

使用 Google Breakpad tag `v2024.02.16`.

仓库本身不完整, 构建前须按 `DEPS` 补齐:
- `src/third_party/lss` ← `https://chromium.googlesource.com/linux-syscall-support` (commit 见 `DEPS`, 构建必需)
- `src/testing` ← `https://github.com/google/googletest` tag `release-1.11.0` (仅 `make check` 需要)

构建依赖: `libzstd-dev` (启用 zstd 时必需), `zlib1g-dev` (`dump_syms` 无条件 `#include <zlib.h>`).

### Configure

无视 Breakpad 的 `configure.ac`, 直接用它自带的 `configure`.

对于 `configure` 可接受的 breakpad 特有的 package options, 我们规定只有 `--enable-zstd` 允许被添加.
是否要传递 `--enable-zstd` 必须得用户明确要求; 你也可根据测试环境, 及时给出建议.

### Test

创建 container 时须指定 `--tmpfs /tmp:exec`, 否则 `make check` 会有测试失败:
- 不带 `--tmpfs` 时 `/tmp` 位于 overlayfs 上, 可能不支持 `O_TMPFILE` (而 `google_breakpad::ScopedTmpFile` 依赖它)
- `--tmpfs` 默认挂载选项含 `noexec`, 但部分测试用例要把辅助程序放进 `/tmp` 运行, 故须显式指定 `exec`

### Install

#### destination

自行查看 [CML](./CMakeLists.txt), 安装到示例程序能找到的位置即可.

#### 我关心的组件

安装目录下包含: 运行时的客户端工具, 服务端用于采集或分析的工具, 用户的构建时依赖, etc.
我们要重点关注的是以下组件:

```
├── bin/
│   ├── core2md
│   ├── dump_syms
│   ├── minidump-2-core
│   ├── minidump_dump
│   ├── minidump_stackwalk
│   └── pid2md
├── include/breakpad/
└── lib/
    ├── libbreakpad_client.a
    └── pkgconfig/breakpad-client.pc
```

## Packaging

[packaging/build-conan-and-deb.bash](./packaging/build-conan-and-deb.bash) 在**当前环境直接** (不借助 docker) 构建 breakpad, 并把**同一份安装目录**打成两个包:

```
packaging/build-conan-and-deb.bash -t <breakpad tag> -b <build metadata> -o <输出目录>
# 例: ... -t v2024.02.16 -b `TZ=Asia/Shanghai date +%Y%m%d%H%M` -o out/
```

- 版本号 `MY_BREAKPAD_VERSION = <tag 去前导 v>+<build metadata>`, 如 `2024.02.16+201212311200`.
- 产物 (ISA 后缀: x86_64→`-x64`, aarch64→`-arm64`):
  - `breakpad-<MY_BREAKPAD_VERSION>-<ISA>.deb` — 安装到 `/opt/breakpad`.
  - `breakpad-<MY_BREAKPAD_VERSION>-<ISA>.conan.tar.gz` — 含 `conanfile.py` + `package/`, 导入:
    `conan export-pkg . breakpad/<MY_BREAKPAD_VERSION>@ -pf package` (JFrog Conan 1.x).
- 安装目录在后处理后包含: `bin/` 全部工具 + 每个工具的同名 `.bash` 启动脚本
  (把安装前缀下的 `lib/` 加入 `LD_LIBRARY_PATH`), `include/breakpad/`,
  `lib/` (另捆绑基础系统不保证提供的 `libzstd.so.1`).
- 环境依赖: conan 1.x 需要 Python ≥ 3.7 (Ubuntu 18.04 自带 3.6, 须另装, 如 distro 的 `python3.7` + get-pip);
  其余见上文"构建依赖". conan 操作在隔离的临时 `CONAN_USER_HOME` 中进行.

## CI

[.github/workflows/build-breakpad.yml](./.github/workflows/build-breakpad.yml) (`workflow_dispatch` 手动触发):

1. `prepare`: 统一计算 `-t` (`v2024.02.16`) 与 `-b` (`TZ=Asia/Shanghai date +%Y%m%d%H%M`), 保证两个环境一致.
2. `build` (matrix: x64 / arm64): 在全新的 `ubuntu:18.04` 容器 (`--tmpfs /tmp:exec`; arm64 经 QEMU) 中
   安装约定环境的软件 (clang-6.0 + g++-7, python3.7 + conan==1.57.0, Kitware CMake 3.23.5 脚本),
   执行上述打包脚本.
3. `release`: 汇总 4 个包上传到 tag 为 `v$MY_BREAKPAD_VERSION` 的 GitHub release
   (已存在则 `--clobber` 覆盖上传, 幂等).

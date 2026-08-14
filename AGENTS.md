# Repository Guidelines

## 构建/测试环境

你可用 `ssh root@172.17.0.1` 访问 Docker 宿主机.

只允许使用 Docker Engine 新建所需的环境.
所使用的环境必须是全新的, 不允许复用任何原先就存在的环境.

## 当前环境

当前环境是由 `172.17.0.1` 上的 Docker Engine 创建的一个 docker container.

当前环境仅供我们对话或访问仓库.

本环境运行着 mihomo 代理服务, 监听在 `7890` 端口.
本环境启动时向 `docker` 传递了 `-p <宿主机的port>:7890`, 请你自行查看.
其它环境 (宿主机, 以及宿主机所创建的任何容器) 可通过 `{http{,s},all}_proxy` 环境变量设置代理加速网络访问.

⚠ 绝不能影响当前容器!  禁止重启 dockerd!  禁止执行任何会对宿主机和本环境有影响的命令!

## Docker 容器

- 操作系统: Ubuntu 18.04
- 编译器工具链: `clang++-6` + `libstdc++-7`

## 版本与构建注意事项

- CMake: 使用 Kitware 官方脚本安装 CMake `3.23.5`
- Google Breakpad: `v2024.02.16`
- configure:
  - 无视 Breakpad 的 `configure.ac`, 直接用它自带的 `configure`
  - 传递给 `configure` 的参数至少需要包含 `--enable-selftest`; 至多只允许额外加一个 `--enable-zstd`, 而且必须得用户明确要求
  - `{C,CXX}FLAGS` 需包含 `-Og -g`
- Breakpad 测试: 创建 container 时须指定 `--tmpfs /tmp:exec`, 否则 `make check` 会有测试失败:
  - 不带 `--tmpfs` 时 `/tmp` 位于 overlayfs 上, 可能不支持 `O_TMPFILE` (而 `google_breakpad::ScopedTmpFile` 依赖它);
  - `--tmpfs` 默认挂载选项含 `noexec`, 但部分测试用例要把辅助程序放进 `/tmp` 运行, 故须显式指定 `exec`.

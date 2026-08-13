cmake_minimum_required(VERSION 3.23)
project(BreakpadExample LANGUAGES CXX)

find_package(PkgConfig REQUIRED)

list(PREPEND CMAKE_PREFIX_PATH "/opt/breakpad")  # 这样就无需设置环境变量 PKG_CONFIG_PATH
pkg_check_modules(BREAKPAD_CLIENT REQUIRED IMPORTED_TARGET breakpad-client)
target_link_options(PkgConfig::BREAKPAD_CLIENT INTERFACE -pthread)

add_executable(breakpad_example src/main.cpp)
target_compile_features(breakpad_example PRIVATE cxx_std_17)
target_link_libraries(breakpad_example PRIVATE PkgConfig::BREAKPAD_CLIENT)

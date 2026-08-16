#include <csignal>
#include <cstdlib>
#include <string>
#include <iostream>
#include "client/linux/handler/exception_handler.h"

static char g_app_state[16];  // 希望随 minidump 一起采集的内存

int main() {
    auto breakpad_handler = ::google_breakpad::ExceptionHandler{
        ::google_breakpad::MinidumpDescriptor{
            [](const std::string minidump_dir) {
                if (std::system(("mkdir -p " + minidump_dir).c_str()) == 0)
                    return minidump_dir;
                std::cerr << "用户指定的用于存放 breakpad minidump 的目录无法创建\n";
                const std::string default_dir = "/tmp/breakpad-minidumps-default-dir";
                std::system(("mkdir -p " + default_dir).c_str());
                return default_dir;
            }("/tmp/breakpad-example-minidumps")
        },  // Minidump 输出位置
        [](void *const context [[maybe_unused]]) {
            // dump 前处理... (thread-safe / async-signal-safe)
            return true;  // 是否 dump
        },
        [](
           const ::google_breakpad::MinidumpDescriptor&,
           void *const context [[maybe_unused]],
           const bool succeeded
        ) {
            // dump 后处理... (thread-safe / async-signal-safe)
            return succeeded;
        },
        nullptr,  // context
        true,     // 要安装崩溃 signal-handler
        -1        // 不连接外部 crash server, 在进程内生成 dump
    };
    breakpad_handler.RegisterAppMemory(g_app_state, sizeof g_app_state);

    g_app_state[10] = 6;
    std::raise(SIGSEGV);
}

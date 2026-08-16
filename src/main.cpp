#include <csignal>
#include "client/linux/handler/exception_handler.h"

static char g_app_state[16];  // 希望随 minidump 一起采集的内存

int main() {
    auto breakpad_handler = ::google_breakpad::ExceptionHandler{
        ::google_breakpad::MinidumpDescriptor{"."},  // Minidump 输出位置
        [](void *const context [[maybe_unused]]) {
            return true;  // 是否 dump
        },
        [](
           const ::google_breakpad::MinidumpDescriptor&,
           void *const context [[maybe_unused]],
           const bool succeeded
        ) {
            // dump 后处理...
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

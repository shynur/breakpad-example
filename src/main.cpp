#include <csignal>
#include "client/linux/handler/exception_handler.h"

int main() {
    auto _breakpad_handler = ::google_breakpad::ExceptionHandler{
        ::google_breakpad::MinidumpDescriptor{"."},  // Minidump 输出位置
        nullptr,  // 崩溃过滤回调: 不需要
        nullptr,  // Minidump 写完后的回调: 暂不需要
        nullptr,  // 传递给回调的上下文
        true,     // 安装崩溃信号处理器
        -1        // 不连接外部 crash server, 在进程内生成 dump
    };  // 绝不能声明为 const

    std::raise(SIGSEGV);
}

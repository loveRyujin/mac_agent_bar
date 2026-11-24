import AgentBarCore
import Foundation

/// 程序入口：`AgentBar plugin …` 作为命令行工具运行（不打开界面），否则启动应用。
@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "plugin" else {
            AgentBarApp.main()
            return
        }
        let code = LockedBox<Int32>(PluginCLI.ExitCode.failure)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            code.value = await PluginCLI().run(Array(arguments.dropFirst()))
            done.signal()
        }
        done.wait()
        exit(code.value)
    }
}

/// 在后台任务和主线程之间传递退出码。
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

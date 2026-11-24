import CoreServices
import Foundation

/// 监听插件文件夹（含子文件夹）的变化，在主线程回调。与 `AppModel` 同生命周期，不需要停止。
@MainActor
final class PluginFolderWatcher {
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    init?(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PluginFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // 事件在主队列上派发（见下面的 FSEventStreamSetDispatchQueue）
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // 合并 1 秒内的连续改动
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

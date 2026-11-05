import Foundation

/// mpv 事件回调（移植自 MPVKit 官方 Demo 并扩充文件加载/结束事件）。
/// 所有回调都在主线程触发（控制器内部已切回主队列）。
@MainActor
public protocol MPVPlayerDelegate: AnyObject {
    func propertyChange(mpv: OpaquePointer, propertyName: String, data: Any?)
    /// 文件已加载完成（此时轨道列表、宽高、时长都可读）
    func mpvFileLoaded(mpv: OpaquePointer)
    /// 播放结束：reason 为 mpv 的 end-file reason（0=自然播完 EOF，4=出错），error 非空表示错误信息
    func mpvEndFile(mpv: OpaquePointer, reason: Int32, error: String?)
    /// loadfile 命令本身被引擎拒绝（如参数非法）：文件根本没有开始加载，
    /// 不会再有 END_FILE 事件，必须单独上报，否则界面只剩静默黑屏
    func mpvLoadFailed(mpv: OpaquePointer, error: String)
}

public extension MPVPlayerDelegate {
    func mpvFileLoaded(mpv: OpaquePointer) {}
    func mpvEndFile(mpv: OpaquePointer, reason: Int32, error: String?) {}
    func mpvLoadFailed(mpv: OpaquePointer, error: String) {}
}

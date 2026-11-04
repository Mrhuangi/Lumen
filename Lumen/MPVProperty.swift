import Foundation

/// mpv 属性名常量（移植自 MPVKit 官方 Demo 并按 Lumen 需要扩充）
enum MPVProperty {
    static let videoParamsColormatrix = "video-params/colormatrix"
    static let videoParamsColorlevels = "video-params/colorlevels"
    static let videoParamsPrimaries = "video-params/primaries"
    static let videoParamsGamma = "video-params/gamma"
    static let videoParamsSigPeak = "video-params/sig-peak"
    static let videoParamsSceneMaxR = "video-params/scene-max-r"
    static let videoParamsSceneMaxG = "video-params/scene-max-g"
    static let videoParamsSceneMaxB = "video-params/scene-max-b"
    static let pause = "pause"
    static let pausedForCache = "paused-for-cache"
    static let timePos = "time-pos"
    static let duration = "duration"
    static let trackList = "track-list"
    static let speed = "speed"
    static let width = "width"
    static let height = "height"
    static let eofReached = "eof-reached"
}

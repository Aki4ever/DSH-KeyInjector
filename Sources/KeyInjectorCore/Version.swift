// ==============================================================================
// 版本单一来源
//
// 全工程（CLI 输出、应用包 Info.plist、文档）的版本号都必须与此处一致。
// 一致性由 scripts/check_version_sync.sh 自动校验，避免多处硬编码各自漂移。
// 修改版本号时请同时更新仓库根目录的 VERSION 文件。
// ==============================================================================

public enum AppVersion {
    /// 当前实施版本，必须与仓库根目录 VERSION 文件内容一致
    public static let current = "1.3.0"

    /// 产品名
    public static let productName = "KeyInjector"

    /// 人类可读的完整版本描述
    public static var display: String { "\(productName) v\(current)" }
}

public enum VirtualizationSupport {
    #if os(macOS)
    public static let available = true
    #else
    public static let available = false
    #endif
}

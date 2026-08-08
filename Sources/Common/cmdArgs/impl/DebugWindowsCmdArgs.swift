public struct DebugWindowsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .debugWindows,
        help: debug_windows_help_generated,
        flags: [
            "--tabs": trueBoolFlag(\.tabs),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )

    public var tabs: Bool = false
}

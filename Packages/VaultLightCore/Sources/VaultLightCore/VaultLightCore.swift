/// VaultLight's testable core: CLI wrapper, models, search index, session and clipboard policy.
///
/// Everything with logic lives in this package so it can be tested with `swift test`.
/// The app target only wires these types to AppKit and SwiftUI.
public enum VaultLightCore {
    public static let version = "0.1.0"
}

import Foundation

/// Map basemap configuration. The MapTiler key is injected at build time into `Info.plist`,
/// from the untracked `Config/maptiler.local.xcconfig` in dev or from the `MAPTILER_API_KEY`
/// environment variable when `scripts/release.sh` builds; no key is committed. When the plist
/// has none, the process environment is tried, so a build launched from a shell that exports
/// the variable still gets tiles. Without any, the basemap tiles do not load and the map says so.
enum MapConfig {
    static var maptilerKey: String {
        let fromPlist = (Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String) ?? ""
        if !fromPlist.isEmpty { return fromPlist }
        return ProcessInfo.processInfo.environment["MAPTILER_API_KEY"] ?? ""
    }
}

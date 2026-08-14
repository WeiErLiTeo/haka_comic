import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let bookmarkRegistrar = flutterViewController.registrar(
      forPlugin: "MacOsSecurityScopedBookmarkPlugin"
    )
    MacOsSecurityScopedBookmarkPlugin.register(with: bookmarkRegistrar)

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

private final class MacOsSecurityScopedBookmarkPlugin {
  private static let channelName = "haka_comic/macos_security_scoped_bookmark"
  private static var accessedUrls: [String: URL] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "create":
          guard
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
          else {
            throw BookmarkError.invalidArguments
          }
          let url = URL(fileURLWithPath: path)
          let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          retainAccess(to: url)
          result(bookmark.base64EncodedString())
        case "resolve":
          guard
            let arguments = call.arguments as? [String: Any],
            let value = arguments["bookmark"] as? String,
            let bookmark = Data(base64Encoded: value)
          else {
            throw BookmarkError.invalidArguments
          }
          var isStale = false
          let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
          )
          retainAccess(to: url)
          result(url.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(
          FlutterError(
            code: "bookmark_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private static func retainAccess(to url: URL) {
    let key = url.standardizedFileURL.path
    if accessedUrls[key] != nil { return }
    if url.startAccessingSecurityScopedResource() {
      accessedUrls[key] = url
    }
  }

  private enum BookmarkError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
      "Invalid security-scoped bookmark arguments."
    }
  }
}

import Flutter
import Foundation

final class BackgroundSafePluginRegistrant {
  private static let lock = NSLock()
  private static var backgroundRegistered = Set<ObjectIdentifier>()
  private static var foregroundRegistered = Set<ObjectIdentifier>()

  static func registerBackgroundPlugins(with registry: FlutterPluginRegistry) {
    register(registry, trackedBy: &backgroundRegistered) {
      registerPlugin(named: "MMKVPlugin", with: registry, aliases: ["mmkv.MMKVPlugin", "mmkv_ios.MMKVPlugin"])
      registerPlugin(
        named: "PathProviderPlugin",
        with: registry,
        aliases: ["path_provider_foundation.PathProviderPlugin"]
      )
      registerPlugin(
        named: "FPPPackageInfoPlusPlugin",
        with: registry,
        aliases: ["package_info_plus.FPPPackageInfoPlusPlugin"]
      )
      registerPlugin(
        named: "SqflitePlugin",
        with: registry,
        aliases: ["sqflite_darwin.SqflitePlugin"]
      )
    }
  }

  static func registerForegroundPlugins(with registry: FlutterPluginRegistry) {
    register(registry, trackedBy: &foregroundRegistered) {
      GeneratedPluginRegistrant.register(with: registry)
    }
  }

  private static func register(
    _ registry: FlutterPluginRegistry,
    trackedBy registrations: inout Set<ObjectIdentifier>,
    action: () -> Void
  ) {
    let key = ObjectIdentifier(registry as AnyObject)

    lock.lock()
    let isAlreadyRegistered = registrations.contains(key)
    if !isAlreadyRegistered {
      registrations.insert(key)
    }
    lock.unlock()

    guard !isAlreadyRegistered else { return }
    action()
  }

  private static func registerPlugin(
    named registrarKey: String,
    with registry: FlutterPluginRegistry,
    aliases: [String] = []
  ) {
    guard let pluginType = pluginType(named: registrarKey, aliases: aliases) else {
      return
    }

    guard let registrar = registry.registrar(forPlugin: registrarKey) else {
      return
    }

    pluginType.register(with: registrar)
  }

  private static func pluginType(
    named name: String,
    aliases: [String]
  ) -> FlutterPlugin.Type? {
    for candidate in [name] + aliases {
      if let pluginClass = NSClassFromString(candidate) as? FlutterPlugin.Type {
        return pluginClass
      }
    }

    return nil
  }
}

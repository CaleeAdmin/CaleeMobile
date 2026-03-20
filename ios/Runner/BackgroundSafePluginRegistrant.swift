import Flutter
import Foundation
import mmkv
import path_provider_foundation
import package_info_plus
import sqflite_darwin

final class BackgroundSafePluginRegistrant {
  private static let lock = NSLock()
  private static var backgroundRegistered = Set<ObjectIdentifier>()
  private static var foregroundRegistered = Set<ObjectIdentifier>()

  static func registerBackgroundPlugins(with registry: FlutterPluginRegistry) {
    register(registry, trackedBy: &backgroundRegistered) {
      MMKVPlugin.register(with: registry.registrar(forPlugin: "MMKVPlugin"))
      PathProviderPlugin.register(with: registry.registrar(forPlugin: "PathProviderPlugin"))
      FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
      SqflitePlugin.register(with: registry.registrar(forPlugin: "SqflitePlugin"))
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
}

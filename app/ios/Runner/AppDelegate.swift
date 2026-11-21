import AppIntents
import Flutter
import UIKit

@MainActor
final class ActionButtonCoordinator {
  static let shared = ActionButtonCoordinator()

  private let defaultsActionKey = "noteit.pending_action"
  private let defaultsTimestampKey = "noteit.pending_action_ts"
  private let maxActionAgeSeconds: TimeInterval = 60.0
  private var channel: FlutterMethodChannel?

  private init() {}

  func attachChannel(_ methodChannel: FlutterMethodChannel) {
    channel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "consumePendingAction" {
        Task { @MainActor in
          result(self?.consumePendingAction())
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func trigger(action: String) {
    if let channel {
      clearPendingAction()
      channel.invokeMethod("onActionTriggered", arguments: action)
      return
    }
    let defaults = UserDefaults.standard
    defaults.set(action, forKey: defaultsActionKey)
    defaults.set(Date().timeIntervalSince1970, forKey: defaultsTimestampKey)
  }

  func handleIncomingURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "noteit" else {
      return false
    }
    let host = (url.host ?? "").lowercased()
    if host == "record" || host == "start" {
      trigger(action: "start_recording")
      return true
    }
    if host == "toggle" {
      trigger(action: "toggle_recording")
      return true
    }
    return false
  }

  private func consumePendingAction() -> String? {
    let defaults = UserDefaults.standard
    guard let action = defaults.string(forKey: defaultsActionKey) else {
      return nil
    }
    let timestamp = defaults.double(forKey: defaultsTimestampKey)
    clearPendingAction()
    let age = Date().timeIntervalSince1970 - timestamp
    guard age >= 0, age <= maxActionAgeSeconds else {
      return nil
    }
    return action
  }

  private func clearPendingAction() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: defaultsActionKey)
    defaults.removeObject(forKey: defaultsTimestampKey)
  }
}

@available(iOS 16.0, *)
struct StartRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start NoteIt Recording"
  static var description = IntentDescription(
    "Opens NoteIt and immediately starts recording meeting audio."
  )
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ActionButtonCoordinator.shared.trigger(action: "start_recording")
    return .result()
  }
}

@available(iOS 16.0, *)
struct ToggleRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Toggle NoteIt Recording"
  static var description = IntentDescription(
    "Starts recording if idle, or stops and uploads if currently recording."
  )
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ActionButtonCoordinator.shared.trigger(action: "toggle_recording")
    return .result()
  }
}

@available(iOS 16.0, *)
struct NoteItAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: [
        "Start recording in \(.applicationName)",
        "Record meeting with \(.applicationName)"
      ],
      shortTitle: "Start Recording",
      systemImageName: "mic.circle.fill"
    )
    AppShortcut(
      intent: ToggleRecordingIntent(),
      phrases: [
        "Toggle recording in \(.applicationName)",
        "Start or stop \(.applicationName)"
      ],
      shortTitle: "Toggle Recording",
      systemImageName: "record.circle"
    )
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if ActionButtonCoordinator.shared.handleIncomingURL(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.noteit/action_button",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    Task { @MainActor in
      ActionButtonCoordinator.shared.attachChannel(channel)
    }
  }
}

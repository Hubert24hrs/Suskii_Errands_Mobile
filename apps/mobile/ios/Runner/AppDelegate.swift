import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// One cover per scene while it is inactive (see `coverSnapshot`).
  private var snapshotCovers: [ObjectIdentifier: UIView] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Scene notifications rather than SceneDelegate overrides: FlutterSceneDelegate implements
    // the lifecycle methods without declaring them, so a Swift subclass cannot call super.
    let center = NotificationCenter.default
    center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) {
      [weak self] note in
      if let scene = note.object as? UIWindowScene { self?.coverSnapshot(of: scene) }
    }
    center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) {
      [weak self] note in
      if let scene = note.object as? UIWindowScene { self?.uncoverSnapshot(of: scene) }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// iOS cannot block a screenshot, but it can keep balances, KYC details and handover PINs
  /// out of the app-switcher snapshot, which is taken while the scene is inactive. Android
  /// does the equivalent with FLAG_SECURE (lib/app/secure_screen.dart, MainActivity).
  private func coverSnapshot(of scene: UIWindowScene) {
    let key = ObjectIdentifier(scene)
    guard snapshotCovers[key] == nil,
      let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return }
    let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    snapshotCovers[key] = cover
  }

  private func uncoverSnapshot(of scene: UIWindowScene) {
    snapshotCovers.removeValue(forKey: ObjectIdentifier(scene))?.removeFromSuperview()
  }
}

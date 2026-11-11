import SwiftUI
import UIKit

@MainActor final class PlayerGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    var onTap: () -> Void = {}
    var onDoubleTap: (CGFloat) -> Void = { _ in }
    var onHold: (Bool) -> Void = { _ in }
    var onZoom: (Bool) -> Void = { _ in }
    var excludesTouch: ((CGPoint, UIView) -> Bool)?
    private var installed: [UIGestureRecognizer] = []
    func install(in view: UIView, singleTap: Bool) {
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped)); double.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held)); hold.minimumPressDuration = 0.18
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        installed = [double, hold, pinch]
        if singleTap {
            let single = UITapGestureRecognizer(target: self, action: #selector(tapped)); single.require(toFail: double); installed.append(single)
        }
        for gesture in installed { gesture.delegate = self; gesture.cancelsTouchesInView = false; view.addGestureRecognizer(gesture) }
    }
    func remove() { onHold(false); for gesture in installed { gesture.view?.removeGestureRecognizer(gesture) }; installed = [] }
    @objc private func tapped() { onTap() }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view, view.bounds.width > 0 else { return }
        onDoubleTap(gesture.location(in: view).x / view.bounds.width)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onHold(true) }
        else if [.ended, .cancelled, .failed].contains(gesture.state) { onHold(false) }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) { if gesture.state == .ended { onZoom(gesture.scale > 1) } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = gestureRecognizer.view, excludesTouch?(touch.location(in: view), view) == true { return false }
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }; view = current.superview
        }
        return true
    }
}
struct PlayerGestureSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onDoubleTap: (CGFloat) -> Void
    let onHold: (Bool) -> Void
    let onZoom: (Bool) -> Void
    func makeCoordinator() -> PlayerGestureCoordinator { PlayerGestureCoordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; context.coordinator.install(in: view, singleTap: true); return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTap = onTap; context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onHold = onHold; context.coordinator.onZoom = onZoom
    }
    static func dismantleUIView(_ view: UIView, coordinator: PlayerGestureCoordinator) { coordinator.remove() }
}

@MainActor enum PlayerGestureRateState {
    private static var players: Set<ObjectIdentifier> = []
    static func set(_ player: AnyObject, active: Bool) { if active { players.insert(ObjectIdentifier(player)) } else { players.remove(ObjectIdentifier(player)) } }
    static func isActive(_ player: AnyObject) -> Bool { players.contains(ObjectIdentifier(player)) }
}

@MainActor enum PlaybackGesturePreferences {
    static let skipIntervalKey = "player.doubleTapSkipSeconds"
    static func skipInterval(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: skipIntervalKey) as? Double ?? 15
        guard value.isFinite else { return 15 }
        return min(60, max(5, (value / 5).rounded() * 5))
    }
}

struct DoubleTapSkipSettings: View {
    @AppStorage(PlaybackGesturePreferences.skipIntervalKey) private var seconds = 15.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Double-tap skip", value: seconds == 60 ? "1 minute" : "\(Int(seconds)) seconds")
            Slider(value: $seconds, in: 5...60, step: 5) {
                Text("Double-tap skip interval")
            } minimumValueLabel: { Text("5s") } maximumValueLabel: { Text("1m") }
                .accessibilityIdentifier("settings.doubleTapSkip")
            Text("Double-tap either side of the video to seek by this amount.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

import Foundation
import CoreGraphics

/// Geometry shared by the renderer and the panel's hit testing.
enum NotchLayout {
    static func idle(base: CGSize, hardware: CGSize?, percent: Double) -> CGSize {
        let k = min(max(percent, 80), 130) / 100
        guard let hardware else {
            return CGSize(width: (base.width * k).rounded(), height: (base.height * k).rounded())
        }
        if k >= 1 {
            return CGSize(width: (base.width * k).rounded(),
                          height: max(hardware.height, (base.height * k).rounded()))
        }
        // 80% is flush with the camera housing; interpolate the visible extension, not the hardware.
        let t = (k - 0.8) / 0.2
        return CGSize(width: (hardware.width + (base.width - hardware.width) * t).rounded(.up),
                      height: max(hardware.height,
                                  (hardware.height + (base.height - hardware.height) * t).rounded(.up)))
    }

    static func announcementTop(hardwareHeight: CGFloat, islandBottom: CGFloat) -> CGFloat {
        max(hardwareHeight, islandBottom) + 6
    }

    static func announcementRect(screen: CGRect, size: CGSize, top: CGFloat) -> CGRect {
        CGRect(x: screen.midX - size.width / 2, y: screen.maxY - top - size.height,
               width: size.width, height: size.height)
    }
}

import Foundation
import CoreGraphics

@main
enum NotchLayoutTests {
    static func main() {
        let hardware = CGSize(width: 176, height: 38)
        let base = CGSize(width: 270, height: 38)
        let widths = stride(from: 80, through: 130, by: 5).map {
            NotchLayout.idle(base: base, hardware: hardware, percent: Double($0)).width
        }
        precondition(widths.first == hardware.width && widths[4] == base.width)
        precondition(zip(widths, widths.dropFirst()).allSatisfy { $0.0 < $0.1 })
        precondition(NotchLayout.idle(base: CGSize(width: 220, height: 32), hardware: nil, percent: 80)
                     == CGSize(width: 176, height: 26))
        let screen = CGRect(x: -1440, y: 140, width: 1440, height: 900)
        let size = CGSize(width: 260, height: 34)
        let top = NotchLayout.announcementTop(hardwareHeight: 38, islandBottom: 32)
        let rect = NotchLayout.announcementRect(screen: screen, size: size, top: top)
        precondition(top == 44 && rect.midX == screen.midX && rect.maxY == screen.maxY - 44)
        precondition(NotchLayout.announcementTop(hardwareHeight: 38, islandBottom: 60) == 66)
        print("Glance layout: 11 scale steps, notchless sizing, and announcement geometry passed")
    }
}

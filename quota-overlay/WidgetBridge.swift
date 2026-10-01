import Foundation
import WidgetKit

@objc(QGWidgetBridge)
public final class QGWidgetBridge: NSObject {
    @objc public static func reloadAllTimelines() {
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

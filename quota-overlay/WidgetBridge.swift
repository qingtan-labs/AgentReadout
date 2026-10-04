import WidgetKit

// Runs inside the containing AppKit app, using its bundle identity.
@_cdecl("QGReloadNativeWidgets")
public func reloadNativeWidgets() {
    WidgetCenter.shared.reloadTimelines(ofKind: "com.qingtanlabs.gaugeforcodex.quota")
    WidgetCenter.shared.reloadTimelines(ofKind: "com.qingtanlabs.gaugeforcodex.daily-token")
}

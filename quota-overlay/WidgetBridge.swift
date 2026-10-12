import WidgetKit

// Runs inside the containing AppKit app, using its bundle identity.
@_cdecl("QGReloadNativeQuotaWidget")
public func reloadNativeQuotaWidget() {
    WidgetCenter.shared.reloadTimelines(ofKind: "com.qingtanlabs.gaugeforcodex.quota")
}

@_cdecl("QGReloadNativeDailyWidget")
public func reloadNativeDailyWidget() {
    WidgetCenter.shared.getCurrentConfigurations { result in
        switch result {
        case .success(let widgets):
            let kinds = widgets.filter { $0.kind.hasPrefix("com.qingtanlabs.gaugeforcodex.") }
                .map(\.kind).sorted()
            NSLog("AgentReadout: configured native widgets: %@", kinds.joined(separator: ", "))
        case .failure(let error):
            NSLog("AgentReadout: widget configuration lookup failed: %@", error.localizedDescription)
        }
    }
    WidgetCenter.shared.reloadTimelines(ofKind: "com.qingtanlabs.gaugeforcodex.daily-token")
}

@_cdecl("QGReloadAllNativeWidgets")
public func reloadAllNativeWidgets() {
    WidgetCenter.shared.getCurrentConfigurations { result in
        if case .success(let widgets) = result {
            let kinds = widgets.filter { $0.kind.hasPrefix("com.qingtanlabs.gaugeforcodex.") }
                .map(\.kind).sorted()
            NSLog("AgentReadout: configured native widgets: %@", kinds.joined(separator: ", "))
        }
    }
    WidgetCenter.shared.reloadAllTimelines()
}

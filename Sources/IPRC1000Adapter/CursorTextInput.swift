import AppKit
import ApplicationServices

/// Retains the user's focused editor for one utterance; never activates another application.
@MainActor
final class CursorTextInput {
    var onStatus: (String) -> Void = { _ in }
    private var application: NSRunningApplication?
    private var field: AXUIElement?
    private var targetError = "未找到输入框；请先点入目标输入框再说话"

    func begin() {
        application = nil
        field = nil
        guard AXIsProcessTrusted() else { targetError = "光标输入需要辅助功能权限"; return }
        guard let app = NSWorkspace.shared.frontmostApplication else { targetError = "无法取得前台应用"; return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            targetError = "当前前台是适配器；请先点击其他应用的输入框"
            return
        }
        guard let focused = Self.focusedElement(pid: app.processIdentifier) else {
            targetError = "无法取得 \(app.localizedName ?? "前台应用") 的聚焦输入框"
            return
        }
        let role = Self.stringAttribute(focused, kAXRoleAttribute)
        let subrole = Self.stringAttribute(focused, kAXSubroleAttribute)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              subrole != kAXSecureTextFieldSubrole else {
            targetError = "\(app.localizedName ?? "前台应用") 当前焦点为 \(role)；请点击普通文本输入框"
            return
        }
        application = app
        field = focused
    }

    func insert(_ text: String) -> String {
        defer { application = nil; field = nil }
        guard !text.isEmpty else { return "没有可输入的文字" }
        guard AXIsProcessTrusted() else { return "光标输入需要辅助功能权限" }
        guard let application, let field else { return targetError }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let current = Self.focusedElement(pid: application.processIdentifier),
              CFEqual(current, field) else {
            return "输入焦点已改变，文字保留在此处"
        }
        let oldValue = Self.stringAttribute(field, kAXValueAttribute)
        var rangeValue: CFTypeRef?
        var selection = CFRange(location: 0, length: 0)
        let hasRange = AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString,
            &rangeValue) == .success && rangeValue.map {
                CFGetTypeID($0) == AXValueGetTypeID()
                    && AXValueGetValue($0 as! AXValue, .cfRange, &selection)
            } == true
        let oldString = oldValue as NSString
        let expected: String?
        if hasRange, selection.location >= 0, selection.length >= 0,
           selection.location + selection.length <= oldString.length {
            expected = oldString.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text)
        } else { expected = oldValue.isEmpty ? text : nil }
        // Chromium can report AXSelectedText success without editing the DOM. Use normal paste.
        KeyEmitter.pasteText(text)
        let name = application.localizedName ?? "当前输入框"
        let report = onStatus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let actual = Self.stringAttribute(field, kAXValueAttribute)
            if actual == expected || (expected == nil && actual != oldValue && actual.contains(text)) {
                report("已确认输入到 \(name)")
            } else if actual == oldValue {
                report("目标输入框未改变；文字已保留，需检查粘贴与辅助功能权限")
            } else {
                report("已发送粘贴；当前编辑器无法完整回读，请核对输入框")
            }
        }
        return "正在向 \(name) 粘贴并核对结果…"
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
            kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}

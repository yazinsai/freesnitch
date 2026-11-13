import SwiftUI
import AppKit

/// The rows of the live monitor tree.
///
/// Every view here is a pure function of one already-grouped node. No view in
/// this file groups, sorts, filters by traffic, or decides anything: a
/// decision only happens when the user presses one of the two labelled
/// controls on a row, and it is sent straight to the helper.

// MARK: - List

struct MonitorTreeList: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var controller: MonitorTreeController
    let searchText: String
    /// Narrows the tree to the rows behind the menu bar's denied badge (#138).
    var deniedOnly: Bool = false
    @Binding var selectedAppID: String?
    /// Removing a rule is removing stored policy, so it is confirmed and the
    /// confirmation names what goes (#115).
    @State private var pendingClear: PendingClear?

    private struct PendingClear: Identifiable {
        let id = UUID()
        let subject: String
        let target: MonitorRuleTarget
    }

    var body: some View {
        let visible = MonitorTreeFilter.apply(query: searchText,
                                              deniedOnly: deniedOnly,
                                              to: controller.snapshot)
        // A real outline: system disclosure triangles, system selection and
        // arrow-key navigation. The hand-drawn chevron button and the painted
        // selection tint are gone, but the controller still owns expansion, so
        // an app stays open across every refresh of the live data.
        List(selection: $selectedAppID) {
            if visible.apps.isEmpty {
                emptyRow
            }
            ForEach(visible.apps) { app in
                DisclosureGroup(isExpanded: expansion(of: app)) {
                    ForEach(app.destinations) { destination in
                        // Selecting a disclosure group highlights its children
                        // as well, so a destination row can be sitting on the
                        // accent colour without being selected itself. It has
                        // to know, or its blue bar vanishes the same way the
                        // app row's did (#76).
                        MonitorDestinationRow(destination: destination,
                                              selected: selectedAppID == app.id || selectedAppID == destination.id,
                                              peakTraffic: app.peakDestinationTraffic,
                                              decision: controller.decision(for: MonitorRuleTarget.destination(destination, in: app)),
                                              pending: controller.isPending(MonitorRuleTarget.destination(destination, in: app)),
                                              onDecide: { action in decide(action, destination: destination, app: app) },
                                              onClear: { clear(destination: destination, app: app) })
                        // Tagged so the row can be selected and so the list's
                        // context menu can tell which row was clicked.
                        .tag(destination.id)
                    }
                    if let note = boundsNote(for: app) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    MonitorAppRow(app: app,
                                  selected: selectedAppID == app.id,
                                  peakTraffic: controller.snapshot.peakAppTraffic,
                                  decision: controller.decision(for: MonitorRuleTarget.app(app)),
                                  pending: controller.isPending(MonitorRuleTarget.app(app)),
                                  onDecide: { action in decide(action, app: app) },
                                  onClear: { clear(app: app) })
                }
                .tag(app.id)
            }
            if visible.hiddenAppCount > 0 {
                Text("\(visible.hiddenAppCount) more apps are not shown, the list is bounded at \(MonitorTreeLimits.maxApps).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Content, not a sidebar: the window's own sidebar is the only place
        // that carries a translucent material.
        .listStyle(.inset)
        // A per-row .contextMenu inside a List never sees the right click here:
        // the NSTableView underneath takes the event first. The selection-aware
        // form is installed on the table itself, so it works, and it selects
        // the row that was clicked before opening (#78).
        .contextMenu(forSelectionType: String.self) { ids in
            rowContextMenu(for: ids, in: visible)
        }
        // The keyboard reaches the same two actions the pointer does (#116).
        .onDeleteCommand { clearSelectedRow(in: visible) }
        .onCopyCommand { copySelectedRow(in: visible) }
        .confirmationDialog("Remove the rule for \(pendingClear?.subject ?? "this row")?",
                            isPresented: Binding(get: { pendingClear != nil },
                                                 set: { if !$0 { pendingClear = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Rule", role: .destructive) {
                if let target = pendingClear?.target {
                    controller.clearDecision(for: target, state: state)
                }
                pendingClear = nil
            }
            Button("Cancel", role: .cancel) { pendingClear = nil }
        } message: {
            Text("The rule is deleted from FreeSnitch. This row goes back to no decision, and the next connection follows the current mode.")
        }
    }

    /// One menu for both kinds of row: the id identifies either an app or one
    /// of its destinations.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<String>, in visible: MonitorTreeFilter.Result) -> some View {
        if let id = ids.first {
            if let app = visible.apps.first(where: { $0.id == id }) {
                decisionMenu(target: MonitorRuleTarget.app(app),
                             onDecide: { decide($0, app: app) },
                             onClear: { clear(app: app) })
                Divider()
                CopyMenuItem(title: "Copy App Name", value: app.name)
                CopyMenuItem(title: "Copy Path", value: app.path)
                if RowActions.canReveal(path: app.path) {
                    Button("Reveal in Finder") { RowActions.revealInFinder(path: app.path) }
                }
            } else if let (app, destination) = visible.destinationRow(withID: id) {
                decisionMenu(target: MonitorRuleTarget.destination(destination, in: app),
                             onDecide: { decide($0, destination: destination, app: app) },
                             onClear: { clear(destination: destination, app: app) })
                Divider()
                CopyMenuItem(title: "Copy Host", value: destination.remoteHost)
                CopyMenuItem(title: "Copy IP Address", value: destination.remoteIP)
            }
        }
    }

    /// Expansion still belongs to the controller; the disclosure triangle just
    /// drives it.
    private func expansion(of app: MonitorAppNode) -> Binding<Bool> {
        Binding(get: { controller.isExpanded(app) },
                set: { _ in controller.toggleExpansion(app) })
    }

    private var emptyRow: some View {
        Text(state.helperConnected
             ? (searchText.isEmpty ? "No connections yet." : "Nothing matches this search.")
             : "Waiting for the FreeSnitch helper.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boundsNote(for app: MonitorAppNode) -> String? {
        var parts: [String] = []
        if app.hiddenDestinationCount > 0 {
            parts.append("\(app.hiddenDestinationCount) more destinations")
        }
        if app.ungroupedConnectionCount > 0 {
            parts.append("\(app.ungroupedConnectionCount) connections past the grouping bound, counted in the totals above")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + "."
    }

    /// Allow, Deny and Remove for one row, driving exactly the closures the
    /// row's own two controls drive (#78). A row that cannot be addressed by a
    /// rule gets no decision items rather than items that quietly do nothing.
    @ViewBuilder
    private func decisionMenu(target: MonitorRuleTarget?,
                              onDecide: @escaping (RuleAction) -> Void,
                              onClear: @escaping () -> Void) -> some View {
        if let target {
            let decision = controller.decision(for: target)
            let pending = controller.isPending(target)
            Button("Allow") { onDecide(.allow) }
                .disabled(pending || decision?.action == .allow)
            Button("Deny") { onDecide(.deny) }
                .disabled(pending || decision?.action == .deny)
            if decision != nil {
                Button("Remove This Rule", role: .destructive) { onClear() }
                    .disabled(pending)
            }
        }
    }

    private func decide(_ action: RuleAction, app: MonitorAppNode) {
        guard let target = MonitorRuleTarget.app(app) else { return }
        controller.apply(action, to: target, processName: app.name, state: state)
    }

    private func decide(_ action: RuleAction, destination: MonitorDestinationNode, app: MonitorAppNode) {
        guard let target = MonitorRuleTarget.destination(destination, in: app) else { return }
        controller.apply(action, to: target, processName: app.name, state: state)
    }

    /// Delete on a selected row removes the rule behind it, through the same
    /// confirmation the menu item uses.
    private func clearSelectedRow(in visible: MonitorTreeFilter.Result) {
        guard let id = selectedAppID else { return }
        if let app = visible.apps.first(where: { $0.id == id }) {
            guard controller.decision(for: MonitorRuleTarget.app(app)) != nil else { return }
            clear(app: app)
            return
        }
        for app in visible.apps {
            if let destination = app.destinations.first(where: { $0.id == id }) {
                guard controller.decision(for: MonitorRuleTarget.destination(destination, in: app)) != nil else { return }
                clear(destination: destination, app: app)
                return
            }
        }
    }

    private func copySelectedRow(in visible: MonitorTreeFilter.Result) -> [NSItemProvider] {
        guard let id = selectedAppID else { return [] }
        if let app = visible.apps.first(where: { $0.id == id }) {
            return [NSItemProvider(object: app.name as NSString)]
        }
        for app in visible.apps {
            if let destination = app.destinations.first(where: { $0.id == id }) {
                // A seen name is a label; the row is the address.
                let value = destination.labelIsSeenName ? destination.remoteIP ?? destination.label : destination.label
                return [NSItemProvider(object: value as NSString)]
            }
        }
        return []
    }

    private func clear(app: MonitorAppNode) {
        guard let target = MonitorRuleTarget.app(app) else { return }
        pendingClear = PendingClear(subject: "every connection from \(app.name)", target: target)
    }

    private func clear(destination: MonitorDestinationNode, app: MonitorAppNode) {
        guard let target = MonitorRuleTarget.destination(destination, in: app) else { return }
        pendingClear = PendingClear(subject: "\(app.name) to \(destination.decisionSubject)", target: target)
    }
}

// MARK: - App row

struct MonitorAppRow: View {
    let app: MonitorAppNode
    let selected: Bool
    let peakTraffic: Int64
    let decision: Rule?
    let pending: Bool
    let onDecide: (RuleAction) -> Void
    let onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName ?? app.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(OptionalHelp(text: app.displayName == nil ? app.name : "Connections made by \(app.name)"))
                MonitorSubtitle(parts: summaryParts, deniedCount: app.deniedCount)
            }
            Spacer(minLength: 4)
            MonitorDecisionControls(decision: decision,
                                    pending: pending,
                                    addressable: MonitorRuleTarget.app(app)?.isAddressable ?? false,
                                    subject: "every connection from \(app.name)",
                                    revealed: hovering || selected,
                                    onSelection: selected,
                                    onDecide: onDecide,
                                    onClear: onClear)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if app.isWebContent {
            Image(systemName: "safari")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        } else if let image = MonitorAppIconCache.icon(for: app) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    private var summaryParts: [String] {
        var parts = ["\(app.destinationCount) destination\(app.destinationCount == 1 ? "" : "s")"]
        if app.traffic.total > 0 { parts.append(PSFormat.bytes(app.traffic.total)) }
        return parts
    }
}

/// "8 destinations · 1.2 MB · 3 denied", with only the denied count in colour.
/// Zero traffic is left out rather than shown as "0 bytes".
struct MonitorSubtitle: View {
    let parts: [String]
    let deniedCount: Int

    var body: some View {
        (Text(parts.joined(separator: " · ")).foregroundColor(.secondary)
         + (deniedCount > 0
            ? Text(" · \(deniedCount) denied").foregroundColor(Color(nsColor: .systemRed))
            : Text("")))
            .font(.caption)
            .lineLimit(1)
            .monospacedDigit()
    }
}

// MARK: - Destination row

struct MonitorDestinationRow: View {
    let destination: MonitorDestinationNode
    var selected: Bool = false
    let peakTraffic: Int64
    let decision: Rule?
    let pending: Bool
    let onDecide: (RuleAction) -> Void
    let onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: destination.remoteHost == nil ? "number" : "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                MonitorSubtitle(parts: subtitleParts, deniedCount: destination.deniedCount)
            }
            Spacer(minLength: 4)
            MonitorDecisionControls(decision: decision,
                                    pending: pending,
                                    addressable: isAddressable,
                                    subject: destination.decisionSubject,
                                    revealed: hovering || selected,
                                    onSelection: selected,
                                    onDecide: onDecide,
                                    onClear: onClear)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var isAddressable: Bool {
        if let host = destination.remoteHost { return PFHostValidator.kind(for: host) != nil }
        if let ip = destination.remoteIP { return PFHostValidator.kind(for: ip) != nil }
        return false
    }

    private var subtitleParts: [String] {
        var parts: [String] = []
        if destination.labelIsSeenName, let ip = destination.remoteIP { parts.append(ip) }
        parts.append("\(destination.connectionCount) connection\(destination.connectionCount == 1 ? "" : "s")")
        if destination.traffic.total > 0 { parts.append(PSFormat.bytes(destination.traffic.total)) }
        if let code = destination.countryCode, !code.isEmpty { parts.append(code) }
        return parts
    }
}

// MARK: - Decision controls

/// Allow and Deny for one row, in words.
///
/// A row with no rule shows nothing until it is hovered or selected, then two
/// labelled buttons. A row with a rule always shows that rule ("Allowed",
/// "Denied"); hovering it offers the opposite choice and Reset, which removes
/// the rule. Pressing a button is the only way the monitor makes a decision.
struct MonitorDecisionControls: View {
    @EnvironmentObject var state: AppState
    let decision: Rule?
    let pending: Bool
    let addressable: Bool
    let subject: String
    /// The row is hovered or selected, so its actions are on show.
    var revealed: Bool = false
    var onSelection: Bool = false
    let onDecide: (RuleAction) -> Void
    let onClear: () -> Void

    private var canDecide: Bool { state.helperConnected }
    private var ruleActive: Bool { decision?.enabled == true }

    var body: some View {
        HStack(spacing: 6) {
            if pending {
                ProgressView().controlSize(.small)
            } else if revealed && addressable && canDecide {
                if !(ruleActive && decision?.action == .allow) {
                    actionButton("Allow", action: .allow)
                }
                if !(ruleActive && decision?.action == .deny) {
                    actionButton("Deny", action: .deny)
                }
                if decision != nil {
                    Button("Reset", action: onClear)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(onSelection ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .help("Remove this rule. New connections follow the current mode again.")
                        .accessibilityLabel("Remove the rule for \(subject)")
                }
            }
            if let decision, !pending {
                MonitorDecisionBadge(decision: decision)
            }
        }
        .modifier(OptionalHelp(text: revealed ? unavailableReason : nil))
    }

    private var unavailableReason: String? {
        if !addressable { return "This row has no destination a rule can name." }
        if !canDecide { return "Approve the FreeSnitch helper before deciding anything here." }
        return nil
    }

    private func actionButton(_ title: String, action: RuleAction) -> some View {
        let disabledRule = decision?.action == action && decision?.enabled == false
        return Button(title) { onDecide(action) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(action == .deny ? .red : nil)
            .accessibilityLabel("\(title) \(subject)")
            .help(disabledRule
                  ? "Turn the existing rule back on: \(title.lowercased()) \(subject)."
                  : "\(title) \(subject). You can change this later in Rules.")
    }
}

/// The rule a row is under, in words: "Denied", "Allowed", "Ask", or "Rule off"
/// for a disabled one.
struct MonitorDecisionBadge: View {
    let decision: Rule

    var body: some View {
        Group {
            if !decision.enabled {
                PSChip("Rule off", color: .secondary, icon: "pause.circle.fill")
            } else {
                switch decision.action {
                case .deny: PSChip("Denied", color: .red, icon: "xmark.circle.fill")
                case .allow: PSChip("Allowed", color: .green, icon: "checkmark.circle.fill")
                case .ask: PSChip("Ask", color: .orange, icon: "questionmark.circle.fill")
                }
            }
        }
        .fixedSize()
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        if !decision.enabled {
            return "A rule exists for this row but is turned off in Rules, so it decides nothing."
        }
        let verb: String
        switch decision.action {
        case .deny: verb = "are blocked"
        case .allow: verb = "are allowed"
        case .ask: verb = "ask first"
        }
        return "New connections here \(verb) by your rule. Connections that are already open are not affected."
    }
}

// MARK: - Filtering

/// Search over an already-built snapshot. Bounded by the snapshot's own caps,
/// and never changes the order rows are in.
enum MonitorTreeFilter {
    struct Result {
        let apps: [MonitorAppNode]
        let hiddenAppCount: Int

        /// Finds a destination row and the app it belongs to. Row ids are
        /// unique across the tree, so one id identifies exactly one row.
        func destinationRow(withID id: String) -> (MonitorAppNode, MonitorDestinationNode)? {
            for app in apps {
                if let destination = app.destinations.first(where: { $0.id == id }) {
                    return (app, destination)
                }
            }
            return nil
        }
    }

    static func apply(query: String,
                      deniedOnly: Bool = false,
                      to snapshot: MonitorTreeSnapshot) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || deniedOnly else {
            return Result(apps: snapshot.apps, hiddenAppCount: snapshot.hiddenAppCount)
        }
        let needle = trimmed.lowercased()
        let apps: [MonitorAppNode] = snapshot.apps.compactMap { app in
            // "Denied" narrows to the rows the menu bar badge counted, so the
            // badge lands on the list it promised (#138).
            if deniedOnly && app.deniedCount == 0 { return nil }
            let nameMatches = needle.isEmpty
                || app.name.lowercased().contains(needle)
                || app.displayName?.lowercased().contains(needle) == true
            if nameMatches && !deniedOnly { return app }
            let matches = app.destinations.filter { destination in
                let textMatches = needle.isEmpty
                    || nameMatches
                    || destination.label.lowercased().contains(needle)
                    || destination.remoteIP?.lowercased().contains(needle) == true
                    || destination.remoteHost?.lowercased().contains(needle) == true
                let verdictMatches = !deniedOnly || destination.deniedCount > 0
                return textMatches && verdictMatches
            }
            guard !matches.isEmpty else { return nil }
            return MonitorAppNode(id: app.id,
                                  name: app.name,
                                  bundleID: app.bundleID,
                                  path: app.path,
                                  connectionCount: app.connectionCount,
                                  deniedCount: app.deniedCount,
                                  destinationCount: app.destinationCount,
                                  traffic: app.traffic,
                                  destinations: matches,
                                  hiddenDestinationCount: app.hiddenDestinationCount,
                                  ungroupedConnectionCount: app.ungroupedConnectionCount,
                                  peakDestinationTraffic: app.peakDestinationTraffic,
                                  order: app.order,
                                  displayName: app.displayName,
                                  iconPath: app.iconPath,
                                  isWebContent: app.isWebContent)
        }
        return Result(apps: apps, hiddenAppCount: 0)
    }
}

// MARK: - Icons

/// Resolving an app icon touches the file system, so a row must not do it on
/// every redraw. Bounded, main-actor only, and cheap to miss.
@MainActor
enum MonitorAppIconCache {
    private static var cache: [String: NSImage?] = [:]
    private static let capacity = 256

    static func icon(for app: MonitorAppNode) -> NSImage? {
        if let cached = cache[app.id] { return cached }
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        let resolved = app.iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? AppIcon.resolve(bundleId: app.bundleID, path: app.path, name: app.name)
        cache[app.id] = resolved
        return resolved
    }
}

/// `.help` with nothing to say attaches an empty tooltip, which AppKit shows as
/// an empty yellow box. This attaches the tooltip only when there is a reason.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

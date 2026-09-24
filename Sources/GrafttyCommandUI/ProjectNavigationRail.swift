import SwiftUI
import GrafttyProtocol
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum ProjectAccentColor {
    private static let palette: [Color] = [.purple, .orange, .pink, .green, .gray, .teal, .blue, .indigo]
    public static func color(for project: SidebarProject) -> Color {
        guard let hex = project.accentHex, hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return palette[project.colorIndex]
        }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}

public struct ProjectIdentityView: View {
    public let project: SidebarProject
    public var imageData: Data?
    public init(project: SidebarProject, imageData: Data? = nil) { self.project = project; self.imageData = imageData }
    private var accent: Color { ProjectAccentColor.color(for: project) }
    public var body: some View {
        Group {
            if let image = decodedImage {
                image.resizable().scaledToFit().padding(2)
            } else {
                Text(project.displayInitials).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(accent.opacity(0.16))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.35)))
        .accessibilityHidden(true)
    }
    private var decodedImage: Image? {
        guard let imageData, imageData.count <= 65536 else { return nil }
        #if canImport(AppKit)
        return NSImage(data: imageData).map { Image(nsImage: $0) }
        #elseif canImport(UIKit)
        return UIImage(data: imageData).map { Image(uiImage: $0) }
        #else
        return nil
        #endif
    }
}

public struct ProjectNavigationRail: View {
    public var projects: [SidebarProject]
    public var counts: [String: Int]
    public var workingCounts: [String: Int]
    public var icons: [String: Data]
    public var selectedID: String?
    public var showsAttention: Bool
    public var excludedAttentionProjectIDs: Set<String>
    @Binding public var collapsed: Bool
    @Binding public var expandedWidth: Double
    public var onSelect: (SidebarProject) -> Void
    public var onAttention: () -> Void
    public var onMove: (String, String, Bool) -> Void
    public var menu: (SidebarProject) -> AnyView
    public var allowsReordering: Bool
    public var canExpand: Bool
    public var selectionColor: Color
    public var localDeviceID: RemoteDeviceID?
    public var management: () -> AnyView
    @State private var dropTarget: String?
    @State private var resizeStartWidth: Double?

    public init(projects: [SidebarProject], counts: [String: Int], workingCounts: [String: Int] = [:], icons: [String: Data], selectedID: String?,
                showsAttention: Bool, excludedAttentionProjectIDs: Set<String> = [], collapsed: Binding<Bool>, expandedWidth: Binding<Double> = .constant(196), allowsReordering: Bool = true, canExpand: Bool = true, selectionColor: Color = .primary.opacity(0.16),
                onSelect: @escaping (SidebarProject) -> Void, onAttention: @escaping () -> Void,
                onMove: @escaping (String, String, Bool) -> Void,
                localDeviceID: RemoteDeviceID? = nil,
                management: @escaping () -> AnyView = { AnyView(EmptyView()) },
                menu: @escaping (SidebarProject) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.projects = projects; self.counts = counts; self.icons = icons; self.selectedID = selectedID
        self.workingCounts = workingCounts
        self.localDeviceID = localDeviceID; self.management = management
        self.showsAttention = showsAttention; self.excludedAttentionProjectIDs = excludedAttentionProjectIDs; self._collapsed = collapsed; self._expandedWidth = expandedWidth; self.onSelect = onSelect
        self.onAttention = onAttention; self.onMove = onMove; self.menu = menu; self.allowsReordering = allowsReordering; self.canExpand = canExpand; self.selectionColor = selectionColor
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !collapsed { Text("Projects").font(.caption).foregroundStyle(.secondary); Spacer() }
            }.frame(height: 40).padding(.horizontal, 10)
            Button(action: onAttention) {
                HStack(spacing: 9) {
                    Image(systemName: "tray.full").frame(width: 28, height: 28)
                    if !collapsed {
                        if expandedWidth >= 160 { Text("Attention").font(.callout).lineLimit(1) }
                        Spacer(minLength: 0)
                        SidebarActivityBadge(counts.values.reduce(0, +))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(alignment: .topTrailing) { if collapsed { SidebarActivityBadge(counts.values.reduce(0, +)) } }
                .padding(.horizontal, collapsed ? 0 : 8)
                .contentShape(Rectangle())
                .background(showsAttention ? selectionColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).padding(.horizontal, 6)
                .accessibilityLabel("Attention, \(counts.values.reduce(0, +)) pending requests")
                .help(showsAttention ? "Show worktrees" : "Attention across all projects")
            Divider().padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(projects) { project in
                        projectButton(project)
                            .overlay(alignment: .top) { if dropTarget == project.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                            .draggable("graftty-project:" + project.id)
                            .dropDestination(for: String.self) { values, location in
                                guard allowsReordering && !showsAttention, let value = values.first, value.hasPrefix("graftty-project:") else { return false }
                                onMove(String(value.dropFirst("graftty-project:".count)), project.id, location.y > 22)
                                return true
                            } isTargeted: { dropTarget = $0 ? project.id : nil }
                    }
                }.padding(.horizontal, 6)
            }
            if collapsed { management() }
            HStack {
                if !collapsed { management(); Spacer() }
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.left")
                        .frame(minWidth: 36, minHeight: 40).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(collapsed && !canExpand)
                    .help(collapsed ? "Expand project rail" : "Collapse project rail")
                    .accessibilityLabel(collapsed ? "Expand project rail" : "Collapse project rail")
            }.padding(.horizontal, 10)
        }
        .frame(width: SidebarLayoutPolicy.railWidth(collapsed: collapsed, expandedWidth: expandedWidth))
        .clipped()
        .overlay(alignment: .trailing) {
            if canExpand { resizeHandle }
        }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .modifier(ResizeCursorModifier(isHorizontal: true))
            .help("Drag to resize or collapse projects")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStartWidth == nil {
                        resizeStartWidth = SidebarLayoutPolicy.railWidth(collapsed: collapsed, expandedWidth: expandedWidth)
                    }
                    let size = SidebarLayoutPolicy.resizedRail(
                        proposedWidth: (resizeStartWidth ?? 196) + value.translation.width,
                        expandedWidth: expandedWidth)
                    expandedWidth = size.expandedWidth
                    collapsed = size.collapsed
                }
                .onEnded { _ in resizeStartWidth = nil })
            .accessibilityLabel("Project rail width")
            .accessibilityValue(collapsed ? "Collapsed" : "\(Int(expandedWidth)) points")
            .accessibilityAdjustableAction { direction in
                let width = SidebarLayoutPolicy.railWidth(collapsed: collapsed, expandedWidth: expandedWidth)
                let proposed = direction == .increment ? max(128, width + 20) : width - 20
                let size = SidebarLayoutPolicy.resizedRail(proposedWidth: proposed, expandedWidth: expandedWidth)
                expandedWidth = size.expandedWidth
                collapsed = size.collapsed
            }
    }
    private func projectButton(_ project: SidebarProject) -> some View {
        Button { onSelect(project) } label: {
            HStack(spacing: 9) {
                ProjectIdentityView(project: project, imageData: icons[project.id])
                    .padding(3)
                    .background(ProjectAccentColor.color(for: project).opacity(showsAttention ? 0.25 : 0.17), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ProjectAccentColor.color(for: project).opacity(showsAttention ? 0.8 : 0.55), lineWidth: showsAttention ? 2 : 1))
                    .opacity(showsAttention && excludedAttentionProjectIDs.contains(project.id) ? 0.35 : 1)
                    .overlay(alignment: .bottomLeading) {
                        if collapsed, let owner = project.owner, owner.deviceID != localDeviceID {
                            Image(systemName: "desktopcomputer").font(.system(size: 8))
                                .padding(2).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(height: 44)
                    .overlay(alignment: .topTrailing) {
                        if !collapsed && expandedWidth < 160 { SidebarActivityBadge(counts[project.id, default: 0]) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !collapsed && expandedWidth < 160 { SidebarActivityBadge(workingCounts[project.id, default: 0], kind: .working) }
                    }
                if !collapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.callout).lineLimit(1)
                        if let subtitle = project.ownerSubtitle(localDeviceID: localDeviceID) {
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if expandedWidth >= 160 {
                        HStack(spacing: 4) {
                            SidebarActivityBadge(workingCounts[project.id, default: 0], kind: .working)
                            SidebarActivityBadge(counts[project.id, default: 0])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .topTrailing) { if collapsed { SidebarActivityBadge(counts[project.id, default: 0]) } }
            .overlay(alignment: .bottomTrailing) { if collapsed { SidebarActivityBadge(workingCounts[project.id, default: 0], kind: .working) } }
            .padding(.horizontal, collapsed ? 0 : 8)
            .contentShape(Rectangle())
            .background(!showsAttention && selectedID == project.id ? selectionColor : showsAttention && !excludedAttentionProjectIDs.contains(project.id) ? ProjectAccentColor.color(for: project).opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .help(project.name + (project.owner.map { " on " + $0.deviceLabel } ?? "") + (project.isAvailable ? "" : " · Offline"))
            .accessibilityLabel(project.name + (showsAttention ? (excludedAttentionProjectIDs.contains(project.id) ? ", excluded from Attention" : ", included in Attention") : "") + ", \(counts[project.id, default: 0]) pending requests, \(workingCounts[project.id, default: 0]) agents working" + (project.owner.map { ", " + $0.deviceLabel } ?? ""))
            .contextMenu {
                if allowsReordering && !showsAttention, let index = projects.firstIndex(where: { $0.id == project.id }) {
                    if index > 0 { Button("Move Up") { onMove(project.id, projects[index-1].id, false) } }
                    if index+1 < projects.count { Button("Move Down") { onMove(project.id, projects[index+1].id, true) } }
                }
                menu(project)
            }
            .accessibilityAction(named: "Move Up") { move(project.id, offset: -1) }
            .accessibilityAction(named: "Move Down") { move(project.id, offset: 1) }
    }
    private func move(_ id: String, offset: Int) {
        guard allowsReordering && !showsAttention, let index = projects.firstIndex(where: { $0.id == id }), projects.indices.contains(index + offset) else { return }
        onMove(id, projects[index + offset].id, offset > 0)
    }
}

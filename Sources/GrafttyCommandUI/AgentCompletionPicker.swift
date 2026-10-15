import SwiftUI

public struct AgentCompletionPicker: View {
    @ObservedObject private var model: AgentCompletionModel

    public init(model: AgentCompletionModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("%" + model.query).font(.system(.callout, design: .monospaced))
                Spacer()
                Button { model.cancel(preserveLiteral: true) } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Insert literal percent token")
            }
            if model.isLoading {
                ProgressView("Finding agents…")
            }
            if !model.candidates.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.candidates) { candidate in
                                Button { model.accept(candidate.id) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(candidate.worktreeName).fontWeight(.medium).lineLimit(1)
                                            Spacer()
                                            Text(candidate.runtime).foregroundStyle(.secondary)
                                        }
                                        Text(candidate.projectName + " · " + candidate.hostName)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedID == candidate.id ? Color.accentColor.opacity(0.18) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(candidate.address)
                                .id(candidate.id)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: model.selectedID) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
            } else if !model.isLoading {
                Text(model.loadFailed ? "Couldn't load agents. Escape inserts the text you typed." : "No matching agents")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(idealWidth: 340, maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent completion")
    }
}

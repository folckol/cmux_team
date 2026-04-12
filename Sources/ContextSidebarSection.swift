import SwiftUI

/// Sidebar view for Team Context.
/// Shows KV entries, documents (with inline expand), and graph entities.
struct ContextSidebarSection: View {
    @ObservedObject var store: ContextStore
    @State private var expandedDocId: String?
    @State private var expandedEntityId: String?
    @State private var copiedKey: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            header
            Divider()

            if !store.isConnected {
                disconnectedBanner
            } else if store.kvEntries.isEmpty && store.documents.isEmpty && store.entities.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // KV Section
                        if !store.kvEntries.isEmpty {
                            sectionBlock(icon: "key.fill", title: "Key-Value", count: store.kvEntries.count) {
                                ForEach(store.kvEntries) { entry in
                                    kvRow(entry)
                                }
                            }
                        }

                        // Documents Section
                        if !store.documents.isEmpty {
                            sectionBlock(icon: "doc.text.fill", title: "Documents", count: store.documents.count) {
                                ForEach(store.documents) { doc in
                                    docRow(doc)
                                    if expandedDocId == doc.id {
                                        docDetail(doc)
                                    }
                                }
                            }
                        }

                        // Graph Section
                        if !store.entities.isEmpty {
                            sectionBlock(icon: "point.3.connected.trianglepath.dotted", title: "Graph", count: store.entities.count) {
                                ForEach(store.entities) { entity in
                                    entityRow(entity)
                                    if expandedEntityId == entity.id {
                                        entityDetail(entity)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.isConnected ? Color.green : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)

            Text("Team Context")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            if store.isConnected {
                Text("\(store.kvEntries.count + store.documents.count + store.entities.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(3)
            }

            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Section block

    private func sectionBlock<Content: View>(icon: String, title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .tracking(0.5)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)

            content()
        }
    }

    // MARK: - KV rows

    private func kvRow(_ entry: ContextKVEntry) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !entry.category.isEmpty {
                        categoryBadge(entry.category)
                    }
                }
                Text(entry.value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Copy button
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.value, forType: .string)
                copiedKey = entry.key
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedKey == entry.key { copiedKey = nil }
                }
            }) {
                Image(systemName: copiedKey == entry.key ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(copiedKey == entry.key ? .green : .secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(0.00001)) // hit target
    }

    // MARK: - Document rows

    private func docRow(_ doc: ContextDocument) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedDocId = expandedDocId == doc.id ? nil : doc.id
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expandedDocId == doc.id ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 10)

                Text(doc.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if !doc.category.isEmpty {
                    categoryBadge(doc.category)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func docDetail(_ doc: ContextDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !doc.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(doc.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue.opacity(0.8))
                            .cornerRadius(2)
                    }
                }
            }

            Text(doc.body)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(12)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(doc.body, forType: .string)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Text("id: \(String(doc.id.prefix(8)))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Entity rows

    private func entityRow(_ entity: ContextEntity) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedEntityId = expandedEntityId == entity.id ? nil : entity.id
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expandedEntityId == entity.id ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 10)

                Image(systemName: iconForEntityType(entity.type))
                    .font(.system(size: 9))
                    .foregroundColor(colorForEntityType(entity.type))
                    .frame(width: 14)

                Text(entity.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Text(entity.type)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func entityDetail(_ entity: ContextEntity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !entity.properties.isEmpty {
                ForEach(Array(entity.properties.keys.sorted()), id: \.self) { key in
                    HStack(spacing: 4) {
                        Text(key)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("=")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("\(String(describing: entity.properties[key]?.value ?? ""))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                    }
                }
            }

            // Show edges for this entity
            let entityEdges = store.edges.filter { $0.sourceId == entity.id || $0.targetId == entity.id }
            if !entityEdges.isEmpty {
                ForEach(entityEdges) { edge in
                    HStack(spacing: 3) {
                        if edge.sourceId == entity.id {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(edge.relation)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.orange.opacity(0.8))
                            Text(entityName(for: edge.targetId))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        } else {
                            Text(entityName(for: edge.sourceId))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(edge.relation)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.orange.opacity(0.8))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
            }

            if entity.properties.isEmpty && entityEdges.isEmpty {
                Text("No properties or connections")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Helpers

    private func categoryBadge(_ category: String) -> some View {
        Text(category)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.secondary.opacity(0.7))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(3)
    }

    private func entityName(for id: String) -> String {
        store.entities.first(where: { $0.id == id })?.name ?? String(id.prefix(8))
    }

    private var disconnectedBanner: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bolt.slash")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Context daemon not running")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text("Start with: cmuxd-context")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
            Button(action: { store.refresh() }) {
                Text("Retry")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.3))
            Text("No context data yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text("cmux context set <key> <value>")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconForEntityType(_ type: String) -> String {
        switch type {
        case "service": return "server.rack"
        case "person": return "person.fill"
        case "task": return "checklist"
        case "decision": return "arrow.triangle.branch"
        case "dependency": return "link"
        default: return "circle.fill"
        }
    }

    private func colorForEntityType(_ type: String) -> Color {
        switch type {
        case "service": return .blue
        case "person": return .green
        case "task": return .orange
        case "decision": return .purple
        case "dependency": return .red
        default: return .gray
        }
    }
}

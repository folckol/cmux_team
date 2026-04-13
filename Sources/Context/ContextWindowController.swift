import AppKit
import SwiftUI

/// Standalone window for the Team Context panel.
/// Uses NSPanel (like Debug Windows) to avoid portal system recursion issues.
final class ContextWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ContextWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Team Context"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.teamContext")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showWithStore(_ store: ContextStore) {
        if window?.contentView == nil || !(window?.contentView is NSHostingView<ContextWindowView>) {
            window?.contentView = NSHostingView(rootView: ContextWindowView(store: store))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle(store: ContextStore) {
        if let w = window, w.isVisible {
            w.close()
        } else {
            showWithStore(store)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // No-op, window persists
    }
}

// MARK: - Full Context Window View

struct ContextWindowView: View {
    @ObservedObject var store: ContextStore
    var projectRoot: String? = nil

    @State private var selectedTab: ContextPanelTab = .keyValue
    @State private var searchQuery = ""
    @State private var selectedDocId: String?
    @State private var selectedEntityId: String?
    @State private var editingDocId: String?
    @State private var editBody = ""
    @State private var isCreatingDoc = false
    @State private var newDocTitle = ""
    @State private var newDocBody = ""
    @State private var newDocCategory = ""
    @State private var newKVKey = ""
    @State private var newKVValue = ""
    @State private var newKVCategory = ""
    @State private var editingKVKey: String?
    @State private var editKVValue = ""
    @State private var editKVCategory = ""
    @State private var selectedCategory: String?
    @State private var newCategoryName = ""
    @State private var newEntityName = ""
    @State private var newEntityType = "service"
    @State private var showingNewProjectSheet = false
    @State private var newProjectName = ""
    @State private var newProjectPassword = ""
    @State private var joinPromptProject: ContextProject?
    @State private var joinPasswordInput = ""
    @State private var joinError = ""
    @State private var passwordSheetProject: ContextProject?
    @State private var passwordSheetInput = ""

    private let entityTypes = ["role", "person", "service", "task", "decision", "dependency"]

    private var allCategories: [String] {
        let cats = Set(store.documents.map(\.category).filter { !$0.isEmpty })
        return cats.sorted()
    }

    /// "default" when nothing is explicitly selected — matches daemon fallback.
    private var effectiveProjectId: String {
        store.currentProjectId.isEmpty ? "default" : store.currentProjectId
    }

    private var isMemberOfCurrentProject: Bool {
        guard let me = store.currentUser else { return false }
        if me.isAdmin { return true }
        return store.currentProjectMembers.contains(where: { $0.userId == me.id })
    }

    private var isGated: Bool {
        store.isUnidentified || store.notAMemberOfCurrentProject
    }

    /// Full-panel banner shown when shared context is not accessible yet.
    /// Must be rendered only when `isGated` is true.
    @ViewBuilder
    private func gateBanner() -> some View {
        if store.isUnidentified {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36)).foregroundColor(.secondary)
                Text("Identify yourself first").font(.system(size: 14, weight: .semibold))
                Text("Open the Users tab → Identify as, set your name and role. Shared context is disabled until you do.")
                    .multilineTextAlignment(.center).font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: 320)
                Button("Go to Users") { selectedTab = .users }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if store.notAMemberOfCurrentProject {
            let proj = store.projects.first(where: { $0.id == effectiveProjectId })
            VStack(spacing: 12) {
                Image(systemName: "lock").font(.system(size: 36)).foregroundColor(.secondary)
                Text("You haven't joined this project").font(.system(size: 14, weight: .semibold))
                Text("“\(proj?.name ?? effectiveProjectId)” is private. Ask the owner for the password, or pick a different project from the header picker.")
                    .multilineTextAlignment(.center).font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: 360)
                if let proj {
                    Button("Enter password…") {
                        joinPromptProject = proj
                        joinPasswordInput = ""
                        joinError = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    /// Decide whether we can switch in-place or must prompt for the project
    /// password. Admins and already-joined users go through directly.
    private func attemptSwitchProject(_ project: ContextProject) {
        // No identity yet → user can't use context at all, no point in switching.
        if store.isUnidentified {
            store.switchProject(id: project.id)
            return
        }
        if store.isCurrentUserAdmin {
            store.switchProject(id: project.id)
            return
        }
        // Check membership against daemon data we already have cached.
        let iAmMember = project.id == effectiveProjectId
            ? isMemberOfCurrentProject
            : false
        if iAmMember {
            store.switchProject(id: project.id)
            return
        }
        // If the project has no password, join is free.
        if !project.hasPassword {
            store.joinProject(id: project.id, password: "")
            return
        }
        // Gate with password sheet.
        joinPromptProject = project
        joinPasswordInput = ""
        joinError = ""
    }

    private var docsInSelectedCategory: [ContextDocument] {
        guard let cat = selectedCategory else { return store.documents }
        if cat == "__uncategorized__" {
            return store.documents.filter { $0.category.isEmpty }
        }
        return store.documents.filter { $0.category == cat }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar + search
            HStack(spacing: 2) {
                ForEach(ContextPanelTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.iconName).font(.system(size: 11))
                            Text(tab.localizedTitle).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear))
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Project selector
                Menu {
                    ForEach(store.projects) { p in
                        Button(action: { attemptSwitchProject(p) }) {
                            HStack {
                                Text(p.name)
                                if p.hasPassword { Image(systemName: "lock") }
                                if p.id == effectiveProjectId { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if !store.projects.isEmpty { Divider() }
                    Button(action: {
                        newProjectName = ""
                        newProjectPassword = ""
                        showingNewProjectSheet = true
                    }) {
                        Label("New project…", systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(store.currentProjectName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.3)).cornerRadius(4)
                    .frame(maxWidth: 160)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                    TextField("Search...", text: $searchQuery)
                        .textFieldStyle(.plain).font(.system(size: 11)).frame(maxWidth: 150)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3)).cornerRadius(4)

                Circle().fill(store.isConnected ? Color.green : Color.red).frame(width: 6, height: 6)
                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()

            // Content
            if isGated && selectedTab != .settings && selectedTab != .users {
                gateBanner()
            } else {
                switch selectedTab {
                case .keyValue: kvView
                case .documents: docsView
                case .graph: graphView
                case .users: usersView
                case .settings: settingsView
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showingNewProjectSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New project").font(.headline)
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                SecureField("Project password (required to join)", text: $newProjectPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                Text("Teammates will need this password the first time they pick this project. You can leave it empty to create an open project and set a password later from Settings.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .frame(width: 300, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Cancel") { showingNewProjectSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let name = newProjectName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let pwd = newProjectPassword
                        store.createProject(name: name) { result in
                            if case .success(let p) = result, !pwd.isEmpty {
                                store.setProjectPassword(id: p.id, password: pwd)
                            }
                        }
                        showingNewProjectSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
        .sheet(item: $joinPromptProject) { project in
            VStack(alignment: .leading, spacing: 12) {
                Text("Join “\(project.name)”").font(.headline)
                Text("This project is password-protected. Enter the password from the project owner to access its shared context.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(width: 320, alignment: .leading)
                SecureField("Password", text: $joinPasswordInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                if !joinError.isEmpty {
                    Text(joinError).font(.system(size: 11)).foregroundColor(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { joinPromptProject = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Join") {
                        joinError = ""
                        let pwd = joinPasswordInput
                        store.joinProject(id: project.id, password: pwd) { result in
                            switch result {
                            case .success:
                                joinPromptProject = nil
                            case .failure(let err):
                                if case .serverError(let code, let msg) = err {
                                    joinError = code == "wrong_password" ? "Incorrect password" : msg
                                } else {
                                    joinError = err.localizedDescription
                                }
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(joinPasswordInput.isEmpty)
                }
            }
            .padding(16)
        }
        .sheet(item: $passwordSheetProject) { project in
            VStack(alignment: .leading, spacing: 12) {
                Text("Set password for “\(project.name)”").font(.headline)
                Text("Any user who picks this project for the first time will need this password. Leave empty to remove the password (open project).")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(width: 320, alignment: .leading)
                SecureField("New password (empty = remove)", text: $passwordSheetInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("Cancel") { passwordSheetProject = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        store.setProjectPassword(id: project.id, password: passwordSheetInput)
                        passwordSheetProject = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .onAppear { store.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            store.refreshProjects()
            store.refreshLocks()
            store.refreshKV()
            store.refreshDocs()
            store.refreshEntities()
            store.refreshEdges()
            if selectedTab == .users {
                store.refreshUsers()
                store.refreshEvents()
            }
        }
    }

    // MARK: - KV

    private var filteredKV: [ContextKVEntry] {
        guard !searchQuery.isEmpty else { return store.kvEntries }
        let q = searchQuery.lowercased()
        return store.kvEntries.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
    }

    private var kvView: some View {
        VStack(spacing: 0) {
            List {
                ForEach(filteredKV) { entry in
                    if editingKVKey == entry.key {
                        // Inline edit mode
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            TextField("Value", text: $editKVValue)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            HStack(spacing: 4) {
                                TextField("Category", text: $editKVCategory)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 10)).frame(maxWidth: 100)
                                Spacer()
                                Button("Cancel") {
                                    store.releaseLock(kind: "kv", targetId: entry.key)
                                    editingKVKey = nil
                                }
                                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
                                Button("Save") {
                                    store.setKV(key: entry.key, value: editKVValue, category: editKVCategory)
                                    store.releaseLock(kind: "kv", targetId: entry.key)
                                    editingKVKey = nil
                                }
                                .font(.system(size: 10, weight: .medium))
                                .keyboardShortcut(.return, modifiers: .command)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Display mode
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(entry.key).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    if !entry.category.isEmpty {
                                        Text(entry.category).font(.system(size: 8, weight: .medium))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.1)).cornerRadius(3).foregroundColor(.secondary)
                                    }
                                }
                                Text(entry.value).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).lineLimit(2)
                                let who = authorLabel(entry.updatedBy ?? "", entry.createdBy)
                                if !who.isEmpty {
                                    Text(who).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                                }
                            }
                            Spacer()
                            if let holder = store.lockHolder(kind: "kv", targetId: entry.key), holder.userId != store.currentAuthorId {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(.orange)
                                    Text(holder.userName).font(.system(size: 9)).foregroundColor(.orange)
                                }
                                .help("Being edited by \(holder.userName)")
                            } else {
                                Button(action: {
                                    store.acquireLock(kind: "kv", targetId: entry.key) { ok, err in
                                        if ok {
                                            editingKVKey = entry.key; editKVValue = entry.value; editKVCategory = entry.category
                                        } else if let err { store.lastError = err }
                                    }
                                }) {
                                    Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                                }.buttonStyle(.plain)
                            }
                            Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.value, forType: .string) }) {
                                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                            }.buttonStyle(.plain)
                            Button(action: { store.deleteKV(key: entry.key) }) {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red.opacity(0.4))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 4) {
                TextField("Key", text: $newKVKey).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(maxWidth: 140)
                TextField("Value", text: $newKVValue).textFieldStyle(.roundedBorder).font(.system(size: 11))
                TextField("Category", text: $newKVCategory).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(maxWidth: 80)
                Button("Add") {
                    guard !newKVKey.isEmpty else { return }
                    store.setKV(key: newKVKey, value: newKVValue, category: newKVCategory)
                    newKVKey = ""; newKVValue = ""; newKVCategory = ""
                }.disabled(newKVKey.isEmpty)
            }.padding(8)
        }
    }

    // MARK: - Documents


    private var docsView: some View {
        HStack(spacing: 0) {
            // Left panel: categories or docs within category
            VStack(spacing: 0) {
                if selectedCategory == nil {
                    // Category list
                    categoryListView
                } else {
                    // Docs in category
                    docsInCategoryListView
                }

                Divider()
                HStack {
                    Button(action: { isCreatingDoc = true; selectedDocId = nil }) {
                        HStack(spacing: 3) { Image(systemName: "plus"); Text("New") }.font(.system(size: 11))
                    }.buttonStyle(.plain)
                    Spacer()
                }.padding(6)
            }
            .frame(width: 250)

            Divider()

            // Right: doc detail or create form
            if isCreatingDoc {
                createDocForm
            } else if let docId = selectedDocId, let doc = store.documents.first(where: { $0.id == docId }) {
                docDetail(doc)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.3))
                    Text(selectedCategory == nil ? "Select a category" : "Select a document").foregroundColor(.secondary).font(.system(size: 12))
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Category list

    private var categoryListView: some View {
        List {
            // Named categories
            ForEach(allCategories, id: \.self) { cat in
                let count = store.documents.filter { $0.category == cat }.count
                Button(action: { selectedCategory = cat; selectedDocId = nil }) {
                    HStack {
                        Image(systemName: "folder.fill").font(.system(size: 12)).foregroundColor(.accentColor.opacity(0.7))
                        Text(cat).font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
                        Spacer()
                        Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete category (keeps docs)") {
                        // Move all docs in this category to uncategorized
                        for doc in store.documents where doc.category == cat {
                            store.updateDoc(id: doc.id, category: "")
                        }
                    }
                }
            }

            // Uncategorized
            let uncatCount = store.documents.filter { $0.category.isEmpty }.count
            if uncatCount > 0 {
                Button(action: { selectedCategory = "__uncategorized__"; selectedDocId = nil }) {
                    HStack {
                        Image(systemName: "folder").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.5))
                        Text("Uncategorized").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(uncatCount)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }

            // All documents shortcut
            Button(action: { selectedCategory = "__all__"; selectedDocId = nil }) {
                HStack {
                    Image(systemName: "tray.full.fill").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.5))
                    Text("All Documents").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Text("\(store.documents.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Docs in category

    private var docsInCategoryListView: some View {
        VStack(spacing: 0) {
            // Back button + category name
            HStack(spacing: 4) {
                Button(action: { selectedCategory = nil; selectedDocId = nil }) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Back").font(.system(size: 11))
                    }.foregroundColor(.accentColor)
                }.buttonStyle(.plain)
                Spacer()
                Text(categoryDisplayName(selectedCategory))
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider()

            let docs = docsForCurrentCategory
            List(docs, selection: $selectedDocId) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Text(relativeDate(doc.updatedAt)).font(.system(size: 9)).foregroundColor(.secondary)
                        let who = authorLabel(doc.updatedBy ?? "", doc.createdBy)
                        if !who.isEmpty {
                            Text("·").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                            Text(who).font(.system(size: 9)).foregroundColor(.accentColor.opacity(0.8))
                        }
                    }
                }
                .tag(doc.id)
                .contextMenu { Button("Delete") { store.deleteDoc(id: doc.id) } }
            }
        }
    }

    private var docsForCurrentCategory: [ContextDocument] {
        guard let cat = selectedCategory else { return [] }
        let q = searchQuery.lowercased()
        var docs: [ContextDocument]
        if cat == "__all__" {
            docs = store.documents
        } else if cat == "__uncategorized__" {
            docs = store.documents.filter { $0.category.isEmpty }
        } else {
            docs = store.documents.filter { $0.category == cat }
        }
        if !q.isEmpty {
            docs = docs.filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
        }
        return docs
    }

    private func categoryDisplayName(_ cat: String?) -> String {
        guard let cat else { return "" }
        if cat == "__uncategorized__" { return "Uncategorized" }
        if cat == "__all__" { return "All Documents" }
        return cat
    }

    // MARK: - Create doc form

    private var createDocForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("New Document").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { isCreatingDoc = false }.font(.system(size: 11)).buttonStyle(.plain)
            }
            TextField("Title", text: $newDocTitle).textFieldStyle(.roundedBorder)

            // Category picker
            HStack(spacing: 8) {
                Text("Category:").font(.system(size: 11)).foregroundColor(.secondary)
                if allCategories.isEmpty {
                    TextField("New category", text: $newDocCategory).textFieldStyle(.roundedBorder).font(.system(size: 11))
                } else {
                    Picker("", selection: $newDocCategory) {
                        Text("None").tag("")
                        ForEach(allCategories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                        Text("New...").tag("__new__")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    if newDocCategory == "__new__" {
                        TextField("Category name", text: $newCategoryName)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(maxWidth: 120)
                    }
                }
            }

            TextEditor(text: $newDocBody).font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100)
            HStack {
                Spacer()
                Text("Cmd+Enter to save").font(.system(size: 9)).foregroundColor(.secondary)
                Button("Save") {
                    let cat = newDocCategory == "__new__" ? newCategoryName : newDocCategory
                    store.createDoc(title: newDocTitle, body: newDocBody, category: cat)
                    isCreatingDoc = false; newDocTitle = ""; newDocBody = ""
                    newDocCategory = selectedCategory ?? ""; newCategoryName = ""
                }.disabled(newDocTitle.isEmpty).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .onAppear {
            // Pre-select current category when creating from within a category
            if let cat = selectedCategory, cat != "__uncategorized__" && cat != "__all__" {
                newDocCategory = cat
            }
        }
    }

    // MARK: - Doc detail

    private func docDetail(_ doc: ContextDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(doc.title).font(.system(size: 14, weight: .semibold))
                if !doc.category.isEmpty {
                    Text(doc.category).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1)).cornerRadius(3).foregroundColor(.secondary)
                }
                let uid = (doc.updatedBy?.isEmpty == false ? doc.updatedBy! : doc.createdBy)
                if !uid.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(colorForUser(uid)).frame(width: 8, height: 8)
                        Text(userNameFor(uid)).font(.system(size: 10))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(colorForUser(uid).opacity(0.15)).cornerRadius(4)
                }
                Spacer()
                if editingDocId == doc.id {
                    Button("Cancel") {
                        store.releaseLock(kind: "doc", targetId: doc.id); editingDocId = nil
                    }.font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.secondary)
                    Button("Save") {
                        store.updateDoc(id: doc.id, body: editBody)
                        store.releaseLock(kind: "doc", targetId: doc.id)
                        editingDocId = nil
                    }.font(.system(size: 11, weight: .medium)).keyboardShortcut(.return, modifiers: .command)
                } else if let holder = store.lockHolder(kind: "doc", targetId: doc.id), holder.userId != store.currentAuthorId {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").foregroundColor(.orange)
                        Text("Editing: \(holder.userName)").font(.system(size: 11)).foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12)).cornerRadius(4)
                } else {
                    Button(action: {
                        store.acquireLock(kind: "doc", targetId: doc.id) { ok, err in
                            if ok { editingDocId = doc.id; editBody = doc.body }
                            else if let err { store.lastError = err }
                        }
                    }) {
                        HStack(spacing: 3) { Image(systemName: "pencil"); Text("Edit") }.font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12)).cornerRadius(4)
                    }.buttonStyle(.plain)
                    Button(action: { store.deleteDoc(id: doc.id); selectedDocId = nil }) {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.red.opacity(0.5))
                    }.buttonStyle(.plain)
                }
            }.padding(10)

            Divider()

            if editingDocId == doc.id {
                TextEditor(text: $editBody).font(.system(size: 12, design: .monospaced)).padding(4)
            } else {
                ScrollView {
                    blamedBody(doc).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                blameLegend(doc).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }

    // MARK: - Graph

    private var filteredEntities: [ContextEntity] {
        guard !searchQuery.isEmpty else { return store.entities }
        let q = searchQuery.lowercased()
        return store.entities.filter { $0.name.lowercased().contains(q) || $0.type.lowercased().contains(q) }
    }

    @State private var addingConnectionForEntityId: String?
    @State private var newConnectionTarget = ""
    @State private var newConnectionRelation = "has_role"

    private var roles: [ContextEntity] { store.entities.filter { $0.type == "role" } }
    private var people: [ContextEntity] { store.entities.filter { $0.type == "person" } }
    private var services: [ContextEntity] { store.entities.filter { $0.type == "service" } }
    private var otherEntities: [ContextEntity] { store.entities.filter { !["role", "person", "service"].contains($0.type) } }

    private var graphView: some View {
        HStack(spacing: 0) {
            // Left: grouped entity list
            VStack(spacing: 0) {
                List(selection: $selectedEntityId) {
                    // Roles section
                    if !roles.isEmpty || !searchQuery.isEmpty {
                        Section(header: HStack {
                            Image(systemName: "shield.fill").font(.system(size: 9)).foregroundColor(.purple)
                            Text("ROLES").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        }) {
                            ForEach(filterEntities(roles)) { entity in
                                entityListRow(entity).tag(entity.id)
                            }
                        }
                    }

                    // People section
                    if !people.isEmpty || !searchQuery.isEmpty {
                        Section(header: HStack {
                            Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(.green)
                            Text("PEOPLE").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        }) {
                            ForEach(filterEntities(people)) { entity in
                                entityListRow(entity).tag(entity.id)
                            }
                        }
                    }

                    // Services section
                    if !services.isEmpty || !searchQuery.isEmpty {
                        Section(header: HStack {
                            Image(systemName: "server.rack").font(.system(size: 9)).foregroundColor(.blue)
                            Text("SERVICES").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        }) {
                            ForEach(filterEntities(services)) { entity in
                                entityListRow(entity).tag(entity.id)
                            }
                        }
                    }

                    // Other entities
                    if !otherEntities.isEmpty {
                        Section(header: Text("OTHER").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)) {
                            ForEach(filterEntities(otherEntities)) { entity in
                                entityListRow(entity).tag(entity.id)
                            }
                        }
                    }
                }

                Divider()

                // Add entity bar
                HStack(spacing: 4) {
                    Picker("", selection: $newEntityType) {
                        Text("role").tag("role")
                        Text("person").tag("person")
                        Text("service").tag("service")
                        ForEach(entityTypes.filter { !["role", "person", "service"].contains($0) }, id: \.self) {
                            Text($0).tag($0)
                        }
                    }.frame(maxWidth: 100).labelsHidden()
                    TextField("Name", text: $newEntityName).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("Add") {
                        store.createEntity(type: newEntityType, name: newEntityName); newEntityName = ""
                    }.disabled(newEntityName.isEmpty)
                }.padding(6)
            }
            .frame(width: 260)

            Divider()

            // Right: entity detail
            if let eid = selectedEntityId, let entity = store.entities.first(where: { $0.id == eid }) {
                entityDetail(entity)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.3))
                    Text("Select an entity").foregroundColor(.secondary).font(.system(size: 12))
                    Text("Add roles, people, services").foregroundColor(.secondary.opacity(0.5)).font(.system(size: 10))
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private func filterEntities(_ list: [ContextEntity]) -> [ContextEntity] {
        guard !searchQuery.isEmpty else { return list }
        let q = searchQuery.lowercased()
        return list.filter { $0.name.lowercased().contains(q) }
    }

    private func entityListRow(_ entity: ContextEntity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconFor(entity.type)).foregroundColor(colorFor(entity.type)).font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.name).font(.system(size: 12, weight: .medium))
                // Show connected entities preview
                let connections = store.edges.filter { $0.sourceId == entity.id || $0.targetId == entity.id }
                if !connections.isEmpty {
                    Text("\(connections.count) connections").font(.system(size: 8)).foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .contextMenu { Button("Delete") { store.deleteEntity(id: entity.id) } }
    }

    private func entityDetail(_ entity: ContextEntity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: iconFor(entity.type)).foregroundColor(colorFor(entity.type)).font(.system(size: 14))
                    Text(entity.name).font(.system(size: 16, weight: .semibold))
                    Text(entity.type).font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(colorFor(entity.type).opacity(0.12)).cornerRadius(4).foregroundColor(colorFor(entity.type))
                    Spacer()
                    Button(action: { store.deleteEntity(id: entity.id); selectedEntityId = nil }) {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.red.opacity(0.5))
                    }.buttonStyle(.plain)
                }

                // Properties
                if !entity.properties.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PROPERTIES").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        ForEach(Array(entity.properties.keys.sorted()), id: \.self) { key in
                            HStack(spacing: 4) {
                                Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                                Text("=").foregroundColor(.secondary.opacity(0.4)).font(.system(size: 11))
                                Text("\(String(describing: entity.properties[key]?.value ?? ""))").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Connections
                let entityEdges = store.edges.filter { $0.sourceId == entity.id || $0.targetId == entity.id }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CONNECTIONS").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        Spacer()
                        Button(action: { addingConnectionForEntityId = entity.id }) {
                            HStack(spacing: 2) { Image(systemName: "plus"); Text("Add") }
                                .font(.system(size: 10)).foregroundColor(.accentColor)
                        }.buttonStyle(.plain)
                    }

                    if entityEdges.isEmpty && addingConnectionForEntityId != entity.id {
                        Text("No connections yet").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                    }

                    ForEach(entityEdges) { edge in
                        let isSource = edge.sourceId == entity.id
                        let otherName = isSource ? entityName(edge.targetId) : entityName(edge.sourceId)
                        let otherEntity = store.entities.first { $0.id == (isSource ? edge.targetId : edge.sourceId) }

                        HStack(spacing: 6) {
                            Image(systemName: iconFor(otherEntity?.type ?? "")).font(.system(size: 9))
                                .foregroundColor(colorFor(otherEntity?.type ?? "")).frame(width: 14)
                            Text(otherName).font(.system(size: 11, weight: .medium))
                            Text(edge.relation).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12)).cornerRadius(3).foregroundColor(.orange)
                            Spacer()
                            Button(action: { store.deleteEdge(id: edge.id) }) {
                                Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(.secondary.opacity(0.4))
                            }.buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    // Add connection form
                    if addingConnectionForEntityId == entity.id {
                        Divider().padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New Connection").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Picker("Target", selection: $newConnectionTarget) {
                                    Text("Select...").tag("")
                                    ForEach(store.entities.filter { $0.id != entity.id }) { e in
                                        HStack {
                                            Image(systemName: iconFor(e.type))
                                            Text("\(e.name) (\(e.type))")
                                        }.tag(e.id)
                                    }
                                }.labelsHidden().frame(maxWidth: 200)

                                Picker("Relation", selection: $newConnectionRelation) {
                                    Text("has_role").tag("has_role")
                                    Text("owns").tag("owns")
                                    Text("depends_on").tag("depends_on")
                                    Text("maintains").tag("maintains")
                                    Text("uses").tag("uses")
                                    Text("reports_to").tag("reports_to")
                                }.labelsHidden().frame(maxWidth: 120)
                            }
                            HStack {
                                Spacer()
                                Button("Cancel") { addingConnectionForEntityId = nil }
                                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
                                Button("Add Connection") {
                                    guard !newConnectionTarget.isEmpty else { return }
                                    store.createEdge(sourceId: entity.id, targetId: newConnectionTarget, relation: newConnectionRelation)
                                    addingConnectionForEntityId = nil; newConnectionTarget = ""
                                }
                                .font(.system(size: 10, weight: .medium))
                                .disabled(newConnectionTarget.isEmpty)
                            }
                        }
                        .padding(8).background(Color.primary.opacity(0.03)).cornerRadius(4)
                    }
                }

                // Role-specific: show who has this role
                if entity.type == "role" {
                    let assignedEdges = store.edges.filter { $0.targetId == entity.id && $0.relation == "has_role" }
                    if !assignedEdges.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ASSIGNED PEOPLE").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                            ForEach(assignedEdges) { edge in
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(.green)
                                    Text(entityName(edge.sourceId)).font(.system(size: 11, weight: .medium))
                                }
                            }
                        }
                    }
                }

                // Person-specific: show their roles
                if entity.type == "person" {
                    let roleEdges = store.edges.filter { $0.sourceId == entity.id && $0.relation == "has_role" }
                    if !roleEdges.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROLES").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                            ForEach(roleEdges) { edge in
                                HStack(spacing: 4) {
                                    Image(systemName: "shield.fill").font(.system(size: 9)).foregroundColor(.purple)
                                    Text(entityName(edge.targetId)).font(.system(size: 11, weight: .medium))
                                }
                            }
                        }
                    }
                }

                Spacer()
            }.padding(12)
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "service": return "server.rack"
        case "person": return "person.fill"
        case "role": return "shield.fill"
        case "task": return "checklist"
        case "decision": return "arrow.triangle.branch"
        case "dependency": return "link"
        default: return "circle.fill"
        }
    }

    // MARK: - Helpers

    private func entityName(_ id: String) -> String {
        store.entities.first { $0.id == id }?.name ?? String(id.prefix(8))
    }

    private func colorFor(_ type: String) -> Color {
        switch type {
        case "service": return .blue; case "person": return .green; case "role": return .purple
        case "task": return .orange; case "decision": return .indigo; case "dependency": return .red
        default: return .gray
        }
    }

    // MARK: - Settings

    // MARK: - Users tab

    @State private var newUserName = ""
    @State private var newUserRole = ""
    @State private var newUserEmail = ""

    private var usersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Current identity
                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT IDENTITY").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                    if let me = store.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill").foregroundColor(.accentColor).font(.system(size: 20))
                            VStack(alignment: .leading) {
                                Text(me.name).font(.system(size: 13, weight: .medium))
                                Text(me.role.isEmpty ? "no role" : me.role).font(.system(size: 11)).foregroundColor(.secondary)
                                Text("id: \(me.id.prefix(8))").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary.opacity(0.6))
                            }
                            Spacer()
                        }
                        .padding(8).background(Color.accentColor.opacity(0.08)).cornerRadius(6)
                    } else {
                        Text("Not identified — changes you make won't be attributed").font(.system(size: 11)).foregroundColor(.orange)
                    }
                }

                Divider()

                // Identify as...
                VStack(alignment: .leading, spacing: 8) {
                    Text("IDENTIFY AS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                    TextField("Your name", text: $newUserName).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("Role (e.g. frontend, backend)", text: $newUserRole).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    TextField("Email (optional)", text: $newUserEmail).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button(store.currentUser == nil ? "Identify" : "Update") {
                        guard !newUserName.isEmpty else { return }
                        store.identifyAs(name: newUserName, role: newUserRole, email: newUserEmail)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .disabled(newUserName.isEmpty)
                }

                Divider()

                // Team members
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TEAM (\(store.users.count))").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        Spacer()
                        Button { store.refreshUsers() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(.plain)
                    }
                    if store.users.isEmpty {
                        Text("No team members yet").font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        ForEach(store.users) { u in
                            HStack {
                                Image(systemName: u.isAdmin ? "star.fill" : "person.fill")
                                    .foregroundColor(u.isAdmin ? .yellow : .secondary)
                                    .font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(u.name).font(.system(size: 12))
                                        if u.isAdmin {
                                            Text("ADMIN").font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.yellow)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Color.yellow.opacity(0.15)).cornerRadius(3)
                                        }
                                    }
                                    if !u.role.isEmpty {
                                        Text(u.role).font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if u.id == store.currentUser?.id {
                                    Text("you").font(.system(size: 9)).foregroundColor(.green)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.green.opacity(0.15)).cornerRadius(3)
                                }
                                // Admin-only controls.
                                if store.isCurrentUserAdmin && u.id != store.currentUser?.id {
                                    Button(u.isAdmin ? "Revoke admin" : "Make admin") {
                                        store.setUserAdmin(id: u.id, isAdmin: !u.isAdmin)
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }

                Divider()

                // Recent activity
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RECENT ACTIVITY").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        Spacer()
                        Button { store.refreshEvents() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }.buttonStyle(.plain)
                    }
                    if store.events.isEmpty {
                        Text("No recent changes").font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        ForEach(store.events) { e in
                            let authorName = store.users.first { $0.id == e.userId }?.name ?? String(e.userId.prefix(8))
                            HStack(alignment: .top, spacing: 6) {
                                Text(relativeDate(e.ts)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                                Text(authorName).font(.system(size: 10, weight: .medium))
                                Text("\(e.action) \(e.kind)").font(.system(size: 10)).foregroundColor(.secondary)
                                Text(e.summary).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Active locks
                if !store.locks.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BEING EDITED NOW").font(.system(size: 10, weight: .bold)).foregroundColor(.orange).tracking(0.5)
                        ForEach(store.locks) { lock in
                            HStack {
                                Image(systemName: "lock.fill").foregroundColor(.orange).font(.system(size: 10))
                                Text("\(lock.kind):\(lock.targetId.prefix(16))").font(.system(size: 10, design: .monospaced))
                                Spacer()
                                Text("by \(lock.userName)").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .onAppear {
                store.refreshUsers()
                store.refreshEvents()
                store.refreshLocks()
            }
        }
    }

    @State private var connectionMode = "local" // "local" or "remote"
    @State private var remoteHost = ""
    @State private var remotePort = "9876"
    @State private var remoteToken = ""
    @State private var connectionStatus = ""
    @State private var didLoadProjectConfig = false
    @State private var systemPromptText = ""
    @State private var systemPromptDirty = false
    @State private var systemPromptSaved = false

    private func loadFieldsFromProject() {
        guard !didLoadProjectConfig else { return }
        didLoadProjectConfig = true
        if let root = projectRoot, let cfg = ContextStore.loadProjectConfig(projectRoot: root) {
            connectionMode = cfg.mode
            remoteHost = cfg.host
            remotePort = String(cfg.port)
            remoteToken = cfg.token
        } else {
            connectionMode = "local"
            remoteHost = ""
            remotePort = "9876"
            remoteToken = ""
        }
        if let root = projectRoot {
            systemPromptText = ContextStore.loadSystemPrompt(projectRoot: root)
        } else {
            systemPromptText = ContextStore.defaultSystemPrompt
        }
        systemPromptDirty = false
    }

    private func saveSystemPrompt() {
        guard let root = projectRoot else { return }
        do {
            try ContextStore.saveSystemPrompt(projectRoot: root, text: systemPromptText)
            systemPromptDirty = false
            systemPromptSaved = true
        } catch {
            store.lastError = "Save prompt failed: \(error.localizedDescription)"
        }
    }

    private func resetSystemPrompt() {
        systemPromptText = ContextStore.defaultSystemPrompt
        systemPromptDirty = true
    }

    private func saveProjectConfigIfPossible(mode: String, host: String, port: Int, token: String) {
        guard let root = projectRoot, !root.isEmpty else { return }
        let cfg = ContextStore.ProjectConfig(mode: mode, host: host, port: port, token: token)
        do {
            try ContextStore.saveProjectConfig(projectRoot: root, config: cfg)
        } catch {
            connectionStatus = "Saved config failed: \(error.localizedDescription)"
        }
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear.frame(height: 0).onAppear { loadFieldsFromProject() }
                // Connection settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONNECTION").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)

                    Picker("Mode:", selection: $connectionMode) {
                        Text("Local (Unix socket)").tag("local")
                        Text("Remote (TCP server)").tag("remote")
                    }
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 12))

                    if connectionMode == "remote" {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading) {
                                    Text("Host").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                                    TextField("e.g. context.myteam.dev", text: $remoteHost)
                                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                }
                                VStack(alignment: .leading) {
                                    Text("Port").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                                    TextField("9876", text: $remotePort)
                                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 80)
                                }
                            }
                            VStack(alignment: .leading) {
                                Text("Token").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                                SecureField("Authentication token", text: $remoteToken)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                            }
                        }
                        .padding(.leading, 4)
                    }

                    HStack {
                        Button(connectionMode == "local" ? "Connect Local" : "Connect Remote") {
                            if connectionMode == "local" {
                                store.connectToLocal()
                                connectionStatus = "Connected to local daemon"
                                saveProjectConfigIfPossible(mode: "local", host: "", port: 0, token: "")
                            } else {
                                guard !remoteHost.isEmpty, let port = Int(remotePort), !remoteToken.isEmpty else {
                                    connectionStatus = "Fill in all fields"
                                    return
                                }
                                store.connectToServer(host: remoteHost, port: port, token: remoteToken)
                                connectionStatus = "Connecting to \(remoteHost):\(port)..."
                                saveProjectConfigIfPossible(mode: "remote", host: remoteHost, port: port, token: remoteToken)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))

                        if store.isConnected {
                            Text("Connected").font(.system(size: 10)).foregroundColor(.green)
                        } else if let err = store.lastError, !err.isEmpty {
                            Text(err).font(.system(size: 10)).foregroundColor(.red)
                                .lineLimit(2).textSelection(.enabled)
                        } else if !connectionStatus.isEmpty {
                            Text(connectionStatus).font(.system(size: 10)).foregroundColor(.orange)
                        }
                    }
                }

                Divider()

                // Server setup instructions
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOSTING A SERVER").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)

                    Text("To share context with your team, run the daemon with TCP mode:")
                        .font(.system(size: 11)).foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("cmuxd-context -tcp 0.0.0.0:9876 -token <your-secret-token>")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }

                    Text("Share the host, port, and token with team members.")
                        .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))

                    if let root = projectRoot, !root.isEmpty {
                        Text("Project config: \(root)/.cmux_team/connection.json")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .textSelection(.enabled)
                    } else {
                        Text("No project directory — config saved only in user defaults.")
                            .font(.system(size: 10)).foregroundColor(.orange.opacity(0.8))
                    }
                }

                Divider()

                // Data management
                VStack(alignment: .leading, spacing: 8) {
                    Text("DATA").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("KV Entries: \(store.kvEntries.count)").font(.system(size: 11))
                            Text("Documents: \(store.documents.count)").font(.system(size: 11))
                            Text("Entities: \(store.entities.count)").font(.system(size: 11))
                            Text("Edges: \(store.edges.count)").font(.system(size: 11))
                        }.foregroundColor(.secondary)

                        Spacer()

                        Button("Export JSON") {
                            // TODO: save dialog
                        }.font(.system(size: 11))
                    }
                }

                Divider()

                // Projects management
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PROJECTS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        Spacer()
                        Button(action: {
                            newProjectName = ""
                            showingNewProjectSheet = true
                        }) {
                            Label("New", systemImage: "plus").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundColor(.accentColor)
                    }
                    Text("One connection can hold multiple projects. Data in each project is isolated.")
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    if store.projects.isEmpty {
                        Text("No projects yet").font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        ForEach(store.projects) { p in
                            HStack(spacing: 8) {
                                Button(action: { store.switchProject(id: p.id) }) {
                                    Image(systemName: p.id == effectiveProjectId ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(p.id == effectiveProjectId ? .accentColor : .secondary)
                                }.buttonStyle(.plain)

                                Text(p.name).font(.system(size: 11, weight: p.id == effectiveProjectId ? .semibold : .regular))

                                Text(p.id == "default" ? "(built-in)" : String(p.id.prefix(8)))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.6))

                                Spacer()

                                // Set/change/remove password: owner or admin only.
                                let canManage = store.isCurrentUserAdmin
                                    || (store.currentUser?.id == p.createdBy)
                                if canManage {
                                    Button(action: {
                                        passwordSheetProject = p
                                        passwordSheetInput = ""
                                    }) {
                                        Image(systemName: p.hasPassword ? "lock.fill" : "lock.open").font(.system(size: 10))
                                    }.buttonStyle(.plain).foregroundColor(p.hasPassword ? .yellow : .secondary)
                                        .help(p.hasPassword ? "Change/remove password" : "Set password")
                                }

                                if p.id != "default" {
                                    Button(action: {
                                        let alert = NSAlert()
                                        alert.messageText = "Rename project"
                                        alert.informativeText = "New name for \"\(p.name)\":"
                                        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                                        field.stringValue = p.name
                                        alert.accessoryView = field
                                        alert.addButton(withTitle: "Rename")
                                        alert.addButton(withTitle: "Cancel")
                                        if alert.runModal() == .alertFirstButtonReturn {
                                            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
                                            if !trimmed.isEmpty { store.renameProject(id: p.id, name: trimmed) }
                                        }
                                    }) {
                                        Image(systemName: "pencil").font(.system(size: 10))
                                    }.buttonStyle(.plain).foregroundColor(.secondary)

                                    Button(action: {
                                        let alert = NSAlert()
                                        alert.messageText = "Delete project \"\(p.name)\"?"
                                        alert.informativeText = "All KV entries, docs, entities, edges, and events in this project will be permanently deleted."
                                        alert.alertStyle = .warning
                                        alert.addButton(withTitle: "Delete")
                                        alert.addButton(withTitle: "Cancel")
                                        if alert.runModal() == .alertFirstButtonReturn {
                                            store.deleteProject(id: p.id)
                                        }
                                    }) {
                                        Image(systemName: "trash").font(.system(size: 10))
                                    }.buttonStyle(.plain).foregroundColor(.red.opacity(0.7))
                                }
                            }
                        }
                    }
                }

                Divider()

                // System prompt editor
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("SYSTEM PROMPT FOR AGENTS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
                        Spacer()
                        if systemPromptDirty {
                            Text("unsaved").font(.system(size: 9)).foregroundColor(.orange)
                        } else if systemPromptSaved {
                            Text("saved").font(.system(size: 9)).foregroundColor(.green)
                        }
                    }

                    Text("This prompt is injected into every Claude session started in this project. Rules here tell the agent how to keep the team context in sync.")
                        .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $systemPromptText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 220)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        .onChange(of: systemPromptText) { _, _ in
                            systemPromptDirty = true
                            systemPromptSaved = false
                        }

                    HStack {
                        Button("Save") { saveSystemPrompt() }
                            .font(.system(size: 11, weight: .medium))
                            .disabled(!systemPromptDirty || projectRoot == nil)
                            .keyboardShortcut("s", modifiers: .command)
                        Button("Reset to default") { resetSystemPrompt() }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.secondary)
                        Spacer()
                        if let root = projectRoot {
                            Text("\(root)/.cmux_team/system_prompt.md")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.head)
                        } else {
                            Text("No project directory — saving disabled").font(.system(size: 9)).foregroundColor(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding(16)
        }
    }

    /// Deterministic color for a user id. Palette picked for visible-but-subtle tints.
    private func colorForUser(_ userId: String) -> Color {
        guard !userId.isEmpty else { return .clear }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown, .cyan, .mint]
        var hash: UInt64 = 5381
        for byte in userId.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func userNameFor(_ id: String) -> String {
        if id.isEmpty { return "unknown" }
        return store.users.first { $0.id == id }?.name ?? String(id.prefix(8))
    }

    @ViewBuilder
    private func blamedBody(_ doc: ContextDocument) -> some View {
        let lines = doc.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let authors = doc.lineAuthors ?? []
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                let who = idx < authors.count ? authors[idx] : (doc.createdBy)
                let color = colorForUser(who)
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(color).frame(width: 3)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(color.opacity(0.08))
                        .help("Edited by \(userNameFor(who))")
                }
            }
        }
    }

    @ViewBuilder
    private func blameLegend(_ doc: ContextDocument) -> some View {
        let authors = doc.lineAuthors ?? []
        let uniq = Array(Set(authors + [doc.createdBy])).filter { !$0.isEmpty }
        if !uniq.isEmpty {
            HStack(spacing: 8) {
                Text("Authors:").font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(uniq, id: \.self) { uid in
                    HStack(spacing: 3) {
                        Circle().fill(colorForUser(uid)).frame(width: 8, height: 8)
                        Text(userNameFor(uid)).font(.system(size: 10))
                    }
                }
                Spacer()
            }
        }
    }

    private func authorLabel(_ updatedBy: String, _ createdBy: String) -> String {
        let id = updatedBy.isEmpty ? createdBy : updatedBy
        if id.isEmpty { return "" }
        let name = store.users.first { $0.id == id }?.name ?? String(id.prefix(8))
        return "by \(name)"
    }

    private func relativeDate(_ unix: Int64) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }
}

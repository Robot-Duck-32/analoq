import Foundation

@MainActor
class LibrarySelectionStore: ObservableObject {

    enum LoadState { case idle, loading, ready, error(String) }

    @Published var libraries: [AnaloqLibrary] = []
    @Published var selection: LibrarySelection = .empty
    @Published var loadState: LoadState = .idle
    @Published private(set) var hasSavedSelection = false

    private let service: LibraryService
    private let selectionKey = "librarySelection"

    init(service: LibraryService) {
        self.service = service
        loadSaved()
    }

    func load() async {
        if case .loading = loadState { return }
        loadState = .loading
        do {
            libraries = try await service.fetchLibraries()
            let availableIDs = Set(libraries.map(\.id))
            selection.selectedIDs = selection.selectedIDs.filter { availableIDs.contains($0) }
            save()
            loadState = .ready
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    func toggle(_ library: AnaloqLibrary) {
        if selection.selectedIDs.contains(library.id) { selection.selectedIDs.remove(library.id) }
        else { selection.selectedIDs.insert(library.id) }
        save()
    }

    var isValid: Bool { !selectedLibraries.isEmpty }

    var selectedLibraries: [AnaloqLibrary] {
        libraries.filter { selection.selectedIDs.contains($0.id) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: selectionKey)
        }
        hasSavedSelection = !selection.selectedIDs.isEmpty
    }

    func reset() {
        selection = .empty
        hasSavedSelection = false
        UserDefaults.standard.removeObject(forKey: selectionKey)
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: selectionKey),
              let saved = try? JSONDecoder().decode(LibrarySelection.self, from: data)
        else { return }
        selection = saved
        hasSavedSelection = !saved.selectedIDs.isEmpty
    }
}

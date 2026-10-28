import SwiftUI
import Combine

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public var searchResults: [Track] = []
    @Published public var isSearching: Bool = false
    @Published public var errorMessage: String?
    
    private var searchTask: Task<Void, Never>?
    
    public init() {}
    
    public func performSearch() {
        searchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        isSearching = true
        errorMessage = nil
        
        searchTask = Task {
            do {
                // First attempt direct YouTube search without fragile proxies
                let results = try await YouTubeDirectService.shared.search(query: trimmed)
                if !Task.isCancelled {
                    self.searchResults = results
                    self.isSearching = false
                }
            } catch {
                // Fallback to Invidious if available
                do {
                    let fallback = try await YouTubeBackendService.shared.search(query: trimmed)
                    if !Task.isCancelled {
                        self.searchResults = fallback
                        self.isSearching = false
                    }
                } catch {
                    if !Task.isCancelled {
                        self.errorMessage = "Search failed: \(error.localizedDescription)"
                        self.isSearching = false
                    }
                }
            }
        }
    }
}

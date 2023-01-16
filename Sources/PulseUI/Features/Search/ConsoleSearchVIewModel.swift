// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Pulse
import CoreData
import Combine

final class ConsoleSearchBarViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var tokens: [ConsoleSearchToken] = []

    var isEmpty: Bool {
        text.isEmpty && tokens.isEmpty
    }
}

@available(iOS 15, tvOS 15, *)
final class ConsoleSearchViewModel: ObservableObject, ConsoleSearchOperationDelegate {
    private var entities: [NSManagedObject]
    private var objectIDs: [NSManagedObjectID]

    @Published private(set) var results: [ConsoleSearchResultViewModel] = []

    @Published var isSpinnerNeeded = false
    @Published var isSearching = false
    @Published var hasMore = false

    @Published var recentSearches: [ConsoleSearchParameters] = []

    // important: if you reload the view with searchable quickly during typing, it crashes and burns
    let searchBar = ConsoleSearchBarViewModel()

    private var dirtyDate: Date?
    private var buffer: [ConsoleSearchResultViewModel] = []
    private var operation: ConsoleSearchOperation?

    @Published var suggestedFilters: [ConsoleSearchSuggestion] = []
    @Published var suggestedScopes: [ConsoleSearchSuggestion] = []

    private let service = ConsoleSearchService()

    private var cancellables: [AnyCancellable] = []
    private let context: NSManagedObjectContext

    init(entities: [NSManagedObject], store: LoggerStore) {
        self.entities = entities
        self.objectIDs = entities.map(\.objectID)
        self.context = store.newBackgroundContext()

        let text = searchBar.$text
            .map { $0.trimmingCharacters(in: .whitespaces ) }
            .removeDuplicates()

        Publishers.CombineLatest(text, searchBar.$tokens.removeDuplicates()).sink { [weak self] in
            self?.didUpdateSearchCriteria($0, $1)
            self?.updateSearchTokens(for: $0)
        }.store(in: &cancellables)

        $isSearching
            .removeDuplicates()
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.isSpinnerNeeded = $0 }
            .store(in: &cancellables)

        recentSearches = getRecentSearches()
    }

    func setEntities(_ entities: [NSManagedObject]) {
        self.entities = entities
        self.objectIDs = entities.map(\.objectID)
    }

    private func didUpdateSearchCriteria(_ searchText: String, _ tokens: [ConsoleSearchToken]) {
        operation?.cancel()
        operation = nil

        guard searchText.count > 1 || !tokens.isEmpty else {
            isSearching = false
            results = []
            return
        }

        isSearching = true
        buffer = []

        // We want to continue showing old results for just a little bit longer
        // to prevent screen from flickering. If the search is slow, we'll just
        // remove the results eventually.
        if !results.isEmpty {
            dirtyDate = Date()
        }

        let parameters = ConsoleSearchParameters(searchTerm: searchText, tokens: tokens, options: .default)
        let operation = ConsoleSearchOperation(objectIDs: objectIDs, parameters: parameters, service: service, context: context)
        operation.delegate = self
        operation.resume()
        self.operation = operation
    }

    private func updateSearchTokens(for searchText: String) {
        guard #available(iOS 16, tvOS 16, *) else { return }

        var suggestedFilters: [ConsoleSearchSuggestion] = []
        var suggestedScopes: [ConsoleSearchSuggestion] = []

        func add(_ filter: ConsoleSearchFilter) {
            var string = AttributedString(filter.name + ": ") { $0.foregroundColor = .primary }
            let values = filter.valuesDescriptions
            if values.isEmpty {
                string.append(filter.valueExample) { $0.foregroundColor = .secondary }
            } else {
                for (index, description) in values.enumerated() {
                    string.append(description) { $0.foregroundColor = .blue }
                    if index < values.endIndex - 1 {
                        string.append(", ") { $0.foregroundColor = .secondary }
                    }
                }
            }
            suggestedFilters.append(.init(text: string) {
                if values.isEmpty {
                    self.searchBar.text = filter.name + ": "
                } else {
                    self.searchBar.text = ""
                    self.searchBar.tokens.append(.filter(filter))
                }
            })
        }

        func add(_ scope: ConsoleSearchScope) {
            var string = AttributedString("Search in ") { $0.foregroundColor = .primary }
            string.append(scope.title) { $0.foregroundColor = .blue }
            suggestedScopes.append(.init(text: string) {
                self.searchBar.text = ""
                self.searchBar.tokens.append(.scope(scope))
            })
        }

        func parse(_ parser: Parser<ConsoleSearchFilter>) {
            (try? parser.parse(searchText)).map(add)
        }

        var allScopes = ConsoleSearchScope.allCases.filter { $0 != .originalRequestHeaders }

        if searchText.isEmpty {
            add(ConsoleSearchFilter.statusCode(.init(values: [])))
            add(ConsoleSearchFilter.host(.init(values: [])))

            for scope in allScopes {
                add(scope)
            }
        } else {
            parse(Parsers.filterStatusCode)
            parse(Parsers.filterHost)

            for scope in allScopes {
                if (try? Parsers.filterName(scope.title).parse(searchText)) != nil {
                    add(scope)
                }
            }
        }

#warning("easier way to manage these suggestions")
#warning("add suggestions based on input, e.g. input range")
#warning("finish this prototype")
#warning("different styles for filters and completions")
#warning("dont show suggestion when its not specific enough")
#warning("search like in xcode with first letter only")
#warning("make it all case insensitive")
#warning("if you are only entering values, what to suggest?")
#warning("filtes and scopes in separate categories")

#warning("TODO: priorize direct matches")

        self.suggestedFilters = suggestedFilters
        self.suggestedScopes = suggestedScopes
    }

    func buttonShowMoreResultsTapped() {
        isSearching = true
        operation?.resume()
    }

    // MARK: ConsoleSearchOperationDelegate

    func searchOperation(_ operation: ConsoleSearchOperation, didAddResults results: [ConsoleSearchResultViewModel]) {
        guard self.operation === operation else { return }

        if let dirtyDate = dirtyDate {
            self.buffer += results
            if Date().timeIntervalSince(dirtyDate) > 0.2 {
                self.dirtyDate = nil
                self.results = buffer
                self.buffer = []
            }
        } else {
            self.results += results
        }
    }

    func searchOperationDidFinish(_ operation: ConsoleSearchOperation, hasMore: Bool) {
        guard self.operation === operation else { return }

        isSearching = false
        if dirtyDate != nil {
            self.dirtyDate = nil
            self.results = buffer
        }
        self.hasMore = hasMore
    }

    // MARK: - Recent Searches

    func onSubmitSearch() {
        guard !searchBar.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        addRecentSearch(.init(searchTerm: searchBar.text, tokens: searchBar.tokens, options: .default))
        saveRecentSearches()
    }

    private func getRecentSearches() -> [ConsoleSearchParameters] {
        ConsoleSettings.shared.recentSearches.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([ConsoleSearchParameters].self, from: $0)
        } ?? []
    }

    private func saveRecentSearches() {
        guard let data = (try? JSONEncoder().encode(recentSearches)),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        ConsoleSettings.shared.recentSearches = string
    }

    func selectRecentSearch(_ parameters: ConsoleSearchParameters) {
        searchBar.text = parameters.searchTerm
        searchBar.tokens = parameters.tokens
    }

    func clearRecentSearchess() {
        recentSearches = []
        saveRecentSearches()
    }

    private func addRecentSearch(_ parameters: ConsoleSearchParameters) {
        while let index = recentSearches.firstIndex(where: { $0.searchTerm == parameters.searchTerm }) {
            recentSearches.remove(at: index)
        }
        recentSearches.append(parameters)
    }
}

@available(iOS 15, tvOS 15, *)
struct ConsoleSearchSuggestion: Identifiable {
    let id = UUID()
    let text: AttributedString
    var onTap: () -> Void
}

@available(iOS 15, tvOS 15, *)
struct ConsoleSearchResultViewModel: Identifiable {
    var id: NSManagedObjectID { entity.objectID }
    let entity: NSManagedObject
    let occurences: [ConsoleSearchOccurence]
}

// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Pulse
import CoreData
import Combine

#warning("TODO: remove public")

public struct _SearchView: View {
    public init() {}

    public var body: some View {
        if #available(iOS 15, *) {
            ConsoleSearchView(viewModel: .init(entities: try! LoggerStore.mock.allMessages()))
        }
    }
}

// TODO: stop updating when leaving background

extension String: Identifiable {
   public var id: String { self }
}

// TODO: use custom search bar?
@available(iOS 15, tvOS 15, *)
struct ConsoleSearchView: View {
    @ObservedObject var viewModel: ConsoleSearchViewModel

    var body: some View {
        let list = List {
            if !suggestedTokens.isEmpty {
                Section {
                    ForEach(suggestedTokens) { token in
                        Button(action: {
                            viewModel.searchText = ""
                            tokens.append(token)
                        }) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .font(ConsoleConstants.fontBody)
                                Text(token)
                                    .foregroundColor(.primary)
                                    .font(ConsoleConstants.fontBody)
                            }
                        }
                    }
                }
            }
            ForEach(viewModel.results) { result in
                Section {
                    ConsoleEntityCell(entity: result.entity)
                    // TODO: limit number of occurences of the same type (or only have one and display how many more?)
                    // TODO: when open body, start with a search term immediatelly
                    let occurences = Array(result.occurences.enumerated())
                    ForEach(occurences.prefix(3), id: \.offset) { item in
                        NavigationLink(destination: makeDestination(for: item.element, entity: result.entity)) {
                            makeCell(for: item.element)
                        }
                    }
                    if occurences.count > 3 {
                        // TODO: how to prioritize what makes the cut?
                        // TODO: implement show-all-occurences
                        NavigationLink(destination: Text("Show All")) {
                            HStack {
                                Text("Show All Occurences")
                                    .font(ConsoleConstants.fontBody)
                                    .foregroundColor(.secondary)
                                Text("\(occurences.count)")
                                    .font(ConsoleConstants.fontBody)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
            .environment(\.defaultMinListRowHeight, 0)
            .listStyle(.insetGrouped)

        //  TODO: rewrite using custom search bar
        if #available(iOS 16, *) {
            list
                .searchable(text: $viewModel.searchText, tokens: $tokens, token: { Text($0) })
                .disableAutocorrection(true)
        }  else {
            list.searchable(text: $viewModel.searchText)
                .disableAutocorrection(true)
        }
    }

    @State var tokens: [String] = []

    // TODO: implement suggested tokens
    // TODO: for status code allow ranges (400<500) etc
    // TODO: use new Regex for this
    var suggestedTokens: [String] {
        if viewModel.searchText == "201" {
            return ["Status Code 200"]
        }
        return ["Status Code 500", "application/json"]
    }

    // TODO: add occurence IDs instead of indices
    func makeCell(for occurence: ConsoleSearchOccurence) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            Text(occurence.kind.title + " (\(occurence.line):\(occurence.range.lowerBound))")
                .font(ConsoleConstants.fontTitle)
                .foregroundColor(.secondary)
            Text(occurence.occurrence)
                .lineLimit(3)
        }
    }

    func makeDestination(for occurence: ConsoleSearchOccurence, entity: NSManagedObject) -> some View {
        switch occurence.kind {
        case .responseBody:
            return NetworkInspectorResponseBodyView(viewModel: .init(task: entity as! NetworkTaskEntity))
                .environment(\.textViewSearchContext, occurence.searchContext)
        }
    }
}

#if DEBUG
@available(iOS 15, tvOS 15, *)
struct ConsoleSearchView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ConsoleSearchView(viewModel: .init(entities: try! LoggerStore.mock.allMessages()))
        }
    }
}
#endif

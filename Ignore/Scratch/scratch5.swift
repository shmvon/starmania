import Foundation
import SwiftSoup
@testable import Starmania

let urlStr = "https://genius.com/Oasis-shakermaker-lyrics"
Task {
    do {
        let result = try await GeniusFetcher.shared.fetchLyrics(title: "Shakermaker", artist: "Oasis", apiKey: "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5")
        print("LYRICS START")
        print(result.lyrics)
        print("LYRICS END")
    } catch {
        print("ERROR: \(error)")
    }
    exit(0)
}
RunLoop.main.run()

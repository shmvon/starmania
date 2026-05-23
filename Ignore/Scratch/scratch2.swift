import Foundation

let apiKey = "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5"
let artist = "oasis"
let title = "rock'n'roll star"
let query = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
let url = URL(string: "https://api.genius.com/search?q=\(query)")!

var request = URLRequest(url: url)
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

let semaphore = DispatchSemaphore(value: 0)
let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }
    guard let data = data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let responseDict = json["response"] as? [String: Any],
          let hits = responseDict["hits"] as? [[String: Any]] else {
        print("Failed to parse")
        return
    }
    
    let keywords = ["traduzion", "translati", "traducción", "traduction", "übersetzung"]
    var filteredHits = hits.filter { hit in
        guard let result = hit["result"] as? [String: Any] else { return false }
        let hitTitle = (result["title"] as? String)?.lowercased() ?? ""
        let hitFullTitle = (result["full_title"] as? String)?.lowercased() ?? ""
        let artistName = ((result["primary_artist"] as? [String: Any])?["name"] as? String)?.lowercased() ?? ""
        
        let combined = "\(hitTitle) \(hitFullTitle) \(artistName)"
        return !keywords.contains { combined.contains($0) }
    }
    
    if filteredHits.isEmpty {
        filteredHits = hits
    }
    
    let bestHit = filteredHits.min { a, b in
        let titleA = (a["result"] as? [String: Any])?["title"] as? String ?? ""
        let titleB = (b["result"] as? [String: Any])?["title"] as? String ?? ""
        return abs(titleA.count - title.count) < abs(titleB.count - title.count)
    }
    
    if let bestHit = bestHit, let result = bestHit["result"] as? [String: Any] {
        let bestTitle = result["title"] as? String ?? ""
        let bestArtist = (result["primary_artist"] as? [String: Any])?["name"] as? String ?? ""
        print("PICKED: \(bestArtist) - \(bestTitle)")
    }
}
task.resume()
semaphore.wait()

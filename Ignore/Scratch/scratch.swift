import Foundation

let apiKey = "y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5"
let query = "oasis rock'n'roll star".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
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
    
    for hit in hits {
        if let result = hit["result"] as? [String: Any] {
            let title = result["title"] as? String ?? ""
            let artist = (result["primary_artist"] as? [String: Any])?["name"] as? String ?? ""
            print("\(artist) - \(title)")
        }
    }
}
task.resume()
semaphore.wait()

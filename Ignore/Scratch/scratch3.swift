import Foundation

let cleanTitle = "Rock'n'roll star".replacingOccurrences(of: "'", with: " ")
let query = "Oasis \(cleanTitle)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
let url = URL(string: "https://api.genius.com/search?q=\(query)")!

var request = URLRequest(url: url)
request.setValue("Bearer y79GjLg6mJjW2kzbrWqbHgc17HCjdCFr9VZvegXK2an0VC0z70AkgeIs_jWPfZf5", forHTTPHeaderField: "Authorization")

let semaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { data, _, _ in
    defer { semaphore.signal() }
    guard let data = data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let responseDict = json["response"] as? [String: Any],
          let hits = responseDict["hits"] as? [[String: Any]] else { return }
    for hit in hits {
        let title = (hit["result"] as? [String: Any])?["title"] as? String ?? ""
        print("Hit: \(title)")
    }
}.resume()
semaphore.wait()

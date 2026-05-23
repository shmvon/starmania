import Foundation
import SwiftSoup

let urlStr = "https://genius.com/Oasis-shakermaker-lyrics"
let url = URL(string: urlStr)!
var request = URLRequest(url: url)
request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

let semaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { data, _, _ in
    defer { semaphore.signal() }
    guard let data = data, let html = String(data: data, encoding: .utf8) else { return }
    do {
        let doc = try SwiftSoup.parse(html)
        for br in try doc.select("br") { try br.append("\\n") }
        for div in try doc.select("div") { try div.append("\\n") }
        for p in try doc.select("p") { try p.prepend("\\n\\n") }
        
        let selectors = ["div[data-lyrics-container=\"true\"]", "div.lyrics", "div[class*=\"Lyrics__Container\"]"]
        for selector in selectors {
            let elements = try doc.select(selector)
            if !elements.isEmpty() {
                var lyricsText = ""
                for element in elements {
                    let text = try element.text()
                    if !lyricsText.isEmpty { lyricsText += "\\n" }
                    lyricsText += text
                }
                var cleaned = lyricsText.replacingOccurrences(of: "\\n", with: "\n")
                cleaned = cleaned.replacingOccurrences(of: " \n", with: "\n")
                cleaned = cleaned.replacingOccurrences(of: "\n ", with: "\n")
                
                print("RAW CLEANED LENGTH: \(cleaned.count)")
                print(String(cleaned.prefix(500)))
                return
            }
        }
    } catch { print("Error") }
}.resume()
semaphore.wait()

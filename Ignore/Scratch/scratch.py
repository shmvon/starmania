import urllib.request
from bs4 import BeautifulSoup

url = "https://genius.com/Oasis-shakermaker-lyrics"
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
html = urllib.request.urlopen(req).read()

soup = BeautifulSoup(html, 'html.parser')
for br in soup.find_all("br"):
    br.replace_with("\\n")
for div in soup.find_all("div"):
    div.append("\\n")
for p in soup.find_all("p"):
    p.insert(0, "\\n\\n")

elements = soup.select('div[data-lyrics-container="true"]')
if not elements:
    elements = soup.select('div[class*="Lyrics__Container"]')

lyrics = ""
for el in elements:
    lyrics += el.get_text() + "\\n"

cleaned = lyrics.replace("\\n", "\n").replace(" \n", "\n").replace("\n ", "\n")
print("LENGTH:", len(cleaned))
print(cleaned[:500])

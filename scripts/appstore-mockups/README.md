# App Store mock-ups

The 1.0 style: dark grey canvas, wide-tracked Quicksand title and subtitle, the screenshot in a
drawn iPhone frame. 1284×2778 (6.5") and 1290×2796 (6.7"/6.9").

```sh
gh workflow run iphone-screens.yml                       # simulator shots of every scenario
gh run download <run> -n iphone-screens -D shots
mkdir -p fonts && curl -L -o fonts/Quicksand.ttf "https://github.com/google/fonts/raw/main/ofl/quicksand/Quicksand%5Bwght%5D.ttf"
python3 build.py shots                                   # → site/assets/appstore-screenshots-1.2
gh workflow run asc-appstore-screenshots.yml             # replaces them in App Store Connect
```

Titles and order are the `SET` list in build.py.

# Plan sal P-14

Strona z planem zajęć sal budynku P-14 (Politechnika Wrocławska) na bieżący i następny tydzień.
Dane pochodzą z publicznych stron USOSweb i są pobierane automatycznie przez GitHub Actions.

## Jak to działa

- `scrape.ps1` pobiera listę sal budynku i plan każdej sali na 3 tygodnie do przodu, zapisuje `site/data.json`.
- `.github/workflows/update.yml` uruchamia skrypt codziennie rano i w niedzielę wieczorem, a potem publikuje folder `site/` na GitHub Pages.
- `site/index.html` wczytuje `data.json` i pokazuje plan z wyborem tygodnia i dnia.

## Inny budynek

W `update.yml` zmień `-Building P-14` na kod innego budynku (np. `C-13`).

## Ręczne odświeżenie

Zakładka **Actions** → **Aktualizacja planu** → **Run workflow**.

## Uruchomienie lokalnie

```powershell
./scrape.ps1 -OutFile site/data.json
```

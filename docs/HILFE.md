# Salenta Code – Hilfe

Salenta Code ist dein Arbeitsplatz für KI-Coding-Agents auf dem Mac. Du schreibst, was erledigt werden soll. Salenta Code wählt den passenden Agent, gibt ihm die richtigen Werkzeuge mit, lässt ihn in einer sicheren Arbeitskopie arbeiten und zeigt dir am Ende, was sich geändert hat. Du entscheidest, was übernommen wird.

## Erste Schritte

1. **Installieren:** `Salenta-Code.dmg` von der GitHub-Seite laden, öffnen und die App in den Ordner **Programme** ziehen – wie jede Mac-App. Die App ist von Apple geprüft und startet ohne Warnung. Updates kommen danach von selbst.
2. **Salenta Code öffnen.** Beim ersten Start prüft die Einrichtung, was auf deinem Mac fehlt (z. B. Git, GitHub CLI, Node, Claude Code) und installiert es auf Wunsch mit einem Klick.
3. **Einen Coding-Agent anmelden.** Mindestens einer wird gebraucht: Claude Code, Codex, Cursor, Gemini CLI, Junie und andere. Du meldest dich mit deinem eigenen Konto an – Salenta Code verkauft oder vermittelt keinen Modell-Zugang.
4. **Ein Projekt hinzufügen.** Unter **Projekte › Projekt hinzufügen**: einen Ordner auf dem Mac wählen, ein GitHub-Repo verbinden (wird geklont) oder ein neues Projekt anlegen. Salenta Code durchsucht deinen Mac nicht von selbst.
5. **Ersten Auftrag schreiben** – oben bei **Neuer Auftrag**.

## Einen Auftrag starten

Schreib in das Eingabefeld, was passieren soll – so, wie du es einem Kollegen sagen würdest:

- „Füge auf der Startseite einen Dark-Mode-Schalter hinzu“
- „Warum schlägt der Login-Test fehl? Finde den Fehler und behebe ihn.“
- „Prüfe den letzten Umbau auf Sicherheitslücken – nichts ändern.“

Danach:

- **Projekt wählen:** Klick auf **Projekt wählen** (oder nenne den Projektnamen im Text). Das gewählte Projekt steht als Chip im Feld – mit dem **×** löst du es wieder. Ein Projekt gilt immer nur für einen Auftrag.
- **Automatisch** wählt den passenden Agent und das Modell. Du kannst stattdessen jeden Agent fest wählen.
- **+** öffnet weitere Optionen: Dateien anhängen, Skills wählen, **Erst planen, dann umsetzen**, mehrere Agents parallel.
- **⌘↩** startet. Bei „Automatisch“ siehst du zuerst einen Vorschlag („So würde ich es umsetzen“) mit Agent, Modell, Projekt, Skills und Erweiterungen – alles änderbar, dann **Starten**.

## Während der Agent arbeitet

- In der Seitenleiste unter **Aufträge** steht jeder laufende Auftrag. Ein grüner Punkt heißt: arbeitet gerade.
- **Helfer** (vom Agent gestartete Unter-Agents, z. B. zum Prüfen) und **Mods** hängen eingerückt unter ihrem Hauptauftrag – markiert mit „↳ Helfer“ bzw. „↳ Mod“.
- Im Auftrag siehst du live jeden Schritt, den Kontext-Verbrauch und welche Integrationen aktiv sind.
- Du kannst jederzeit nachschreiben – der Agent macht im selben Auftrag weiter.
- **Zurückspulen:** Bei jeder deiner Nachrichten kannst du auf den Stand davor zurückspringen.

## Freigaben – was der Agent darf

Agents dürfen Dateien im Projekt ändern und übliche Befehle ausführen (Tests, Build, Lint, Git-Status …). **Riskante Schritte fragen dich vorher** über die Freigabe-Leiste oben:

- `git push`, Force-Push, Löschen, Deploy, Datenbank-Änderungen, Veröffentlichen, Nachrichten an Kunden

Unter **Einstellungen › Regeln** legst du eigene Sperr-Regeln fest (global oder pro Projekt). In der Menüleiste kannst du „Agents ohne Rückfrage arbeiten lassen“ zeitlich begrenzt einschalten – Sperr-Regeln gelten trotzdem.

## Änderungen prüfen und übernehmen

Jeder Code-Auftrag arbeitet in einer **eigenen Arbeitskopie** deines Projekts. Dein Projektordner bleibt unberührt, bis du übernimmst – so können auch mehrere Agents gleichzeitig arbeiten.

- `.env`-Dateien, lokale Einstellungen und `node_modules` kommen automatisch mit, damit Bauen und Testen funktioniert. Weitere Dateien trägst du in eine Datei `.worktreeinclude` im Projekt ein (eine pro Zeile).
- Am Ende siehst du **Änderungen** mit allen Dateien und dem Diff. Hinterlegte Prüfbefehle (Tests, Build) laufen automatisch; auf Wunsch macht ein zweiter Agent ein Review.
- **Übernehmen** – die Änderungen kommen in deinen Branch. Danach fragt Salenta Code, ob sie **auch auf GitHub hochgeladen** werden sollen (normaler Push, nie Force).
- **Pull Request …** – ein Klick für Commit, Push und Pull Request. Titel, Beschreibung und Changelog sind schon fertig geschrieben (aus Auftrag und Änderungen), du kannst alles ändern. Im selben Fenster siehst du jede geänderte Datei mit Diff, wählst **Als Entwurf** und die **Basis**: dein Branch – oder der Branch eines anderen Auftrags, dann bauen die PRs aufeinander auf (gestapelt). Genutzt wird deine GitHub-Anmeldung (`gh`).
- **Nachschieben:** Solange der PR offen ist, bleibt der Auftrag offen. Arbeitet der Agent weiter, lädt **Nachschieben** die neuen Änderungen in denselben PR – auf Wunsch mit neu geschriebener Beschreibung. **Abschließen** räumt die Arbeitskopie auf; PR und Branch bleiben auf GitHub.
- **Verwerfen** – die Arbeitskopie wird gelöscht, dein Projekt bleibt wie es war.

Unter **Projekte** zeigt ein blauer Pfeil mit Zahl, wie viele Commits noch nicht auf GitHub sind – Klick lädt sie hoch.

## Projekte und Projekt-Betreuer

- **Projekte** zeigt alle deine Projekte mit Branch, offenen Änderungen, CI-Status, Live-Vorschau, Terminal und Regeln.
- **Weiterarbeiten** öffnet einen neuen Auftrag direkt in diesem Projekt.
- **Projektwissen** (Gehirn-Symbol): was alle Agents über das Projekt gelernt haben – angeheftete Einträge bekommt jeder Agent mit.
- **Projekt-Betreuer:** Gib ein Projekt in Betreuung. Ein Koordinator plant Aufgaben, startet Helfer, beobachtet die CI und meldet sich, wenn er dich braucht. Du bestimmst, wie viel er selbst darf.

## Agents, Skills und Erweiterungen

- **Automatisch** verteilt so: Bauen/Ändern → Claude Code, Fehlersuche → Junie, Review → Codex, Alltag/Recherche/Integrationen → dein OS-Agent. Ist ein Agent am Limit, nimmt Salenta Code automatisch einen anderen.
- **Arbeitsplan in Phasen:** Jeder Code-Auftrag bekommt einen festen Ablauf – *Verstehen & planen → Umsetzen → Aufräumen → Prüfen wie die CI → Sicherheit → Selbst-Review → Abschließen*. In jeder Phase stehen genau die installierten Erweiterungen und Skills, die dort helfen: z. B. Planungs-Werkzeuge beim Planen, Doku-Helfer und Frontend-Design beim Umsetzen (bei UI-Aufgaben), Code-Simplifier beim Aufräumen, Browser-Tests beim Prüfen von Oberflächen, Sicherheits-Review bei heiklen Themen (Login, Zahlungen, Schlüssel, Deploy). Token-Sparer laufen die ganze Zeit mit.
- **Prüfen wie die CI:** Der Agent führt dieselben Prüfbefehle aus, die danach automatisch laufen – inklusive der sicheren Prüfschritte aus deinen GitHub-Workflows (Lint, Typen, Tests, Build). So ist der Push auf GitHub möglichst gleich grün.
- **Erweiterungen** zeigt geprüfte Plugins, Skills und MCP-Server – Installieren mit einem Klick. Neue werden täglich vorgeschlagen.
- **Integrationen** zeigt alle verbundenen Dienste (MCP), sortiert nach Zweck, mit Status und Reparieren-Knopf.

## Mods – eigene Automatik

Mods reagieren auf Ereignisse und tun dann etwas: einen Agent starten, einen Befehl ausführen, dich benachrichtigen oder einen Webhook aufrufen.

Beispiele: „Nach dem Übernehmen: Sicherheits-Check“, „Wenn die CI rot wird: Fehler suchen“, „Wenn ein Auftrag fertig ist: Changelog schreiben“. Unter **Mods** findest du eine Galerie zum Starten.

## Lokal und offline arbeiten

Mit **Ollama** laufen Modelle direkt auf deinem Mac – kostenlos und privat. Unter **Einstellungen › Modelle**:

- **Empfohlene Modelle** passend zum Arbeitsspeicher deines Macs – laden mit einem Klick, danach sofort aktiv. Die Liste aktualisiert sich, wenn neue Modelle erscheinen.
- **Bei Internet-Ausfall umschalten:** Fällt das Internet weg, laufen Aufträge mit dem lokalen Modell weiter.
- **Kleine Aufgaben lokal:** Tippfehler, Umbenennen, Kommentare, Texte – spart Abo-Kontingent. Kommt das lokale Modell nicht zurecht, übernimmt automatisch Claude.
- **Nur lokal arbeiten (Offline-Modus):** Alles läuft nur noch über das lokale Modell – Aufträge, Helfer, Mods, Reviews, Zusammenfassungen. Nichts geht an eine Cloud-KI. Auch in der Menüleiste umschaltbar.

Unter **Verbrauch › Lokal statt Cloud** siehst du, wie viel lokal lief und was das gespart hat.

## Verbrauch und Limits

**Verbrauch** zeigt pro Agent, wie nah du am Limit bist (z. B. 5-Stunden- und Wochen-Limit bei Claude), Tokens pro Tag und Modell und wie erfolgreich jeder Agent war. Wird es eng, verteilt Salenta Code neue Aufträge automatisch um.

## Mail, Kalender, Aufgaben, Wissen

Salenta Code ist auch dein Tages-Cockpit – alles mit dem Mac abgeglichen:

- **Mail:** alle Konten aus Apple Mail – lesen, antworten, archivieren, an einen Agent geben.
- **Kalender:** alle Kalender des Macs (iCloud, Google, Exchange) – Termine anlegen, verschieben, bearbeiten.
- **Aufgaben:** deine To-dos, auf Wunsch mit Apple Erinnerungen abgeglichen. Agents lesen und erledigen sie mit.
- **Wissen:** dein Obsidian-Vault – Ordner, Tags, Suche, Notizen bearbeiten. Agents lesen ihn als Kontext und schreiben ins Journal.

## Menüleiste und Widgets

- Das **Symbol in der Menüleiste** zeigt laufende Agents, wartende Freigaben und Updates. Dort schaltest du schnell um: Wach bleiben, Agents ohne Rückfrage, Nur lokal, Mitteilungen, Beim Anmelden starten.
- **Widgets:** Schreibtisch rechtsklicken › Widgets bearbeiten › Salenta Code.
- **Wach bleiben:** Der Mac schläft nicht ein, solange Agents arbeiten – mit Schutz bei niedrigem Akku und Hitze.
- **Nachtschicht:** Aufgaben für die Nacht sammeln; sie laufen nacheinander, morgens liegt der Bericht bereit.

## Spracheingabe und Sprache der App

- **Diktieren:** Überall, wo du schreibst, gibt es das Mikrofon – oder ⌥⌘D. Sprechen, nochmal drücken, der Text landet im Feld. Unten im Fenster siehst du dabei die Aufnahme-Leiste.
- **Deutsch oder Englisch:** Salenta Code folgt der Sprache deines Macs. Unter **Einstellungen › Allgemein › Sprache** kannst du sie für die App fest einstellen – auch deine Agents antworten dann in dieser Sprache.

## Tastenkürzel

| Kürzel | Funktion |
|---|---|
| ⌘K | Befehlspalette – alles finden und starten |
| ⌘↩ | Auftrag starten / Vorschlag bestätigen |
| ⌘N | Neue Aufgabe |
| ⌘0 | Mission Control (alles, was gerade läuft) |
| ⌘1 | Cockpit |
| ⌘2 | Aufgaben |
| ⌘3 | Agents |
| ⌘⇧M | Mail |
| ⌘⇧K | Kalender |
| ⌘T | Claude Code im Terminal starten |
| ⌘? | Diese Hilfe |
| ⌃⌥ Leertaste | Salenta Code von überall nach vorn holen oder ausblenden |

Fährst du mit der Maus über einen Knopf, steht dort, was er tut.

## Updates

Salenta Code sucht automatisch nach neuen Versionen. Ein Update wird nur installiert, wenn die Prüfsumme stimmt, es vom selben Entwickler signiert ist und der Selbsttest der neuen Version grün ist – und erst, wenn keine Agents laufen. Die vorige Version bleibt erhalten: **Einstellungen › Modelle › Updates › Vorige Version zurückholen**.

## Datenschutz und Sicherheit

- Deine Daten bleiben auf deinem Mac (`~/Library/Application Support/Salenta Code`). Es gibt keine Cloud von Salenta Code.
- API-Schlüssel liegen nur im macOS-Schlüsselbund – nie in Dateien, Repos oder Notizen.
- Arbeitskopien committen nie `.env`-Dateien oder verlinkte Abhängigkeiten.
- Mit **Nur lokal** verlässt kein Text deinen Mac in Richtung einer KI.

## Wenn etwas hakt

- **Agent startet nicht / „nicht angemeldet“:** Im Terminal einmal anmelden (z. B. `claude`, dann `/login`). Salenta Code nimmt solange automatisch einen anderen Agent.
- **Integration rot:** Unter **Integrationen** auf **Reparieren** klicken.
- **Lokales Modell liefert schlechte Ergebnisse:** Ein größeres Modell laden (Einstellungen › Modelle) – kleine Modelle eignen sich nur für kleine Aufgaben.
- **App reagiert nicht:** Salenta Code startet nach zwei Abstürzen hintereinander automatisch im **abgesicherten Modus**. Unter **Salenta Code › Leistung messen** entsteht ein Bericht, den du einem Fehler-Ticket anhängen kannst.
- **Fehler melden oder Idee vorschlagen:** auf GitHub unter *Issues*.

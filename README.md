# LocaLM

On-device personal assistant for iPhone (iOS 26.1+). Runs Liquid AI's LFM3-1.7B through llama.cpp (Metal).
Chat, memory, and the tools below work offline once the model is downloaded; only web search and Maps
directions use the internet.

## Tools (28)

| Group | Tools | Confirm tap? |
|---|---|---|
| Reminders (EventKit) | create, list, complete, update, delete | yes, except list |
| Calendar (EventKit) | list events, create (shows overlaps), move, delete | yes, except list |
| Memory (SQLite FTS5) | save, search, delete; relevant memories are also attached to each message automatically | save/delete |
| Alarms (AlarmKit) | set timer, set alarm (one-time or repeating), list, cancel | alarm/cancel |
| Contacts | find contact; call (iOS asks before dialing); draft text / email (user taps Send in Apple's sheet) | — |
| Utilities | calculate, convert units, days until/since, world time | — |
| Other | directions (Maps), run a Siri Shortcut, battery/storage | shortcut |
| Web search | fetches results (Wikipedia without a key, Brave Search with your API key) and answers from them with the source; one search per message | asks by default (⋯ > Web search) |

`ToolRouter` shows the model only the groups the user's words point at (2–9 tools per message instead of 28).

Also: Memories screen (view, search, edit, delete, add), morning-briefing notification, Siri/Shortcuts
intents ("Ask LocaLM", "LocaLM briefing", "Save a memory in LocaLM"). Background behavior and its
limits: `docs/background-execution.md`.

## Layout

```
ios/project.yml                   XcodeGen spec (generates ios/LocaLM.xcodeproj)
ios/LocaLM/LLM/                   llama.cpp wrapper, LFM3 chat template port, tool-call parser
ios/LocaLM/Agent/AssistantStore   Agent loop: route -> model -> parse -> validate -> confirm -> execute -> model
ios/LocaLM/Agent/ToolRouter       Which tool groups the model sees for each message
ios/LocaLM/Tools/                 All tools, date/duration/range parsing, compose-sheet presenter
ios/LocaLM/Storage/               SQLite: chats, memories (FTS5), memory retrieval
ios/LocaLM/Background/            Briefing + maintenance background tasks, App Intents
ios/LocaLM/Models/                Model catalog and in-app download with SHA-256 check
ios/LocaLM/Diagnostics/           Self-test, 166-case eval, persistence check
docs/                             Eval results, background research, raw on-device reports
```

## Setup (not in git: vendor/, models/, tools/)

```sh
# llama.cpp prebuilt XCFramework (LFM3 needs b11960 or newer)
mkdir -p vendor && cd vendor
curl -LO https://github.com/ggml-org/llama.cpp/releases/download/b11971/llama-b11971-xcframework.zip
unzip -q llama-b11971-xcframework.zip && cd ..

brew install xcodegen
cd ios && xcodegen generate
```

## Build, install, run

```sh
cd ios
xcodebuild -project LocaLM.xcodeproj -scheme LocaLM -configuration Release \
  -destination 'id=YOUR_DEVICE_UDID' -derivedDataPath build DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  build/Build/Products/Release-iphoneos/LocaLM.app
```

List device IDs with `xcrun devicectl list devices` (install/launch) and
`xcodebuild -project LocaLM.xcodeproj -scheme LocaLM -showdestinations` (build).

## Self-test and eval (no taps needed; phone must be unlocked)

```sh
xcrun devicectl device process launch --device <id> --terminate-existing \
  com.nikilthalapaneni.localm -- -LocaLMSelfTest YES
#   -LocaLMEvalFilter cal_,mem_   only cases whose id starts with these prefixes
#   -LocaLMEvalAllTools YES       baseline without tool routing
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.nikilthalapaneni.localm --source Documents/eval.json --destination eval.json
```

The self-test checks the database (chats + memory search), 25 deterministic tool checks, the device's
background capabilities, downloads the model if missing, runs 7 timing prompts, then the 166-case eval.
Progress goes to `Documents/selftest-status.txt`. It never creates reminders, events, or alarms.
Results: `docs/eval-results.md`.

Persistence + automatic memory recall across restarts: launch twice with `-- -LocaLMPersistenceCheck YES`
and read `Documents/persistence-check.txt`. It refuses to run if a conversation already exists, and
cleans up after itself.

## Development configuration

Select your Apple development team in Xcode or supply `DEVELOPMENT_TEAM` at build time.
Use your own bundle identifier if you intend to distribute the app. The project is
generated from `ios/project.yml`; do not commit Xcode user state or signing material.
Model weights and llama.cpp binaries are downloaded separately and remain subject
to their upstream licenses. The checked-in evaluation files use synthetic prompts
and describe historical device runs, not results from every supported device.

## Validation

See [TEST_RESULTS.md](TEST_RESULTS.md) for checks performed on this publication copy.

# Word Relay for Mac

Word Relay watches a Roblox window for the starting tiles and finds English words that start with them. It keeps the prompt steady while words are typed into the tile row. It includes 106,179 indexed English words and runs locally on macOS 14 or later.

## Download

Download the macOS app from [GitHub Releases](https://github.com/Fatennalover/word-relay/releases/latest). The bundle supports Apple silicon and Intel Macs running macOS 14 or later.

## Start a match

1. Extract the ZIP and open **Word Relay.app**. Open Roblox in a regular window so the floating panel is easy to see.
2. Click **Start** or press **Control–Shift–S**. If macOS asks for permission, allow **Word Relay** in **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen Word Relay if requested.
3. Click a suggestion to copy it, then paste or type it in the game. **Next** cycles through batches of available words. A suggestion stays available until you submit it or mark it as played. Scroll the suggestions when your batch is larger than five.
4. Press **Control–Shift–D** to stop scanning. Press **Control–Shift–N** or click **New match** to reset the match and its history.

## Track played words

- Open the gear and select **Allow Input Monitoring** under **Played words**. Turn on Word Relay in the macOS Input Monitoring pane and reopen it if macOS asks. Keep **Track words I submit in Roblox** enabled.
- While Word Relay is scanning a turn, type your word and press **Return** in Roblox. The app assembles the word as you type, then logs matching dictionary or custom words on submission. The listener is scoped to the Roblox process and the current scanned turn.
- The **Played** tab shows the source of each entry. A submission is an attempt, so use **Undo** there if the game rejects it. Right-click a suggestion and choose **Mark played**, or type a word in the history to log it manually.
- If the game shows a last-played word (including an opponent's), you can also select **Settings → Scan areas → Played word → Preview window** and draw a tight box around that word. Word Relay can also recognize a complete typed row when its last letters become the next prompt. The optional scan area looks for a single word in two frames and labels detections **Seen on screen**. The placement and how long the game displays the word affect detection.
- Your submissions and words you manually mark as played are excluded during the current match. Previewed, copied, and screen-observed words stay eligible unless you submit or mark them. A result banner clears both histories as soon as the match ends. In Roblox, three seconds without both the clock and the tiles also clears the histories. The configurable no-tiles timeout covers other layouts.

## Customize suggestions and timing

- Under **Suggestions**, set **Words per batch** from 1 to 100. The default is five. **Custom words** accepts up to 100 entries. Set **Custom words per batch** from 0 to 100 to control how many matching custom entries can appear in each batch.
- The game clock is used when readable. **Timing** lets you change the fallback timer and the no-tiles timeout. The scanner reads the full starting row, including prompts longer than two letters. The current suggestions stay visible through brief tile dropouts while the game clock is active.
- If the scanner misses the tiles after the window layout changes, go to **Settings → Scan areas → Letter tiles → Preview window** and draw around the tiles. Leave room for longer prefixes and turn animations.
- Type a prefix into **Enter letters**, or use the photo button to read a screenshot while the scanner is off.

## Build from source

Run `bash build.sh` on a Mac with Xcode command-line tools. The script builds a universal app under `build/` or a directory passed as its first argument.

The word lists come from the [English Speller Database](https://github.com/en-wl/wordlist), release 2026.02.25, including additional headwords from its large US dictionary. Its copyright notice and Fredoka's Open Font License are included in `Resources/` and in the app.

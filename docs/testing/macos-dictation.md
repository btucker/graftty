# Verify macOS Dictation in terminal panes

Run these checks in a signed Graftty application on macOS 14 and the current supported macOS release. Automated text-input tests exercise AppKit callbacks without recording audio. They do not verify the system Dictation UI or recognition service.

1. Enable Dictation in System Settings > Keyboard. Note the configured Dictation shortcut and language.
2. Focus a local shell pane. Activate Dictation with the system shortcut and speak a short sentence. Confirm that provisional text appears near the cursor and the committed sentence appears once. Stopping Dictation must not submit the command.
3. Repeat with the Return key as the way to stop Dictation. Confirm that this does not submit the shell input. If the system delivers Return to the terminal, record the macOS version and treat this as a release blocker.
4. Speak punctuation and "new line". The first version inserts a single line: line breaks become spaces, and terminal control characters are excluded. Confirm that speech never executes a command by introducing a newline.
5. Repeat in an agent prompt and a terminal editor in insert mode. Check accented text and emoji where supported by the selected language.
6. Cancel provisional text with Escape. Confirm that it disappears without writing bytes to the terminal. Switch panes or windows during composition, then return. Confirm that late text does not enter another pane.
7. Close the pane during composition. Confirm that Graftty remains responsive and does not insert into the replacement pane.
8. Repeat in a remote pane and a pane whose display is owned by another client. Confirm that committed input takes control before sending text. Merely displaying provisional text must not take control.
9. Enable Terminal Read-only and repeat. No dictated text should enter the terminal.
10. Check ordinary typing, Return, Backspace, arrows, Tab, Control-C, Option combinations, Command-C, and Command-V before and after Dictation. Confirm that they retain their normal terminal behavior.
11. Resize or scroll while dictating. Confirm that the system indicator remains positioned at the terminal cursor.

System Dictation uses the user's macOS language, microphone, and privacy settings. This system shortcut does not use Graftty's microphone recorder. Check the description beneath Dictation in Keyboard settings to determine whether the selected configuration processes speech on device.

Voice Control is a separate macOS feature and needs separate validation. An editable multiline draft and voice commands for pane navigation are outside this first version.

## Verify the sidebar microphone

Run these checks in a signed application with microphone and speech recognition permissions. This feature requires on-device recognition for the system language. It does not fall back to server recognition or require Voice Control commands.

1. Select a shell pane and click the microphone above the project management buttons. On first use, allow microphone and speech recognition access. Confirm that recording starts after authorization.
2. Speak a sentence, then pause. Confirm that provisional text updates in the terminal and the final text appears once without submitting. Continue speaking and check the space between utterances.
3. Pause, then say "Send prompt" as a separate utterance. Confirm that Graftty removes the command words, sends Return once, and stops the microphone. Repeat in Codex or Claude Code.
4. Say "change the send prompt button". Confirm that the whole sentence is inserted as ordinary text. A pause alone must never submit.
5. Click the microphone while speaking. Confirm that final recognized words are retained without submitting. Repeat while saying "Send prompt" and confirm that stopping manually prevents submission.
6. Press Escape during provisional speech. Confirm that recording stops and provisional text disappears. Type normally and check that no delayed speech arrives.
7. Switch panes, worktrees, Graftty windows, or applications while dictating. Close the target pane and enable read-only mode in separate runs. Confirm that recording stops and no words reach another terminal.
8. Repeat in expanded and collapsed project columns. Collapse and expand while listening. Confirm that the microphone remains above Add Repository and Manage Remote Macs, the hint remains visible, and the terminal retains keyboard focus. Disable the project rail and check the single-sidebar footer too.
9. Speak again immediately after a pause. Confirm that words spoken while the previous utterance finalizes are retained. Try a long utterance that crosses the recognition request rollover.
10. Deny each permission separately, test an unavailable on-device language, and disconnect the microphone while listening. Confirm that Graftty stops and explains the problem without submitting input.
11. Repeat with a remote terminal and a terminal controlled by another client. Confirm that successful text delivery takes display control and failed delivery stops dictation without a later Return.

Automated tests cover command parsing, stale callbacks, buffering, and focus behavior. They cannot establish recognition accuracy, microphone levels, permission-dialog timing, or how fast terminal previews appear. These checks remain required before release.

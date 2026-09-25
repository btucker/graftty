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

System Dictation uses the user's macOS language, microphone, and privacy settings. Graftty does not record audio or select a recognition service. Check the description beneath Dictation in Keyboard settings to determine whether the selected configuration processes speech on device.

Voice Control is a separate macOS feature and needs separate validation. An editable multiline draft and voice commands for pane navigation are outside this first version.

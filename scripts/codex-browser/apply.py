#!/usr/bin/env python3
"""Apply only the opt-in TUI opener hook to the pinned Codex source tree."""
import pathlib
import sys

check_only = len(sys.argv) == 3 and sys.argv[1] == "--check"
root = pathlib.Path(sys.argv[2] if check_only else sys.argv[1]) / "codex-rs" / "tui" / "src"
module = pathlib.Path(__file__).with_name("browser_command.rs").read_text()
changes = [
    (root / "lib.rs", "mod branch_summary;\n", "mod branch_summary;\nmod browser_command;\n"),
    (root / "app" / "history_ui.rs", "    pub(super) fn open_url_in_browser(&mut self, url: String) {\n",
     """    pub(super) fn open_url_in_browser(&mut self, url: String) {
        if let Some(helper) = std::env::var_os("CODEX_BROWSER_COMMAND").filter(|value| !value.is_empty() && crate::browser_command::is_web_url(&url)) {
            let events = self.app_event_tx.clone();
            // Enqueue off the TUI loop. This never reports OAuth success.
            tokio::task::spawn_blocking(move || {
                if let Err(error) = crate::browser_command::open_url(&url, &helper) {
                    events.send(AppEvent::InsertHistoryCell(Box::new(history_cell::new_error_event(
                        format!("Failed to hand off browser URL: {error}"),
                    ))));
                }
            });
            return;
        }
"""),
]
if check_only:
    for path, old, new in changes:
        if path.read_text().count(new) != 1:
            raise SystemExit(f"Cached browser hook differs in {path}")
    if (root / "browser_command.rs").read_text() != module:
        raise SystemExit("Cached browser command module differs")
    raise SystemExit(0)
# Fail closed on source drift or repeat application before modifying any source.
if (root / "browser_command.rs").exists():
    raise SystemExit("Browser hook module already exists; use --check or a fresh pinned source tree")
for path, old, new in changes:
    contents = path.read_text()
    if "mod browser_command;" in contents or "crate::browser_command::" in contents:
        raise SystemExit(f"Browser hook already present in {path}; use a fresh pinned source tree")
    if contents.count(old) != 1:
        raise SystemExit(f"Expected one opener anchor in {path}; use the pinned source")
for path, old, new in changes:
    path.write_text(path.read_text().replace(old, new, 1))
(root / "browser_command.rs").write_text(module)

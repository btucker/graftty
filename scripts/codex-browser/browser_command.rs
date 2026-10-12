//! Graftty's opt-in browser handoff for the Codex TUI. OAuth remains in the app-server.
use std::ffi::OsStr;
use std::io;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(crate) fn open_url(url: &str, helper: &OsStr) -> io::Result<()> {
    dispatch(url, Some(helper), Duration::from_secs(8), |_| {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "browser helper is empty",
        ))
    })
}

fn dispatch(
    url: &str,
    helper: Option<&OsStr>,
    timeout: Duration,
    native: impl FnOnce(&str) -> io::Result<()>,
) -> io::Result<()> {
    let Some(helper) = helper.filter(|value| !value.is_empty()) else {
        return native(url);
    };
    // One argv value, never shell text. Inherit the originating pane's context.
    let mut child = Command::new(helper)
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                return Err(io::Error::other(format!(
                    "browser handoff failed: {status}"
                )))
            }
            Ok(None) => {}
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "browser handoff timed out",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new(body: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir()
                .join(format!("graftty-browser-{}-{nonce}", std::process::id()));
            fs::create_dir(&root).unwrap();
            let script = root.join("helper's executable");
            fs::write(&script, format!("#!/bin/sh\n{body}\n")).unwrap();
            fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
            Self(root)
        }
        fn helper(&self) -> PathBuf {
            self.0.join("helper's executable")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn absent_or_empty_hook_preserves_native_browser() {
        for helper in [None, Some(OsStr::new(""))] {
            let mut calls = 0;
            dispatch(
                "https://example.com",
                helper,
                Duration::from_secs(1),
                |url| {
                    assert_eq!(url, "https://example.com");
                    calls += 1;
                    Ok(())
                },
            )
            .unwrap();
            assert_eq!(calls, 1);
        }
    }

    #[test]
    fn helper_receives_one_literal_url_and_session_context() {
        let fixture = Fixture::new(
            "[ \"$#\" -eq 1 ] || exit 1\nprintf '%s\\n%s' \"$1\" \"${PATH:-}\" > \"$0.receipt\"",
        );
        let url = "https://example.com/oauth?state=a'b&literal=$(printf oops); space";
        dispatch(
            url,
            Some(fixture.helper().as_os_str()),
            Duration::from_secs(1),
            |_| panic!("configured handoff must not invoke the native browser"),
        )
        .unwrap();
        let receipt = fs::read_to_string(fixture.0.join("helper's executable.receipt")).unwrap();
        assert_eq!(
            receipt,
            format!("{url}\n{}", std::env::var("PATH").unwrap())
        );
    }

    #[test]
    fn failed_handoff_does_not_open_native_browser() {
        let fixture = Fixture::new("exit 9");
        let error = dispatch(
            "https://example.com",
            Some(fixture.helper().as_os_str()),
            Duration::from_secs(1),
            |_| panic!("failure must remain visible rather than opening the Mac browser"),
        )
        .unwrap_err();
        assert!(error.to_string().contains('9'));
    }

    #[test]
    fn configured_entry_point_reports_failed_handoff() {
        let fixture = Fixture::new("exit 9");
        let error = open_url("https://example.com", fixture.helper().as_os_str()).unwrap_err();
        assert!(error.to_string().contains('9'));
    }

    #[test]
    fn stalled_helper_is_killed_and_reaped() {
        let fixture = Fixture::new("exec sleep 20");
        let started = Instant::now();
        let error = dispatch(
            "https://example.com",
            Some(fixture.helper().as_os_str()),
            Duration::from_millis(50),
            |_| panic!("timeout must not invoke the native browser"),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn missing_helper_does_not_open_native_browser() {
        let error = dispatch(
            "https://example.com",
            Some(OsStr::new("/graftty-missing-browser-helper")),
            Duration::from_secs(1),
            |_| panic!("missing helper must not invoke the native browser"),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
    }
}

//! Graftty's opt-in browser handoff for the Codex TUI. OAuth remains in the app-server.
use std::ffi::OsStr;
use std::io;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(crate) fn is_web_url(url: &str) -> bool {
    url.split_once(':').is_some_and(|(scheme, _)| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}

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
    let Some(helper) = helper.filter(|value| !value.is_empty() && is_web_url(url)) else {
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

// Reserve on the TUI loop before scheduling blocking work, so worker scheduling
// cannot reorder browser offers. Tokio owns the workers and joins them at shutdown.
#[derive(Default)]
struct Order { next: u64, serving: u64, pending: usize, finished: std::collections::BTreeSet<u64> }
static ORDER: (std::sync::Mutex<Order>, std::sync::Condvar) =
    (std::sync::Mutex::new(Order { next: 0, serving: 0, pending: 0, finished: std::collections::BTreeSet::new() }), std::sync::Condvar::new());

pub(crate) struct Handoff { ordinal: u64 }
pub(crate) fn reserve_handoff() -> io::Result<Handoff> {
    let mut order = ORDER.0.lock().unwrap_or_else(|e| e.into_inner());
    if order.pending >= 9 {
        return Err(io::Error::new(io::ErrorKind::WouldBlock, "browser handoff queue is full"));
    }
    let ordinal = order.next;
    order.next = order.next.wrapping_add(1);
    order.pending += 1;
    Ok(Handoff { ordinal })
}
impl Handoff {
    pub(crate) fn run(self, url: &str, helper: &OsStr) -> io::Result<()> {
        let mut order = ORDER.0.lock().unwrap_or_else(|e| e.into_inner());
        while order.serving != self.ordinal {
            order = ORDER.1.wait(order).unwrap_or_else(|e| e.into_inner());
        }
        drop(order);
        open_url(url, helper)
    }
}
impl Drop for Handoff {
    fn drop(&mut self) {
        let mut order = ORDER.0.lock().unwrap_or_else(|e| e.into_inner());
        order.finished.insert(self.ordinal);
        loop {
            let serving = order.serving;
            if !order.finished.remove(&serving) { break; }
            order.serving = serving.wrapping_add(1);
            order.pending -= 1;
        }
        ORDER.1.notify_all();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
    use std::time::{Instant, SystemTime, UNIX_EPOCH};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new(body: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "graftty-browser-{}-{nonce}-{}",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
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
    fn delayed_first_handoff_preserves_submission_order() {
        // Abandoned reservations release successors, without invoking any helper.
        let abandoned = reserve_handoff().unwrap();
        drop(abandoned);

        let fixture = Fixture::new("case \"$1\" in *first) touch \"$0.started\"; n=0; while [ ! -f \"$0.release\" ]; do n=$((n+1)); [ \"$n\" -lt 300 ] || exit 70; sleep 0.01; done;; esac\nprintf '%s\\n' \"$1\" >> \"$0.receipt\"");
        let (tx, rx) = std::sync::mpsc::channel();
        let first_tx = tx.clone();
        let first = reserve_handoff().unwrap();
        let helper = fixture.helper();
        std::thread::spawn(move || { first_tx.send(first.run("https://example.com/first", helper.as_os_str())).unwrap(); });
        let deadline = Instant::now() + Duration::from_secs(2);
        while !fixture.0.join("helper's executable.started").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let skipped = reserve_handoff().unwrap();
        let second = reserve_handoff().unwrap();
        drop(skipped);
        // Reserve the remaining slots while first is held. Full admission fails
        // immediately, and dropping those slots must not skip the running first.
        let waiting: Vec<_> = (0..6).map(|_| reserve_handoff().unwrap()).collect();
        assert!(reserve_handoff().is_err());
        drop(waiting);
        let helper = fixture.helper();
        std::thread::spawn(move || { tx.send(second.run("https://example.com/second", helper.as_os_str())).unwrap(); });
        // A queued successor must not finish while its predecessor is gated.
        let premature = rx.recv_timeout(Duration::from_millis(200));
        fs::write(fixture.0.join("helper's executable.release"), "").unwrap();
        assert!(premature.is_err(), "second handoff overtook first");
        rx.recv_timeout(Duration::from_secs(3)).unwrap().unwrap();
        rx.recv_timeout(Duration::from_secs(3)).unwrap().unwrap();
        assert_eq!(fs::read_to_string(fixture.0.join("helper's executable.receipt")).unwrap(), "https://example.com/first\nhttps://example.com/second\n");
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
    fn non_web_links_preserve_native_opening_with_a_configured_hook() {
        let fixture = Fixture::new("exit 9");
        for url in [
            "file:///tmp/chart.html",
            "codex://threads/example",
            "mailto:test@example.com",
        ] {
            let mut native_calls = 0;
            dispatch(
                url,
                Some(fixture.helper().as_os_str()),
                Duration::from_secs(1),
                |received| {
                    assert_eq!(received, url);
                    native_calls += 1;
                    Ok(())
                },
            )
            .unwrap();
            assert_eq!(native_calls, 1);
        }
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

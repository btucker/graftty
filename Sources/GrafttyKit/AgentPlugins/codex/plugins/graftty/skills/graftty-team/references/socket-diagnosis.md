# Diagnose socket failures

For `EPERM` or `errno 1`, use read-only checks to confirm `$GRAFTTY_SOCK` exists and a Graftty process owns or listens on it. Retry the same authorized command with narrowly scoped elevated permission outside the sandbox. Retain that execution mode for later socket commands.

Do not delete or recreate the socket, change its permissions, or restart Graftty as a first response. If the elevated retry fails, continue diagnosis. A timeout or connection refusal alone does not establish sandbox denial. Leave queued messages for Graftty's native transport to retry.

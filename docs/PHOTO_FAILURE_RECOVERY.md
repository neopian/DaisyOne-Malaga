# Unreadable photo recovery

A picked photo can become inaccessible before submission. Previously, an error
from `XFile.length()` or `readAsBytes()` escaped as an unclassified exception.
Although no HTTP request had started, the form conservatively treated it as an
unknown outcome and locked the draft.

Only those two local operations are now mapped to `invalid_image`, with a clear
instruction to choose the photo again. Local paths are not exposed. A first such
failure clears the pending operation and keeps the draft editable; a valid
replacement can be submitted normally. HTTP work stays outside the catch.

If an earlier attempt might have reached the server, a later unreadable photo
cannot erase that uncertainty. The form retains the original frozen payload
and request ID. No new point hold is created by a local read failure. Existing
account-change guards remain in place during preprocessing.

Five regressions cover failure while reading length/bytes, unknown transport
failure, replacement after a missing file, and an unreadable retry after a lost
acknowledgement. The widget tests use the real repository, synthetic temporary
PNGs, a mocked picker channel and mocked HTTP. They are not iOS photo-library
validation and do not claim to repair third-party native analyzer findings.

The original local correction passed 312 Flutter tests, clean analysis and the
production web build on 2026-10-02. Following runtime replacement, the same
behavior and regression coverage were restored from recorded source changes;
current verification is listed in [VERIFICATION](VERIFICATION.md). The old local
commit object was unavailable, so the recovered commit has a new identity.

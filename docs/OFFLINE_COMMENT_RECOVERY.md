# Comment recovery during interrupted connectivity

Two failures were reproduced before this correction:

1. A traveler typed an unsent comment on question detail. The automatic
   15-second refresh failed once while offline. After reconnection, the editor
   had been recreated with empty text.
2. An HTTP 408 response discarded the automatic mutation key. Retrying the same
   comment could use a new key and create a second comment, including after
   recreating the API client. Both structured JSON and HTML proxy errors showed
   the problem.

The detail page now owns its comment text and submission state outside the
refresh/error body. A transient refresh cannot discard that input, and the
error view says that the input remains on this screen. It does not show cached
question content. Account/question changes and access-denied/not-found
responses clear the draft. An old response cannot clear a new account/question's
input or show its success message there. An acknowledged post clears the
matching text even while a refresh error hides the editor.

HTTP 408 now retains the original operation key like a local transport timeout.
Retrying identical content can replay the server's recorded result. Acknowledged
success and terminal validation errors retain their existing cleanup behavior.
The server remains authoritative for comment permissions and idempotency.

This comment buffer is scoped to the current detail page in memory. It does not
add durable comment storage across closing the page or restarting the app.
Existing durable question/answer drafts are unchanged. Verification is recorded
in [VERIFICATION](VERIFICATION.md); controlled widget/transport failures are not
claims about real device or mobile-network testing.

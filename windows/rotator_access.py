"""Classify Claude API access failures. No I/O and no tokens.

A subscription-disabled 403 is the API saying this seat cannot use Claude Code.
A quota 429 and a network failure are different things and must not be recorded as this.
"""

DISABLED_MARKERS = (
    "oauth_org_not_allowed",
    "disabled claude subscription access",
    "oauth authentication is currently not allowed",
)

# Stop-hook error tokens. rate_limit / billing_error are the quota stops the hook already
# honoured. oauth_org_not_allowed is the subscription-disabled 403. The hook does not treat
# a normal turn, or a user's quotation of the message, as one of these.
HOOK_ERRORS = {"rate_limit", "billing_error", "oauth_org_not_allowed", "subscription_disabled"}


def _text(body) -> str:
    if body is None:
        return ""
    if isinstance(body, bytes):
        body = body.decode("utf-8", "replace")
    return str(body)[:8000]


def is_subscription_disabled(status, body) -> bool:
    """True only for an explicit HTTP 403 access refusal. Empty, 429, and 5xx are not."""
    try:
        code = int(status or 0)
    except (TypeError, ValueError):
        return False
    if code != 403:
        return False
    low = _text(body).lower()
    if not low.strip():
        return False
    return any(marker in low for marker in DISABLED_MARKERS)


def access_code(body) -> str:
    low = _text(body).lower()
    if "oauth_org_not_allowed" in low:
        return "oauth_org_not_allowed"
    if any(marker in low for marker in DISABLED_MARKERS):
        return "subscription_disabled"
    return ""


def classify_hook(event, transcript_error=""):
    """Return the trigger token, or None when this stop should not rotate.

    Only the hook's error field and the transcript's own API-error token are consulted.
    The rest of the event (including anything the user typed) is ignored.
    """
    err = ""
    if isinstance(event, dict):
        for key in ("error", "api_error"):
            value = event.get(key)
            if isinstance(value, str) and value.strip():
                err = value.strip()
                break
    if err in HOOK_ERRORS:
        return err
    if any(marker in err.lower() for marker in DISABLED_MARKERS):
        return "oauth_org_not_allowed"
    te = (transcript_error or "").strip()
    if te in HOOK_ERRORS:
        return te
    if te and any(marker in te.lower() for marker in DISABLED_MARKERS):
        return "oauth_org_not_allowed"
    return None

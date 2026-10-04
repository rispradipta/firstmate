#!/usr/bin/env python3
# fm-telegram.py - Telegram Bot API transport for bin/fm-telegram.sh.
#
# This file owns the two network calls the Telegram captain channel makes and
# nothing else; bin/fm-telegram.sh owns the cursor, the allowlist, the durable
# note queue, and the reply-delivery ledger. Keeping the HTTP surface here lets
# the shell orchestration be tested against a stub `python3` without a network
# or a live bot token, exactly the way bin/fm-mail.py is tested.
#
# Subcommands (all credentials come from the environment, never argv):
#   poll_list                Call getUpdates once and write one NUL-terminated
#                            record per update to stdout:
#                              update_id \t chat_id \t chat_type \t user_id \t
#                              from_name \t text \x00
#                            The offset is read from FM_TELEGRAM_OFFSET. A
#                            record may carry an empty chat/text for a
#                            non-message update, so the caller can advance the
#                            offset past it. Diagnostics go to stderr; a
#                            network or API failure exits 1.
#   send_message <chat_id>   Read the message text from stdin and call
#                            sendMessage, chunking at the Telegram text limit.
#                            Exits 1 on any failed chunk.
#
# Environment:
#   FM_TELEGRAM_BOT_TOKEN   required bot token (never printed or logged)
#   FM_TELEGRAM_API_BASE    optional API root, default https://api.telegram.org
#   FM_TELEGRAM_OFFSET      next update offset for poll_list, default 0
#   FM_TELEGRAM_POLL_TIMEOUT  optional getUpdates long-poll seconds, default 0
#   FM_TELEGRAM_TIMEOUT     optional HTTP socket timeout seconds, default 20
#
# A diagnostic never contains the token or the request URL, because the URL
# embeds the token: failures are reported by method name and error class only.

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_BASE = "https://api.telegram.org"
DEFAULT_SOCKET_TIMEOUT = 20.0
TELEGRAM_TEXT_LIMIT = 4096


def api_base():
    base = os.environ.get("FM_TELEGRAM_API_BASE") or DEFAULT_API_BASE
    return base.rstrip("/")


def bot_token():
    return os.environ.get("FM_TELEGRAM_BOT_TOKEN", "")


def socket_timeout():
    raw = os.environ.get("FM_TELEGRAM_TIMEOUT", "")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = DEFAULT_SOCKET_TIMEOUT
    if value <= 0:
        value = DEFAULT_SOCKET_TIMEOUT
    return value


def _safe_error(exc):
    # Reduce an exception to a token-free description. The API URL embeds the
    # bot token, so str(exc) must never reach a log.
    if isinstance(exc, urllib.error.HTTPError):
        return "HTTP %s" % exc.code
    reason = getattr(exc, "reason", None)
    if isinstance(reason, OSError) and reason.errno:
        return "%s (errno %s)" % (type(reason).__name__, reason.errno)
    return type(exc).__name__


def call(method, params):
    # Return the parsed `result`, or None after one token-free diagnostic.
    url = "%s/bot%s/%s" % (api_base(), bot_token(), method)
    data = urllib.parse.urlencode(params).encode("utf-8")
    try:
        request = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(request, timeout=socket_timeout()) as response:
            body = response.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - any transport failure is reported cleanly.
        sys.stderr.write("fm-telegram: %s request failed: %s\n" % (method, _safe_error(exc)))
        return None
    try:
        payload = json.loads(body)
    except ValueError:
        sys.stderr.write("fm-telegram: %s returned a non-JSON response\n" % method)
        return None
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        description = ""
        if isinstance(payload, dict):
            description = str(payload.get("description") or "").strip()
        sys.stderr.write(
            "fm-telegram: %s refused: %s\n" % (method, description or "unknown error")
        )
        return None
    return payload.get("result")


def _clean_field(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _record(uid, chat_id, chat_type, user_id, name, text):
    return "\t".join(
        [
            str(uid),
            _clean_field(chat_id),
            _clean_field(chat_type),
            _clean_field(user_id),
            _clean_field(name),
            text,
        ]
    )


def cmd_poll_list():
    offset = os.environ.get("FM_TELEGRAM_OFFSET") or "0"
    if not offset.isdigit():
        offset = "0"
    long_poll = os.environ.get("FM_TELEGRAM_POLL_TIMEOUT") or "0"
    if not long_poll.isdigit():
        long_poll = "0"
    result = call(
        "getUpdates",
        {
            "offset": offset,
            "timeout": long_poll,
            "limit": "100",
            "allowed_updates": '["message"]',
        },
    )
    if result is None:
        return 1
    if not isinstance(result, list):
        sys.stderr.write("fm-telegram: getUpdates returned an unexpected shape\n")
        return 1
    out = sys.stdout.buffer
    for update in result:
        if not isinstance(update, dict):
            sys.stderr.write("fm-telegram: ignored a malformed update record\n")
            continue
        uid = update.get("update_id")
        if not isinstance(uid, int) or isinstance(uid, bool):
            sys.stderr.write("fm-telegram: ignored an update without a numeric update_id\n")
            continue
        chat_id = ""
        chat_type = ""
        user_id = ""
        name = ""
        text = ""
        message = update.get("message")
        if isinstance(message, dict):
            chat = message.get("chat")
            if isinstance(chat, dict):
                chat_id = str(chat.get("id", ""))
                chat_type = str(chat.get("type", ""))
            sender = message.get("from")
            if isinstance(sender, dict):
                user_id = str(sender.get("id", ""))
                name = str(sender.get("username") or sender.get("first_name") or "")
            body = message.get("text")
            if isinstance(body, str):
                text = body
        record = _record(uid, chat_id, chat_type, user_id, name, text)
        out.write(record.encode("utf-8") + b"\x00")
    out.flush()
    return 0


def _chunks(text):
    if not text:
        return []
    return [
        text[index : index + TELEGRAM_TEXT_LIMIT]
        for index in range(0, len(text), TELEGRAM_TEXT_LIMIT)
    ]


def cmd_send_message(argv):
    if len(argv) != 1 or not argv[0]:
        sys.stderr.write("fm-telegram: send_message requires exactly one chat id\n")
        return 2
    chat_id = argv[0]
    text = sys.stdin.read()
    if not text.strip():
        sys.stderr.write("fm-telegram: refusing to send empty text\n")
        return 2
    chunks = _chunks(text)
    if not chunks:
        sys.stderr.write("fm-telegram: refusing to send empty text\n")
        return 2
    for chunk in chunks:
        result = call(
            "sendMessage",
            {
                "chat_id": chat_id,
                "text": chunk,
                "disable_web_page_preview": "true",
            },
        )
        if result is None:
            return 1
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("fm-telegram.py: usage: fm-telegram.py <poll_list|send_message> ...\n")
        return 2
    command = argv[1]
    if command == "poll_list":
        return cmd_poll_list()
    if command == "send_message":
        return cmd_send_message(argv[2:])
    sys.stderr.write("fm-telegram.py: unknown subcommand: %s\n" % command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

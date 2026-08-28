#!/usr/bin/env python3
"""Sync BioTime attendance punches to the Wakulima Dairy ERP.

Meant to be run on a schedule (Windows Task Scheduler) via run_sync.bat.
Each run:
  1. Logs into BioTime and fetches transactions newer than the last sync.
  2. Sends each punch to the ERP with the same curl call already validated
     manually: `curl -G process.php?tp=logattendance&staff_number=...&time=...&temp=...`
  3. Records how far it got in state.json, so a re-run (or the next
     scheduled run) never re-sends a punch that was already delivered, and
     a failed punch is retried next time instead of being skipped.

Config comes from config.json (copy config.example.json and fill it in) with
env vars BIOTIME_USER / BIOTIME_PASSWORD as an override for credentials so
they don't have to live in a file if you'd rather set them on the scheduled
task itself.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

FOLDER = (
    Path(sys.executable).resolve().parent
    if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent
)
CONFIG_PATH = FOLDER / "config.json"
STATE_PATH = FOLDER / "state.json"
LOG_PATH = FOLDER / "sync.log"

PUNCH_TIME_FORMAT = "%Y-%m-%d %H:%M:%S"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(
            f"Missing {CONFIG_PATH}. Copy config.example.json to config.json "
            "and fill in your BioTime and ERP settings."
        )
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    config["biotime_user"] = os.environ.get("BIOTIME_USER", config.get("biotime_user", ""))
    config["biotime_password"] = os.environ.get(
        "BIOTIME_PASSWORD", config.get("biotime_password", "")
    )
    required = ["biotime_url", "biotime_user", "biotime_password", "erp_url", "temperature"]
    missing = [key for key in required if not config.get(key) and config.get(key) != 0]
    if missing:
        sys.exit(f"config.json is missing: {', '.join(missing)}")
    for key in ("biotime_url", "erp_url"):
        if not config[key].startswith(("http://", "https://")):
            sys.exit(f"config.json {key} must start with http:// or https:// (got: {config[key]!r})")
    config.setdefault("lookback_minutes_on_first_run", 60)
    config.setdefault("page_size", 200)
    return config


def load_state() -> dict:
    if not STATE_PATH.exists():
        return {"last_punch_time": None, "sent_ids_at_last_time": []}
    return json.loads(STATE_PATH.read_text(encoding="utf-8"))


def save_state(state: dict) -> None:
    tmp_path = STATE_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(state, indent=2), encoding="utf-8")
    os.replace(tmp_path, STATE_PATH)


class BioTimeClient:
    def __init__(self, base_url: str, username: str, password: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.token: str | None = None

    def _request(self, method: str, path: str, params: dict | None = None, auth: bool = True):
        url = f"{self.base_url}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        headers = {"Accept": "application/json"}
        if auth:
            headers["Authorization"] = f"Token {self.token}"
        req = urllib.request.Request(url, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc

    def login(self) -> None:
        url = f"{self.base_url}/api-token-auth/"
        data = json.dumps({"username": self.username, "password": self.password}).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}, method="POST"
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        token = result.get("token")
        if not token:
            raise RuntimeError(f"Login failed, no token in response: {result}")
        self.token = token

    def iter_new_transactions(self, start_time: str, page_size: int):
        page = 1
        while True:
            payload = self._request(
                "GET",
                "/iclock/api/transactions/",
                params={"start_time": start_time, "page": page, "page_size": page_size},
            )
            rows = payload.get("data") or []
            for row in rows:
                yield row
            if not payload.get("next"):
                break
            page += 1


def send_to_erp(erp_url: str, emp_code: str, punch_epoch: int, temperature: float) -> tuple[bool, str]:
    cmd = [
        "curl",
        "-sS",
        "-G",
        erp_url,
        "--data-urlencode",
        "tp=logattendance",
        "--data-urlencode",
        f"staff_number={emp_code}",
        "--data-urlencode",
        f"time={punch_epoch}",
        "--data-urlencode",
        f"temp={temperature}",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, str(exc)
    if result.returncode != 0:
        return False, f"curl exit {result.returncode}: {result.stderr.strip()}"
    return True, result.stdout.strip()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(LOG_PATH, encoding="utf-8"), logging.StreamHandler(sys.stdout)],
    )

    config = load_config()
    state = load_state()

    last_punch_time = state.get("last_punch_time")
    sent_ids_at_last_time = set(state.get("sent_ids_at_last_time") or [])
    if not last_punch_time:
        lookback = timedelta(minutes=config["lookback_minutes_on_first_run"])
        last_punch_time = (datetime.now() - lookback).strftime(PUNCH_TIME_FORMAT)
        logging.info("No prior state found. First run will look back to %s.", last_punch_time)

    client = BioTimeClient(config["biotime_url"], config["biotime_user"], config["biotime_password"])
    client.login()

    rows = list(client.iter_new_transactions(last_punch_time, config["page_size"]))
    rows = [
        row
        for row in rows
        if not (row.get("punch_time") == last_punch_time and row.get("id") in sent_ids_at_last_time)
    ]
    rows.sort(key=lambda r: (r.get("punch_time") or "", r.get("id") or 0))

    logging.info("Fetched %d new transaction(s) since %s.", len(rows), last_punch_time)

    sent_count = 0
    final_punch_time = last_punch_time
    final_ids: list[int] = list(sent_ids_at_last_time)

    for row in rows:
        emp_code = row.get("emp_code")
        punch_time = row.get("punch_time")
        try:
            punch_epoch = int(datetime.strptime(punch_time, PUNCH_TIME_FORMAT).timestamp())
        except (TypeError, ValueError) as exc:
            logging.error("Skipping transaction id=%s: bad punch_time %r (%s)", row.get("id"), punch_time, exc)
            continue

        ok, detail = send_to_erp(config["erp_url"], emp_code, punch_epoch, config["temperature"])
        if not ok:
            logging.error(
                "Failed to send emp_code=%s punch_time=%s: %s. Stopping run; will retry from here next time.",
                emp_code,
                punch_time,
                detail,
            )
            break

        logging.info("Sent emp_code=%s punch_time=%s -> %s", emp_code, punch_time, detail)
        sent_count += 1

        if punch_time == final_punch_time:
            final_ids.append(row["id"])
        else:
            final_punch_time = punch_time
            final_ids = [row["id"]]

    save_state({"last_punch_time": final_punch_time, "sent_ids_at_last_time": final_ids})
    logging.info("Done. Sent %d/%d transaction(s) this run.", sent_count, len(rows))

    if sent_count < len(rows):
        sys.exit(1)


if __name__ == "__main__":
    main()

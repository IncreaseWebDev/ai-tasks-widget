#!/usr/bin/env python3
"""Collect scheduled tasks from Claude Desktop and the ChatGPT/Codex desktop app.

Reads local files only (read-only), merges both sources and writes one JSON file
the desktop widget renders. Runs on the macOS system Python (3.9), no packages.

States per task:
  attention  - latest run errored, stopped part-way, is waiting on you, or a run was missed
  running    - a run is in progress right now
  completed  - latest run finished cleanly today (or in the current slot for sub-daily tasks)
  scheduled  - nothing run yet for today's slot; shows the next run time
  paused     - task is disabled / paused
"""

import datetime as dt
import glob
import json
import os
import re
import sqlite3
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE_SESSIONS = os.path.join(HOME, "Library/Application Support/Claude/claude-code-sessions")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude/projects")
CODEX_HOME = os.path.join(HOME, ".codex")
OUT_DIR = os.path.join(HOME, "Library/Application Support/AITasksWidget")
OUT_FILE = os.path.join(OUT_DIR, "status.json")
CACHE_FILE = os.path.join(OUT_DIR, "claude-session-cache.json")

MISSED_GRACE = dt.timedelta(hours=2)      # slot passed this long with no run -> missed
RUNNING_WINDOW = dt.timedelta(minutes=3)  # activity this recent with no end -> running
KEEP_FINISHED_ONE_TIME = dt.timedelta(days=2)  # finished one-time tasks drop off after this


def now_local():
    return dt.datetime.now().astimezone()


def from_ms(ms):
    if ms is None:
        return None
    return dt.datetime.fromtimestamp(ms / 1000.0).astimezone()


def from_iso(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def iso(d):
    return d.isoformat() if d else None


def start_of_today(now):
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def fmt_time(d):
    return d.strftime("%-I:%M %p")


# --------------------------------------------------------------------------- cron


def _parse_cron_field(field, lo, hi):
    vals = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, step_s = part.split("/", 1)
            step = int(step_s)
        if part in ("*", ""):
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = b = int(part)
        vals.update(range(a, b + 1, step))
    return vals


class Cron(object):
    """Standard 5-field cron in local time (minute hour day-of-month month day-of-week)."""

    def __init__(self, expr):
        f = expr.split()
        if len(f) != 5:
            raise ValueError("cron needs 5 fields: %r" % expr)
        self.expr = expr
        self.minutes = _parse_cron_field(f[0], 0, 59)
        self.hours = _parse_cron_field(f[1], 0, 23)
        self.dom = _parse_cron_field(f[2], 1, 31)
        self.months = _parse_cron_field(f[3], 1, 12)
        self.dow = {d % 7 for d in _parse_cron_field(f[4], 0, 7)}
        self.dom_any = f[2] == "*"
        self.dow_any = f[4] == "*"

    def _day_ok(self, d):
        if d.month not in self.months:
            return False
        dow = (d.weekday() + 1) % 7  # cron: 0 = Sunday
        if self.dom_any and self.dow_any:
            return True
        if self.dom_any:
            return dow in self.dow
        if self.dow_any:
            return d.day in self.dom
        return d.day in self.dom or dow in self.dow

    def _times_on(self, day):
        out = []
        for h in sorted(self.hours):
            for m in sorted(self.minutes):
                out.append(day.replace(hour=h, minute=m, second=0, microsecond=0))
        return out

    def next_after(self, t):
        day = t.replace(hour=0, minute=0, second=0, microsecond=0)
        for _ in range(400):
            if self._day_ok(day):
                for x in self._times_on(day):
                    if x > t:
                        return x
            day = (day + dt.timedelta(days=1)).replace(hour=0, minute=0)
        return None

    def prev_at_or_before(self, t):
        day = t.replace(hour=0, minute=0, second=0, microsecond=0)
        for _ in range(400):
            if self._day_ok(day):
                for x in reversed(self._times_on(day)):
                    if x <= t:
                        return x
            day = (day - dt.timedelta(days=1)).replace(hour=0, minute=0)
        return None

    def period(self):
        """Rough spacing between runs, used to decide what 'current' means."""
        if len(self.hours) > 1 or len(self.minutes) > 1:
            return "sub-daily"
        return "daily-or-longer"

    def describe(self):
        h = sorted(self.hours)
        m = sorted(self.minutes)
        if len(h) == 1 and len(m) == 1:
            t = dt.datetime(2000, 1, 1, h[0], m[0]).strftime("%-I:%M %p")
        else:
            t = None
        f = self.expr.split()
        if t and self.dom_any and self.dow_any and f[3] == "*":
            return "Daily %s" % t
        if t and self.dom_any and not self.dow_any:
            names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            days = sorted(self.dow)
            if days == [1, 2, 3, 4, 5]:
                return "Weekdays %s" % t
            return "%s %s" % (", ".join(names[d] for d in days), t)
        if t and not self.dom_any and self.dow_any:
            def ordinal(n):
                return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))
            return "Monthly %s, %s" % (" & ".join(ordinal(d) for d in sorted(self.dom)), t)
        return "Cron %s" % self.expr


# --------------------------------------------------------------------------- rrule (Codex)


class RRule(object):
    """Subset of RFC 5545 RRULE used by Codex automations: HOURLY / DAILY / WEEKLY."""

    DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}

    def __init__(self, text):
        self.text = text
        p = {}
        for kv in text.split(";"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                p[k.strip().upper()] = v.strip()
        self.freq = p.get("FREQ", "DAILY")
        self.interval = int(p.get("INTERVAL", "1") or 1)
        self.byhour = [int(x) for x in p["BYHOUR"].split(",")] if "BYHOUR" in p else None
        self.byminute = [int(x) for x in p["BYMINUTE"].split(",")] if "BYMINUTE" in p else None
        self.byday = [self.DAYS[x[-2:]] for x in p["BYDAY"].split(",")] if "BYDAY" in p else None

    def period(self):
        if self.freq in ("MINUTELY", "HOURLY") and not (self.freq == "HOURLY" and self.interval >= 24):
            return "sub-daily"
        return "daily-or-longer"

    def prev_at_or_before(self, t):
        """Most recent slot at or before t (only for DAILY / WEEKLY with fixed times)."""
        if self.freq not in ("DAILY", "WEEKLY") or self.interval != 1:
            return None
        hours = self.byhour or [0]
        minutes = self.byminute or [0]
        day = t.replace(hour=0, minute=0, second=0, microsecond=0)
        for _ in range(15):
            if self.freq == "DAILY" or (self.byday and day.weekday() in self.byday):
                for h in sorted(hours, reverse=True):
                    for m in sorted(minutes, reverse=True):
                        x = day.replace(hour=h, minute=m)
                        if x <= t:
                            return x
            day = day - dt.timedelta(days=1)
        return None

    def describe(self):
        t = None
        if self.byhour and len(self.byhour) == 1:
            t = dt.datetime(2000, 1, 1, self.byhour[0], (self.byminute or [0])[0]).strftime("%-I:%M %p")
        if self.freq == "HOURLY":
            if self.interval == 1:
                return "Every hour"
            if self.interval % 24 == 0:
                return "Every %d days" % (self.interval // 24) if self.interval > 24 else "Daily"
            return "Every %d hours" % self.interval
        if self.freq == "MINUTELY":
            return "Every %d min" % self.interval
        if self.freq == "DAILY":
            return ("Daily %s" % t) if t else "Daily"
        if self.freq == "WEEKLY":
            names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            days = ", ".join(names[d] for d in (self.byday or []))
            return ("Weekly %s %s" % (days, t or "")).strip()
        return self.text


# --------------------------------------------------------------------------- helpers


def first_line(s, limit=140):
    if not s:
        return ""
    s = re.sub(r"\s+", " ", str(s)).strip()
    return s if len(s) <= limit else s[: limit - 1].rstrip() + "…"


def read_frontmatter(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read(4000)
    except OSError:
        return out
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


def pretty_id(task_id):
    return re.sub(r"[-_]+", " ", task_id).strip().capitalize()


def load_cache():
    try:
        with open(CACHE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    tmp = CACHE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cache, fh)
    os.replace(tmp, CACHE_FILE)


# --------------------------------------------------------------------------- Claude


def claude_transcript_stop_reason(cli_session_id):
    """Look at the end of a run's transcript to say why it stopped part-way."""
    if not cli_session_id:
        return None
    paths = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", cli_session_id + ".jsonl"))
    if not paths:
        return None
    try:
        with open(paths[0], "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 60000))
            tail = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    if "doesn't want to proceed with this tool use" in tail or "Request interrupted by user for tool use" in tail:
        return "Stopped: a tool call was not approved"
    if "Request interrupted by user" in tail:
        return "Stopped: run was interrupted"
    return None


def claude_run_from_session(d):
    """Reduce one Claude session file to the fields the widget needs."""
    created = d.get("createdAt")
    last = d.get("lastActivityAt") or created
    pts = d.get("postTurnSummary") or {}
    wrap = d.get("turnWrapUp") or {}
    status = "completed"
    detail = pts.get("status_detail") or wrap.get("description") or ""

    category = (pts.get("status_category") or "").lower()
    needs = (pts.get("needs_action") or "").strip()
    if d.get("error"):
        status, detail = "attention", "Error: %s" % d.get("error")
    elif category and category not in ("completed", "done", "succeeded"):
        status = "attention"
        detail = needs or pts.get("status_detail") or category
    elif needs:
        status, detail = "attention", needs
    elif d.get("interruptedAwaitingPerson"):
        status, detail = "attention", "Waiting on you"
    elif d.get("lastTurnCutShort"):
        status = "attention"
        detail = claude_transcript_stop_reason(d.get("cliSessionId")) or "Stopped before finishing"

    return {
        "session_id": d.get("sessionId"),
        "task_id": d.get("scheduledTaskId"),
        "started_ms": created,
        "last_activity_ms": last,
        "status": status,
        "detail": first_line(detail),
        "archived": bool(d.get("isArchived")),
    }


def collect_claude(now):
    tasks = []
    files = glob.glob(os.path.join(CLAUDE_SESSIONS, "*", "*", "scheduled-tasks.json"))
    if not files:
        return tasks, "No scheduled-tasks.json found under %s" % CLAUDE_SESSIONS

    cache = load_cache()
    new_cache = {}
    for st_file in files:
        folder = os.path.dirname(st_file)
        with open(st_file) as fh:
            data = json.load(fh)

        # Runs: one session file per run, tagged with scheduledTaskId. Cache by mtime.
        runs_by_task = {}
        for sf in glob.glob(os.path.join(folder, "local_*.json")):
            try:
                mtime = os.path.getmtime(sf)
            except OSError:
                continue
            key = sf
            entry = cache.get(key)
            if entry is None or entry.get("mtime") != mtime:
                try:
                    with open(sf) as fh:
                        sd = json.load(fh)
                except (OSError, ValueError):
                    continue
                run = claude_run_from_session(sd) if sd.get("scheduledTaskId") else None
                entry = {"mtime": mtime, "run": run}
            new_cache[key] = entry
            if entry.get("run"):
                runs_by_task.setdefault(entry["run"]["task_id"], []).append(entry["run"])

        skips = data.get("recordedSkips") or {}

        for t in data.get("scheduledTasks", []):
            tid = t["id"]
            fm = read_frontmatter(t.get("filePath") or "")
            title = t.get("displayName") or pretty_id(tid)
            enabled = bool(t.get("enabled"))
            cron = None
            fire_at = from_ms(t.get("fireAt")) if t.get("fireAt") else None
            if t.get("cronExpression"):
                try:
                    cron = Cron(t["cronExpression"])
                except ValueError:
                    cron = None
            runs = sorted(runs_by_task.get(tid, []), key=lambda r: r["started_ms"] or 0)
            latest = runs[-1] if runs else None
            last_run_at = from_iso(t.get("lastRunAt"))

            schedule_text = cron.describe() if cron else (
                "Once, %s" % fire_at.strftime("%b %-d %-I:%M %p") if fire_at else "Manual")
            next_run = None
            prev_slot = None
            if enabled and cron:
                next_run = cron.next_after(now)
                prev_slot = cron.prev_at_or_before(now)
            elif enabled and fire_at:
                if fire_at > now:
                    next_run = fire_at
                else:
                    prev_slot = fire_at

            recent_skips = [s for s in skips.get(tid, []) if s.get("at") and from_ms(s["at"]) > now - dt.timedelta(days=1)]

            task = {
                "source": "claude",
                "id": tid,
                "title": title,
                "description": first_line(fm.get("description", ""), 200),
                "schedule": schedule_text,
                "enabled": enabled,
                "one_time": cron is None,
                "next_run": iso(next_run),
                "last_run": iso(from_ms(latest["last_activity_ms"]) if latest else last_run_at),
                "run_count": len(runs),
                "skips_24h": len(recent_skips),
            }
            decide_state(task, now, latest, prev_slot, last_run_at,
                         period=cron.period() if cron else "one-time", created=from_ms(t.get("createdAt")))
            if task.get("hide"):
                continue
            tasks.append(task)

    try:
        save_cache(new_cache)
    except OSError:
        pass
    return tasks, None


# --------------------------------------------------------------------------- Codex / ChatGPT


def ro_connect(path):
    return sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=2)


def codex_thread_turns(thread_id, since_s):
    db = os.path.join(CODEX_HOME, "thread_history_1.sqlite")
    if not (thread_id and os.path.exists(db)):
        return []
    try:
        con = ro_connect(db)
        rows = con.execute(
            "select status, error_json, started_at, completed_at from thread_turns "
            "where thread_id=? and started_at>=? order by started_at", (thread_id, since_s)).fetchall()
        con.close()
        return rows
    except sqlite3.Error:
        return []


def codex_turn_to_run(row):
    status, error_json, started, completed = row
    s = (status or "").lower()
    if error_json:
        try:
            err = json.loads(error_json)
            msg = err.get("message") if isinstance(err, dict) else str(err)
        except ValueError:
            msg = error_json
        st, detail = "attention", "Error: %s" % first_line(msg)
    elif s in ("completed", "succeeded", "success"):
        st, detail = "completed", ""
    elif s in ("in_progress", "running", "started"):
        st, detail = "running", "Running"
    elif s == "interrupted":
        st, detail = "attention", "Run was interrupted"
    else:
        st, detail = "attention", "Run ended: %s" % (status or "unknown")
    return {"started_ms": (started or 0) * 1000, "last_activity_ms": (completed or started or 0) * 1000,
            "status": st, "detail": detail}


def codex_automation_run(row):
    """automation_runs rows (cron automations get their own thread per run)."""
    status = (row["status"] or "").lower()
    if any(w in status for w in ("fail", "error", "cancel", "interrupt", "block")):
        st = "attention"
    elif any(w in status for w in ("run", "progress", "pending", "queued")):
        st = "running"
    else:
        st = "completed"
    detail = row["inbox_summary"] or row["inbox_title"] or ""
    if st == "attention" and not detail:
        detail = "Run ended: %s" % row["status"]
    return {"started_ms": row["created_at"], "last_activity_ms": row["updated_at"],
            "status": st, "detail": first_line(detail), "raw_status": row["status"]}


def collect_codex(now):
    tasks = []
    db = os.path.join(CODEX_HOME, "sqlite", "codex-dev.db")
    if not os.path.exists(db):
        return tasks, "Codex database not found at %s" % db
    con = ro_connect(db)
    con.row_factory = sqlite3.Row
    autos = con.execute("select * from automations").fetchall()
    runs_rows = []
    try:
        runs_rows = con.execute("select * from automation_runs").fetchall()
    except sqlite3.Error:
        pass
    con.close()

    runs_by_auto = {}
    for r in runs_rows:
        runs_by_auto.setdefault(r["automation_id"], []).append(codex_automation_run(r))

    for a in autos:
        keys = a.keys()
        rr = RRule(a["rrule"] or "")
        enabled = (a["status"] or "").upper() == "ACTIVE"
        kind = a["kind"] if "kind" in keys else "cron"
        target = a["target_thread_id"] if "target_thread_id" in keys else None
        last_run_at = from_ms(a["last_run_at"]) if a["last_run_at"] else None
        next_run = from_ms(a["next_run_at"]) if (enabled and a["next_run_at"]) else None

        runs = list(runs_by_auto.get(a["id"], []))
        if kind == "heartbeat" and target and last_run_at:
            # Heartbeat automations post a turn into an existing thread.
            since = int(last_run_at.timestamp()) - 120
            runs += [codex_turn_to_run(r) for r in codex_thread_turns(target, since)]
        runs.sort(key=lambda r: r["started_ms"] or 0)
        latest = runs[-1] if runs else None

        prev_slot = rr.prev_at_or_before(now) if enabled else None
        task = {
            "source": "codex",
            "id": a["id"],
            "title": a["name"] or pretty_id(a["id"]),
            "description": first_line(a["prompt"], 200),
            "schedule": rr.describe(),
            "enabled": enabled,
            "one_time": False,
            "next_run": iso(next_run),
            "last_run": iso(from_ms(latest["last_activity_ms"]) if latest else last_run_at),
            "run_count": len(runs),
            "skips_24h": 0,
        }
        decide_state(task, now, latest, prev_slot, last_run_at, period=rr.period(),
                     created=from_ms(a["created_at"]) if a["created_at"] else None)
        tasks.append(task)
    return tasks, None


# --------------------------------------------------------------------------- shared state rule


def decide_state(task, now, latest, prev_slot, last_run_at, period, created=None):
    today = start_of_today(now)
    latest_start = from_ms(latest["started_ms"]) if latest else None
    latest_act = from_ms(latest["last_activity_ms"]) if latest else None

    if not task["enabled"]:
        # Finished one-time tasks: show briefly, then drop off. Paused recurring: keep, dimmed.
        if task["one_time"] and latest_act and now - latest_act > KEEP_FINISHED_ONE_TIME:
            task["hide"] = True
            return
        if task["one_time"] and not latest and (not last_run_at or now - last_run_at > KEEP_FINISHED_ONE_TIME):
            task["hide"] = True
            return
        if task["one_time"] and latest:
            task["state"] = latest["status"] if latest["status"] != "running" else "running"
            task["detail"] = latest["detail"] or ("Ran %s" % fmt_time(latest_act))
            return
        task["state"] = "paused"
        task["detail"] = "Paused"
        return

    # Running now?
    if latest and (latest["status"] == "running" or
                   (latest_act and now - latest_act < RUNNING_WINDOW and latest["status"] == "completed"
                    and latest_start and now - latest_start < dt.timedelta(hours=1))):
        task["state"] = "running"
        task["detail"] = "Running since %s" % fmt_time(latest_start)
        return

    # A problem on the most recent run stays yellow until a later run replaces it.
    if latest and latest["status"] == "attention":
        task["state"] = "attention"
        task["detail"] = latest["detail"] or "Needs attention"
        return

    # Missed: the slot passed a while ago and nothing ran for it.
    if prev_slot and now - prev_slot > MISSED_GRACE and not (created and prev_slot < created):
        ran_for_slot = (latest_start and latest_start >= prev_slot - dt.timedelta(minutes=5)) or \
                       (last_run_at and last_run_at >= prev_slot - dt.timedelta(minutes=5))
        if not ran_for_slot and prev_slot >= today - dt.timedelta(days=1):
            task["state"] = "attention"
            task["detail"] = "Missed the %s run" % prev_slot.strftime("%a %-I:%M %p")
            if task.get("skips_24h"):
                task["detail"] += " (skipped %d times)" % task["skips_24h"]
            return

    # Completed for the current window.
    window_start = today
    if period == "sub-daily" and prev_slot:
        window_start = prev_slot - dt.timedelta(minutes=5)
    if latest and latest["status"] == "completed" and latest_start and latest_start >= window_start:
        task["state"] = "completed"
        task["detail"] = latest["detail"] or ("Completed %s" % fmt_time(latest_act))
        return
    if not latest and last_run_at and last_run_at >= window_start:
        # The app recorded a run but kept no session for it, so the outcome is unknown.
        task["state"] = "scheduled"
        task["detail"] = "Ran %s, no result saved" % fmt_time(last_run_at)
        return

    task["state"] = "scheduled"
    if latest_act:
        prev = "done" if latest["status"] == "completed" else latest["status"]
        task["detail"] = "Last run %s (%s)" % (latest_act.strftime("%b %-d"), prev)
    elif last_run_at:
        task["detail"] = "Last ran %s" % last_run_at.strftime("%b %-d")
    else:
        task["detail"] = "Not run yet"


# --------------------------------------------------------------------------- main

ORDER = {"attention": 0, "running": 1, "scheduled": 2, "completed": 3, "paused": 4}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    now = now_local()
    out = {"generated_at": iso(now), "sources": {}, "tasks": []}
    for name, fn in (("claude", collect_claude), ("codex", collect_codex)):
        try:
            tasks, err = fn(now)
            out["sources"][name] = {"ok": err is None, "error": err, "count": len(tasks)}
            out["tasks"].extend(tasks)
        except Exception as e:  # keep the other source working if one breaks
            out["sources"][name] = {"ok": False, "error": "%s: %s" % (type(e).__name__, e), "count": 0}

    far = "9999"
    out["tasks"].sort(key=lambda t: (ORDER.get(t.get("state"), 9), t.get("next_run") or far, t["title"].lower()))
    counts = {}
    for t in out["tasks"]:
        counts[t["state"]] = counts.get(t["state"], 0) + 1
    out["counts"] = counts

    tmp = OUT_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(out, fh, indent=1)
    os.replace(tmp, OUT_FILE)
    if "--print" in sys.argv:
        for t in out["tasks"]:
            print("%-10s %-7s %-42s %-24s next=%-16s %s" % (
                t["state"], t["source"], t["title"][:42], t["schedule"][:24],
                (t["next_run"] or "-")[:16], t.get("detail", "")[:70]))
        print(json.dumps(out["sources"]))


if __name__ == "__main__":
    main()

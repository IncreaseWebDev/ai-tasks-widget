#!/usr/bin/env python3
"""Write docs/sample-status.json: made-up tasks, timed relative to now, for screenshots."""
import datetime as dt, json, os
now = dt.datetime.now().astimezone()
t = lambda **kw: (now + dt.timedelta(**kw)).replace(second=0, microsecond=0).isoformat()

def at(hour, minute=0, days=0):
    """A clock time relative to today, so sample times match their schedules."""
    d = (now + dt.timedelta(days=days)).replace(hour=hour, minute=minute, second=0, microsecond=0)
    return d.isoformat()
tasks = [
  dict(source="codex", id="dep-audit", title="Weekly dependency audit", schedule="Weekly Mon 9:00 AM", state="attention",
       detail="Stopped: a tool call was not approved", next_run=at(9, days=7), last_run=at(9, 4),
       description="Check every project for outdated or vulnerable packages and open one summary issue."),
  dict(source="claude", id="inbox-digest", title="Morning inbox digest", schedule="Daily 7:00 AM", state="attention",
       detail="Missed this morning's 7:00 AM run", next_run=at(7, days=1), last_run=at(7, 2, days=-1),
       description="Summarise unread email into five bullet points and flag anything that needs a reply today."),
  dict(source="claude", id="release-notes", title="Draft release notes", schedule="Weekdays 4:30 PM", state="scheduled",
       detail="Last run yesterday (done)", next_run=at(16, 30), last_run=at(16, 34, days=-1),
       description="Collect merged pull requests and draft plain-language release notes."),
  dict(source="codex", id="backup-check", title="Backup health check", schedule="Daily 6:00 AM", state="completed",
       detail="All 4 backups verified, newest 2 hours old", next_run=at(6, days=1), last_run=at(6, 3),
       description="Confirm last night's backups finished and can be restored."),
  dict(source="claude", id="standup", title="Standup notes", schedule="Weekdays 8:45 AM", state="completed",
       detail="Notes posted, 2 blockers flagged", next_run=at(8, 45, days=1), last_run=at(8, 49),
       description="Turn yesterday's commits and tickets into a short standup update."),
  dict(source="claude", id="invoice-reminder", title="Invoice reminder", schedule="Monthly 1st, 9:00 AM", state="scheduled",
       detail="Not run yet", next_run=(now.replace(day=1, hour=9, minute=0, second=0, microsecond=0) + dt.timedelta(days=32)).replace(day=1).isoformat(), last_run=None,
       description="Remind me which invoices are unpaid after 30 days."),
  dict(source="codex", id="old-report", title="Quarterly report draft", schedule="Every hour", state="paused",
       detail="Paused", next_run=None, last_run=at(10, days=-20), description="Paused experiment."),
]
for x in tasks: x["enabled"] = x["state"] != "paused"
counts = {}
for x in tasks: counts[x["state"]] = counts.get(x["state"], 0) + 1
out = dict(generated_at=now.isoformat(), counts=counts, tasks=tasks,
           sources={"claude": dict(ok=True, error=None, count=4), "codex": dict(ok=True, error=None, count=3)})
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample-status.json")
json.dump(out, open(path, "w"), indent=1)
print(path)

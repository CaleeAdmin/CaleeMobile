#!/usr/bin/env python3
"""
Calee Client API local regression test.

Covers:
- Auth login/bootstrap
- Calendar collection create / rename / delete
- Task-list collection create / rename / delete
- Chore-list collection create / rename / delete
- Event create + read verification
- Task create / edit / complete status / delete
- Chore create / edit / complete / undo completion / delete

Current known API gap:
- Event edit/delete endpoints are not implemented in the current Client API. The script reports them as SKIP.
  Use --require-event-crud to make that gap fail the run.

Usage:
  CALEE_TEST_EMAIL="demo@example.com" \
  CALEE_TEST_PASSWORD="..." \
  python3 calee_client_regression.py --base-url https://hub.calee.com.au

Optional:
  CALEE_TEST_SERVICE_ID="portal" python3 calee_client_regression.py
  python3 calee_client_regression.py --keep-created
  python3 calee_client_regression.py --require-event-crud
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable


class ApiError(Exception):
    def __init__(self, method: str, url: str, status: int, body: Any):
        self.method = method
        self.url = url
        self.status = status
        self.body = body
        super().__init__(f"{method} {url} -> HTTP {status}: {body}")


@dataclass
class StepResult:
    name: str
    status: str
    detail: str = ""


class CaleeClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.access_token: str | None = None

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        query: dict[str, Any] | None = None,
        allow_statuses: set[int] | None = None,
    ) -> tuple[int, Any]:
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)

        data = None
        headers = {
            "Accept": "application/json",
        }

        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        if self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"

        req = urllib.request.Request(url, data=data, method=method, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                parsed = json.loads(raw) if raw else {}
                return resp.status, parsed
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                parsed = {"raw": raw}

            if allow_statuses and e.code in allow_statuses:
                return e.code, parsed

            raise ApiError(method, url, e.code, parsed) from e

    def data(self, method: str, path: str, body: dict[str, Any] | None = None, **kwargs: Any) -> Any:
        _, payload = self.request(method, path, body, **kwargs)
        return payload.get("data", payload)

    def login(self, email: str, password: str) -> dict[str, Any]:
        data = self.data(
            "POST",
            "/client/v1/auth/login",
            {
                "email": email,
                "password": password,
            },
        )
        token = data.get("accessToken")
        if not isinstance(token, str) or not token:
            raise RuntimeError("Login response did not contain data.accessToken")
        self.access_token = token
        return data

    def get(self, path: str, *, query: dict[str, Any] | None = None) -> Any:
        return self.data("GET", path, query=query)

    def post(self, path: str, body: dict[str, Any]) -> Any:
        return self.data("POST", path, body)

    def patch(self, path: str, body: dict[str, Any]) -> Any:
        return self.data("PATCH", path, body)

    def delete(self, path: str, body: dict[str, Any] | None = None, *, allow_statuses: set[int] | None = None) -> tuple[int, Any]:
        return self.request("DELETE", path, body, allow_statuses=allow_statuses)


class Regression:
    def __init__(self, client: CaleeClient, *, keep_created: bool, require_event_crud: bool):
        self.client = client
        self.keep_created = keep_created
        self.require_event_crud = require_event_crud
        self.results: list[StepResult] = []
        self.created_calendar_ids: list[str] = []
        self.created_task_ids: list[str] = []
        self.created_chore_ids: list[str] = []
        self.run_id = dt.datetime.utcnow().strftime("%Y%m%d%H%M%S")
        self.today = dt.date.today()
        self.tomorrow = self.today + dt.timedelta(days=1)

    def record(self, name: str, status: str, detail: str = "") -> None:
        self.results.append(StepResult(name, status, detail))
        icon = {"PASS": "✅", "FAIL": "❌", "SKIP": "⏭️", "INFO": "ℹ️"}.get(status, "•")
        msg = f"{icon} {status:<4} {name}"
        if detail:
            msg += f" — {detail}"
        print(msg, flush=True)

    def run_step(self, name: str, fn: Callable[[], str | None]) -> None:
        try:
            detail = fn() or ""
            self.record(name, "PASS", detail)
        except Exception as e:
            self.record(name, "FAIL", str(e))
            raise

    def encoded(self, value: str) -> str:
        return urllib.parse.quote(value, safe="")

    def pick_service(self, bootstrap: dict[str, Any]) -> dict[str, Any]:
        preferred = os.environ.get("CALEE_TEST_SERVICE_ID", "").strip()
        services = bootstrap.get("bootstrap", {}).get("services", [])
        if not services and "services" in bootstrap:
            services = bootstrap.get("services", [])

        if preferred:
            for service in services:
                if service.get("id") == preferred:
                    return service
            raise RuntimeError(f"CALEE_TEST_SERVICE_ID={preferred!r} was not found in bootstrap services")

        for service in services:
            if (
                service.get("serviceType") == "nextcloud_calendar"
                and service.get("calendarCredentialStatus") in ("connected", None)
            ):
                return service

        for service in services:
            if service.get("serviceType") == "nextcloud_calendar":
                return service

        raise RuntimeError("No nextcloud_calendar service found in bootstrap")

    def create_collection(self, service_id: str, primary_kind: str, label: str) -> dict[str, Any]:
        name = f"RT {label} {self.run_id}"
        data = self.client.post(
            "/client/v1/calendars",
            {
                "serviceId": service_id,
                "name": name,
                "primaryKind": primary_kind,
                "color": "#3366CC",
            },
        )
        calendar = data["calendar"]
        self.created_calendar_ids.append(calendar["id"])
        return calendar

    def rename_collection(self, calendar_id: str, label: str) -> dict[str, Any]:
        data = self.client.patch(
            f"/client/v1/calendars/{self.encoded(calendar_id)}",
            {
                "name": f"RT {label} renamed {self.run_id}",
                "color": "#6633CC",
            },
        )
        return data["calendar"]

    def delete_collection(self, calendar_id: str) -> None:
        self.client.delete(
            f"/client/v1/calendars/{self.encoded(calendar_id)}",
            {"confirmDeleteItems": True},
        )

    def test_collections(self, service_id: str) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
        created: dict[str, dict[str, Any]] = {}

        for kind, label in [
            ("calendar", "calendar"),
            ("tasks", "task-list"),
            ("chores", "chore-list"),
        ]:
            def _create(kind: str = kind, label: str = label) -> str:
                collection = self.create_collection(service_id, kind, label)
                created[kind] = collection
                return f"{collection['name']} ({collection['id']})"

            self.run_step(f"collection create: {kind}", _create)

            def _rename(kind: str = kind, label: str = label) -> str:
                collection = self.rename_collection(created[kind]["id"], label)
                created[kind] = collection
                return collection["name"]

            self.run_step(f"collection rename: {kind}", _rename)

        return created["calendar"], created["tasks"], created["chores"]

    def test_event_create_and_read(self, calendar: dict[str, Any]) -> None:
        event_holder: dict[str, Any] = {}

        def _create_one_off() -> str:
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=9, minute=0))
            end = start + dt.timedelta(minutes=30)
            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT event {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Regression test",
                    "description": "Created by local regression script",
                },
            )
            event_holder["one_off"] = data["event"]
            return data["event"].get("id", "")

        self.run_step("event create: one-off", _create_one_off)

        def _create_recurring() -> str:
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=10, minute=0))
            end = start + dt.timedelta(minutes=30)
            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT recurring event {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "recurrence": "FREQ=DAILY;COUNT=2",
                },
            )
            event_holder["recurring"] = data["event"]
            return data["event"].get("id", "")

        self.run_step("event create: recurring", _create_recurring)

        def _read() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )
            events = data.get("events", [])
            titles = [event.get("title", "") for event in events]
            expected = f"RT event {self.run_id}"
            expected_recurring = f"RT recurring event {self.run_id}"
            if expected not in titles:
                raise RuntimeError(f"Created event title not found in events response: {expected}")

            recurring_occurrences = [
                event
                for event in events
                if event.get("title") == expected_recurring and event.get("recurring") is True
            ]
            if not recurring_occurrences:
                raise RuntimeError(
                    f"Created recurring event occurrence not found in events response: {expected_recurring}"
                )

            occurrence = recurring_occurrences[0]
            occurrence_id = occurrence.get("id", "")
            series_id = occurrence.get("seriesId", "")

            if not occurrence_id or not series_id or occurrence_id == series_id:
                raise RuntimeError(
                    "Recurring event read model did not include distinct occurrence id and series id"
                )

            event_holder["recurring_occurrence"] = occurrence
            return f"{len(events)} events returned"

        self.run_step("event read: created events visible", _read)

        def _edit() -> str:
            event = event_holder["one_off"]
            event_id = event["id"]
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=11, minute=0))
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(event_id)}",
                {
                    "title": f"RT event edited {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Regression test edited",
                    "description": "Edited by local regression script",
                    "recurrence": None,
                },
            )

            event_holder["one_off"] = data["event"]
            return data["event"].get("id", event_id)

        self.run_step("event edit", _edit)

        def _delete() -> str:
            event = event_holder["one_off"]
            event_id = event["id"]
            self.client.delete(f"/client/v1/events/{self.encoded(event_id)}")
            return event_id

        self.run_step("event delete", _delete)

        def _edit_recurring_series_via_occurrence_id() -> str:
            event = event_holder["recurring_occurrence"]
            occurrence_id = event["id"]
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=12, minute=0))
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(occurrence_id)}",
                {
                    "title": f"RT recurring event edited {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Recurring regression test edited",
                    "description": "Edited as whole series via occurrence id",
                },
            )

            event_holder["recurring_occurrence"] = data["event"]
            return data["event"].get("id", occurrence_id)

        self.run_step(
            "recurring event series edit via occurrence id",
            _edit_recurring_series_via_occurrence_id,
        )

        def _read_recurring_series_edit() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            expected = f"RT recurring event edited {self.run_id}"
            matching = [
                event for event in data.get("events", [])
                if event.get("title") == expected and event.get("recurring") is True
            ]

            if not matching:
                raise RuntimeError("Edited recurring series occurrence was not found")

            event_holder["recurring_occurrence"] = matching[0]
            return matching[0].get("id", "")

        self.run_step("recurring event series edit readback", _read_recurring_series_edit)

        def _delete_recurring_series_via_occurrence_id() -> str:
            event = event_holder["recurring_occurrence"]
            occurrence_id = event["id"]
            self.client.delete(f"/client/v1/events/{self.encoded(occurrence_id)}")
            return occurrence_id

        self.run_step(
            "recurring event series delete via occurrence id",
            _delete_recurring_series_via_occurrence_id,
        )

        def _read_recurring_series_delete() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            deleted_title = f"RT recurring event edited {self.run_id}"
            matching = [
                event for event in data.get("events", [])
                if event.get("title") == deleted_title and event.get("recurring") is True
            ]

            if matching:
                raise RuntimeError("Deleted recurring series is still visible")

            return "recurring series no longer visible"

        self.run_step("recurring event series delete readback", _read_recurring_series_delete)

    def test_tasks(self, task_calendar: dict[str, Any]) -> None:
        task_holder: dict[str, Any] = {}

        def _create() -> str:
            data = self.client.post(
                "/client/v1/tasks",
                {
                    "serviceId": task_calendar["serviceId"],
                    "calendarId": task_calendar["id"],
                    "title": f"RT task {self.run_id}",
                    "dueAt": self.tomorrow.isoformat(),
                    "description": "Created by local regression script",
                },
            )
            task = data["task"]
            task_holder["task"] = task
            self.created_task_ids.append(task["id"])
            return task["id"]

        self.run_step("task create", _create)

        def _edit() -> str:
            task_id = task_holder["task"]["id"]
            data = self.client.patch(
                "/client/v1/tasks",
                {
                    "taskId": task_id,
                    "title": f"RT task edited {self.run_id}",
                    "dueAt": (self.tomorrow + dt.timedelta(days=1)).isoformat(),
                    "description": "Edited by local regression script",
                },
            )
            task_holder["task"] = data["task"]
            return data["task"]["title"]

        self.run_step("task edit", _edit)

        def _complete() -> str:
            task_id = task_holder["task"]["id"]
            data = self.client.patch(
                "/client/v1/tasks",
                {
                    "taskId": task_id,
                    "completed": True,
                },
            )
            task_holder["task"] = data["task"]
            return "completed=true"

        self.run_step("task complete status", _complete)

        def _delete() -> str:
            task_id = task_holder["task"]["id"]
            self.client.delete(f"/client/v1/tasks/{self.encoded(task_id)}")
            self.created_task_ids.remove(task_id)
            return task_id

        self.run_step("task delete", _delete)

    def test_chores(self, chore_calendar: dict[str, Any]) -> None:
        chore_holder: dict[str, Any] = {}

        def _create() -> str:
            data = self.client.post(
                "/client/v1/chores",
                {
                    "serviceId": chore_calendar["serviceId"],
                    "calendarId": chore_calendar["id"],
                    "title": f"RT chore {self.run_id}",
                    "scheduledAt": self.today.isoformat(),
                    "description": "Created by local regression script",
                    "recurrence": "FREQ=WEEKLY",
                    "points": 2,
                },
            )
            chore = data["chore"]
            chore_holder["chore"] = chore
            self.created_chore_ids.append(chore["id"])
            return chore["id"]

        self.run_step("chore create", _create)

        def _edit() -> str:
            chore_id = chore_holder["chore"]["id"]
            data = self.client.patch(
                f"/client/v1/chores/{self.encoded(chore_id)}",
                {
                    "title": f"RT chore edited {self.run_id}",
                    "scheduledAt": self.tomorrow.isoformat(),
                    "description": "Edited by local regression script",
                    "recurrence": "FREQ=DAILY",
                    "points": 2,
                },
            )
            chore_holder["chore"] = data["chore"]
            return data["chore"]["title"]

        self.run_step("chore edit", _edit)

        def _complete() -> str:
            chore_id = chore_holder["chore"]["id"]
            self.client.post(
                f"/client/v1/chores/{self.encoded(chore_id)}/complete",
                {"date": self.today.isoformat()},
            )
            return "completed today"

        self.run_step("chore complete", _complete)

        def _undo() -> str:
            chore_id = chore_holder["chore"]["id"]
            self.client.delete(f"/client/v1/chores/{self.encoded(chore_id)}/completion/today")
            return "completion removed"

        self.run_step("chore undo completion", _undo)

        def _delete() -> str:
            chore_id = chore_holder["chore"]["id"]
            self.client.delete(f"/client/v1/chores/{self.encoded(chore_id)}")
            self.created_chore_ids.remove(chore_id)
            return chore_id

        self.run_step("chore delete", _delete)

    def cleanup(self) -> None:
        if self.keep_created:
            self.record("cleanup", "SKIP", "--keep-created enabled")
            return

        # Delete leaf items first. Calendar collection deletion is the main cleanup, but this gives better diagnostics.
        for task_id in list(self.created_task_ids):
            try:
                self.client.delete(f"/client/v1/tasks/{self.encoded(task_id)}", allow_statuses={404})
                self.created_task_ids.remove(task_id)
                self.record("cleanup task", "PASS", task_id)
            except Exception as e:
                self.record("cleanup task", "FAIL", f"{task_id}: {e}")

        for chore_id in list(self.created_chore_ids):
            try:
                self.client.delete(f"/client/v1/chores/{self.encoded(chore_id)}", allow_statuses={404})
                self.created_chore_ids.remove(chore_id)
                self.record("cleanup chore", "PASS", chore_id)
            except Exception as e:
                self.record("cleanup chore", "FAIL", f"{chore_id}: {e}")

        for calendar_id in reversed(list(self.created_calendar_ids)):
            try:
                self.delete_collection(calendar_id)
                self.created_calendar_ids.remove(calendar_id)
                self.record("cleanup collection", "PASS", calendar_id)
            except Exception as e:
                self.record("cleanup collection", "FAIL", f"{calendar_id}: {e}")

    def run(self, email: str, password: str) -> int:
        try:
            bootstrap_holder: dict[str, Any] = {}

            def _login() -> str:
                bootstrap_holder["payload"] = self.client.login(email, password)
                return "access token received"

            self.run_step("auth login", _login)

            service = self.pick_service(bootstrap_holder["payload"])
            service_id = service["id"]
            self.record("service selected", "INFO", f"{service_id} ({service.get('displayName', '')})")

            calendar_collection, task_collection, chore_collection = self.test_collections(service_id)
            self.test_event_create_and_read(calendar_collection)
            self.test_tasks(task_collection)
            self.test_chores(chore_collection)

            return 0
        finally:
            self.cleanup()
            self.print_summary()

    def print_summary(self) -> None:
        print("\n=== Summary ===")
        counts: dict[str, int] = {}
        for result in self.results:
            counts[result.status] = counts.get(result.status, 0) + 1
        for status in ["PASS", "FAIL", "SKIP", "INFO"]:
            if status in counts:
                print(f"{status}: {counts[status]}")
        failures = [r for r in self.results if r.status == "FAIL"]
        if failures:
            print("\nFailures:")
            for result in failures:
                print(f"- {result.name}: {result.detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Calee Client API local regression tests.")
    parser.add_argument("--base-url", default=os.environ.get("CALEE_API_BASE", "https://hub.calee.com.au"))
    parser.add_argument("--email", default=os.environ.get("CALEE_TEST_EMAIL"))
    parser.add_argument("--password", default=os.environ.get("CALEE_TEST_PASSWORD"))
    parser.add_argument("--keep-created", action="store_true", help="Do not delete test collections/items after the run.")
    parser.add_argument(
        "--require-event-crud",
        action="store_true",
        help="Fail if event edit/delete endpoints are not implemented.",
    )
    args = parser.parse_args()

    if not args.email or not args.password:
        print(
            "Missing credentials. Set CALEE_TEST_EMAIL and CALEE_TEST_PASSWORD, "
            "or pass --email and --password.",
            file=sys.stderr,
        )
        return 2

    client = CaleeClient(args.base_url)
    runner = Regression(
        client,
        keep_created=args.keep_created,
        require_event_crud=args.require_event_crud,
    )

    try:
        return runner.run(args.email, args.password)
    except Exception:
        print("\n=== Unhandled failure ===", file=sys.stderr)
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

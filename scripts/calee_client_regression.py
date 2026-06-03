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
  CALEE_TEST_SERVICE_ID="business" python3 calee_client_regression.py
  CALEE_TEST_CHORE_SERVICE_ID="portal" python3 calee_client_regression.py
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

    def patch(
        self,
        path: str,
        body: dict[str, Any],
        *,
        query: dict[str, Any] | None = None,
    ) -> Any:
        return self.data("PATCH", path, body, query=query)

    def delete(
        self,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        query: dict[str, Any] | None = None,
        allow_statuses: set[int] | None = None,
    ) -> tuple[int, Any]:
        return self.request("DELETE", path, body, query=query, allow_statuses=allow_statuses)


class Regression:
    def __init__(self, client: CaleeClient, *, keep_created: bool, require_event_crud: bool):
        self.client = client
        self.keep_created = keep_created
        self.require_event_crud = require_event_crud
        self.results: list[StepResult] = []
        self.created_calendar_ids: list[str] = []
        self.created_task_ids: list[str] = []
        self.created_chore_ids: list[str] = []
        self.created_person_ids: list[tuple[str, str]] = []  # (household_id, person_id)
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

    def encoded(self, value: Any) -> str:
        return urllib.parse.quote(str(value), safe="")

    def event_date(self, value: Any) -> str:
        text = str(value or "").strip()
        return text[:10] if len(text) >= 10 else text

    def bootstrap_services(self, bootstrap: dict[str, Any]) -> list[dict[str, Any]]:
        services = bootstrap.get("bootstrap", {}).get("services", [])
        if not services and "services" in bootstrap:
            services = bootstrap.get("services", [])
        return list(services)

    def is_calendar_service(self, service: dict[str, Any]) -> bool:
        return service.get("serviceType") in ("nextcloud_calendar", "nextcloud_portal")

    def has_connected_calendar_credential(self, service: dict[str, Any]) -> bool:
        return service.get("calendarCredentialStatus") in ("connected", None)

    def pick_service(self, bootstrap: dict[str, Any]) -> dict[str, Any]:
        preferred = os.environ.get("CALEE_TEST_SERVICE_ID", "").strip()
        services = self.bootstrap_services(bootstrap)

        if preferred:
            for service in services:
                if service.get("id") == preferred:
                    return service
            raise RuntimeError(f"CALEE_TEST_SERVICE_ID={preferred!r} was not found in bootstrap services")

        for service in services:
            if self.is_calendar_service(service) and self.has_connected_calendar_credential(service):
                return service

        for service in services:
            if self.is_calendar_service(service):
                return service

        raise RuntimeError("No calendar-capable service found in bootstrap")

    def pick_chore_service(self, bootstrap: dict[str, Any]) -> dict[str, Any]:
        preferred = os.environ.get("CALEE_TEST_CHORE_SERVICE_ID", "portal").strip() or "portal"
        services = self.bootstrap_services(bootstrap)

        for service in services:
            if service.get("id") == preferred:
                if not self.is_calendar_service(service):
                    raise RuntimeError(
                        f"CALEE_TEST_CHORE_SERVICE_ID={preferred!r} is not calendar-capable"
                    )
                if not self.has_connected_calendar_credential(service):
                    raise RuntimeError(
                        f"CALEE_TEST_CHORE_SERVICE_ID={preferred!r} does not have connected calendar credentials"
                    )
                return service

        raise RuntimeError(
            f"Portal chore service {preferred!r} was not found in bootstrap services. "
            "Set CALEE_TEST_CHORE_SERVICE_ID to the portal service id."
        )

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

    def test_collections(
        self,
        service_id: str,
        *,
        chore_service_id: str,
    ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
        created: dict[str, dict[str, Any]] = {}

        collection_specs = [
            ("calendar", "calendar", service_id),
            ("tasks", "task-list", service_id),
            ("chores", "chore-list", chore_service_id),
        ]

        for kind, label, target_service_id in collection_specs:
            def _create(
                kind: str = kind,
                label: str = label,
                target_service_id: str = target_service_id,
            ) -> str:
                collection = self.create_collection(target_service_id, kind, label)
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

        def _create_all_day_multiday() -> str:
            start_date = self.tomorrow
            end_date = start_date + dt.timedelta(days=3)

            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT all-day multi-day event {self.run_id}",
                    "startsAt": start_date.isoformat(),
                    "endsAt": end_date.isoformat(),
                    "allDay": True,
                    "description": "Created by local regression script",
                },
            )

            event_holder["all_day_multiday"] = data["event"]
            return data["event"].get("id", "")

        self.run_step("event create: all-day multi-day", _create_all_day_multiday)

        def _create_recurring_count() -> str:
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=10, minute=0))
            end = start + dt.timedelta(minutes=30)
            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT recurring count event {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "recurrence": "FREQ=DAILY;COUNT=2",
                },
            )
            event_holder["recurring"] = data["event"]
            return data["event"].get("id", "")

        self.run_step("event create: recurring count", _create_recurring_count)

        def _create_recurring_until() -> str:
            start_date = self.tomorrow
            end_date = start_date + dt.timedelta(days=1)
            until_date = start_date + dt.timedelta(days=2)

            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT recurring until event {self.run_id}",
                    "startsAt": start_date.isoformat(),
                    "endsAt": end_date.isoformat(),
                    "allDay": True,
                    "recurrence": f"FREQ=DAILY;UNTIL={until_date.strftime('%Y%m%d')}",
                },
            )
            event_holder["recurring_until"] = data["event"]
            return data["event"].get("id", "")

        self.run_step("event create: recurring until", _create_recurring_until)

        def _create_recurring_occurrence_delete() -> str:
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=13, minute=0))
            end = start + dt.timedelta(minutes=30)

            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT recurring occurrence delete event {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "recurrence": "FREQ=DAILY;COUNT=3",
                },
            )

            event_holder["recurring_occurrence_delete"] = data["event"]
            return data["event"].get("id", "")

        self.run_step(
            "event create: recurring occurrence delete",
            _create_recurring_occurrence_delete,
        )

        def _create_recurring_occurrence_edit() -> str:
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=14, minute=0))
            end = start + dt.timedelta(minutes=30)

            data = self.client.post(
                "/client/v1/events",
                {
                    "serviceId": calendar["serviceId"],
                    "calendarId": calendar["id"],
                    "title": f"RT recurring occurrence edit event {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "recurrence": "FREQ=DAILY;COUNT=3",
                },
            )

            event_holder["recurring_occurrence_edit"] = data["event"]
            return data["event"].get("id", "")

        self.run_step(
            "event create: recurring occurrence edit",
            _create_recurring_occurrence_edit,
        )

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
            expected_all_day_multiday = f"RT all-day multi-day event {self.run_id}"
            expected_recurring_count = f"RT recurring count event {self.run_id}"
            expected_recurring_until = f"RT recurring until event {self.run_id}"
            expected_occurrence_delete = f"RT recurring occurrence delete event {self.run_id}"
            expected_occurrence_edit = f"RT recurring occurrence edit event {self.run_id}"

            if expected not in titles:
                raise RuntimeError(f"Created event title not found in events response: {expected}")

            all_day_matches = [
                event
                for event in events
                if event.get("title") == expected_all_day_multiday
            ]

            if len(all_day_matches) != 1:
                raise RuntimeError(
                    f"Expected 1 multi-day all-day event, found {len(all_day_matches)}"
                )

            all_day_event = all_day_matches[0]
            expected_start = self.tomorrow.isoformat()
            expected_end = (self.tomorrow + dt.timedelta(days=3)).isoformat()

            if all_day_event.get("allDay") is not True:
                raise RuntimeError("Multi-day all-day event was not returned as all-day")

            actual_start = self.event_date(all_day_event.get("startsAt"))
            actual_end = self.event_date(all_day_event.get("endsAt"))

            if actual_start != expected_start:
                raise RuntimeError(
                    f"Expected all-day startsAt {expected_start}, got {all_day_event.get('startsAt')}"
                )

            if actual_end != expected_end:
                raise RuntimeError(
                    f"Expected all-day exclusive endsAt {expected_end}, got {all_day_event.get('endsAt')}"
                )

            event_holder["all_day_multiday"] = all_day_event

            recurring_count_occurrences = [
                event
                for event in events
                if event.get("title") == expected_recurring_count and event.get("recurring") is True
            ]
            if len(recurring_count_occurrences) != 2:
                raise RuntimeError(
                    f"Expected 2 COUNT recurring occurrences, found {len(recurring_count_occurrences)}"
                )

            recurring_until_occurrences = [
                event
                for event in events
                if event.get("title") == expected_recurring_until and event.get("recurring") is True
            ]
            if len(recurring_until_occurrences) != 3:
                raise RuntimeError(
                    f"Expected 3 UNTIL recurring occurrences, found {len(recurring_until_occurrences)}"
                )

            if not all(event.get("allDay") is True for event in recurring_until_occurrences):
                raise RuntimeError("UNTIL recurring all-day occurrences were not returned as all-day events")

            occurrence_delete_occurrences = [
                event
                for event in events
                if event.get("title") == expected_occurrence_delete and event.get("recurring") is True
            ]
            if len(occurrence_delete_occurrences) != 3:
                raise RuntimeError(
                    f"Expected 3 occurrence-delete test occurrences, found {len(occurrence_delete_occurrences)}"
                )

            occurrence_delete_occurrences.sort(key=lambda event: str(event.get("startsAt", "")))
            event_holder["occurrence_delete_all"] = occurrence_delete_occurrences
            event_holder["occurrence_delete_middle"] = occurrence_delete_occurrences[1]

            occurrence_edit_occurrences = [
                event
                for event in events
                if event.get("title") == expected_occurrence_edit and event.get("recurring") is True
            ]
            if len(occurrence_edit_occurrences) != 3:
                raise RuntimeError(
                    f"Expected 3 occurrence-edit test occurrences, found {len(occurrence_edit_occurrences)}"
                )

            occurrence_edit_occurrences.sort(key=lambda event: str(event.get("startsAt", "")))
            event_holder["occurrence_edit_all"] = occurrence_edit_occurrences
            event_holder["occurrence_edit_middle"] = occurrence_edit_occurrences[1]

            occurrence = recurring_count_occurrences[0]
            occurrence_id = occurrence.get("id", "")
            series_id = occurrence.get("seriesId", "")

            if not occurrence_id or not series_id or occurrence_id == series_id:
                raise RuntimeError(
                    "Recurring event read model did not include distinct occurrence id and series id"
                )

            event_holder["recurring_occurrence"] = occurrence
            return (
                f"{len(events)} events returned; "
                f"COUNT occurrences={len(recurring_count_occurrences)}, "
                f"UNTIL occurrences={len(recurring_until_occurrences)}, "
                f"occurrence-delete occurrences={len(occurrence_delete_occurrences)}, "
                f"occurrence-edit occurrences={len(occurrence_edit_occurrences)}"
            )

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

        def _update_one_off_to_recurring() -> str:
            event = event_holder["one_off"]
            event_id = event["id"]
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=11, minute=0))
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(event_id)}",
                {
                    "title": f"RT event recurrence updated {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Regression test recurrence updated",
                    "description": "Updated to recurring by local regression script",
                    "recurrence": "FREQ=DAILY;COUNT=2",
                },
            )

            event_holder["one_off"] = data["event"]
            return data["event"].get("id", event_id)

        self.run_step("event recurrence update: one-off to count", _update_one_off_to_recurring)

        def _read_one_off_to_recurring() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            expected = f"RT event recurrence updated {self.run_id}"
            occurrences = [
                event
                for event in data.get("events", [])
                if event.get("title") == expected and event.get("recurring") is True
            ]

            if len(occurrences) != 2:
                raise RuntimeError(
                    f"Expected updated event to have 2 recurring occurrences, found {len(occurrences)}"
                )

            event_holder["one_off_recurring_occurrence"] = occurrences[0]
            return f"updated recurring occurrences={len(occurrences)}"

        self.run_step("event recurrence update readback", _read_one_off_to_recurring)

        def _clear_event_recurrence() -> str:
            event = event_holder["one_off_recurring_occurrence"]
            event_id = event.get("seriesId") or event["id"]
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=11, minute=0))
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(event_id)}",
                {
                    "title": f"RT event recurrence cleared {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Regression test recurrence cleared",
                    "description": "Cleared recurrence by local regression script",
                    "recurrence": None,
                },
            )

            event_holder["one_off"] = data["event"]
            return data["event"].get("id", event_id)

        self.run_step("event recurrence clear", _clear_event_recurrence)

        def _read_recurrence_clear() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            cleared_title = f"RT event recurrence cleared {self.run_id}"
            recurring_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == cleared_title and event.get("recurring") is True
            ]
            one_off_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == cleared_title and event.get("recurring") is not True
            ]

            if recurring_matches:
                raise RuntimeError("Cleared recurrence event is still returned as recurring")

            if not one_off_matches:
                raise RuntimeError("Cleared recurrence event was not returned as a one-off event")

            event_holder["one_off"] = one_off_matches[0]
            return "event returned as one-off"

        self.run_step("event recurrence clear readback", _read_recurrence_clear)

        def _edit_all_day_multiday() -> str:
            event = event_holder["all_day_multiday"]
            event_id = event["id"]
            start_date = self.tomorrow
            end_date = start_date + dt.timedelta(days=4)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(event_id)}",
                {
                    "title": f"RT all-day multi-day event edited {self.run_id}",
                    "startsAt": start_date.isoformat(),
                    "endsAt": end_date.isoformat(),
                    "allDay": True,
                    "description": "Edited by local regression script",
                    "recurrence": None,
                },
            )

            event_holder["all_day_multiday"] = data["event"]
            return data["event"].get("id", event_id)

        self.run_step("event edit: all-day multi-day", _edit_all_day_multiday)

        def _read_all_day_multiday_edit() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            expected = f"RT all-day multi-day event edited {self.run_id}"
            matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == expected
            ]

            if len(matches) != 1:
                raise RuntimeError(
                    f"Expected edited multi-day all-day event once, found {len(matches)}"
                )

            event = matches[0]
            expected_end = (self.tomorrow + dt.timedelta(days=4)).isoformat()

            if event.get("allDay") is not True:
                raise RuntimeError("Edited multi-day event was not returned as all-day")

            actual_end = self.event_date(event.get("endsAt"))

            if actual_end != expected_end:
                raise RuntimeError(
                    f"Expected edited all-day exclusive endsAt {expected_end}, got {event.get('endsAt')}"
                )

            event_holder["all_day_multiday"] = event
            return f"exclusive endsAt={event.get('endsAt')}"

        self.run_step("event edit readback: all-day multi-day", _read_all_day_multiday_edit)

        def _delete_all_day_multiday() -> str:
            event = event_holder["all_day_multiday"]
            event_id = event["id"]
            self.client.delete(f"/client/v1/events/{self.encoded(event_id)}")
            return event_id

        self.run_step("event delete: all-day multi-day", _delete_all_day_multiday)

        def _delete() -> str:
            event = event_holder["one_off"]
            event_id = event["id"]
            self.client.delete(f"/client/v1/events/{self.encoded(event_id)}")
            return event_id

        self.run_step("event delete", _delete)

        def _delete_one_recurring_occurrence() -> str:
            occurrence = event_holder["occurrence_delete_middle"]
            occurrence_id = occurrence["id"]

            self.client.delete(
                f"/client/v1/events/{self.encoded(occurrence_id)}",
                query={"scope": "occurrence"},
            )

            return occurrence_id

        self.run_step(
            "recurring event occurrence delete",
            _delete_one_recurring_occurrence,
        )

        def _read_one_recurring_occurrence_delete() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            deleted_occurrence = event_holder["occurrence_delete_middle"]
            deleted_occurrence_id = deleted_occurrence["id"]
            title = f"RT recurring occurrence delete event {self.run_id}"

            remaining = [
                event
                for event in data.get("events", [])
                if event.get("title") == title and event.get("recurring") is True
            ]

            remaining_ids = {event.get("id") for event in remaining}

            if deleted_occurrence_id in remaining_ids:
                raise RuntimeError("Deleted recurring occurrence is still visible")

            if len(remaining) != 2:
                raise RuntimeError(
                    f"Expected 2 remaining recurring occurrences after occurrence delete, found {len(remaining)}"
                )

            if len({event.get("seriesId") for event in remaining}) != 1:
                raise RuntimeError("Remaining occurrences do not belong to one series")

            event_holder["occurrence_delete_remaining"] = remaining
            return f"remaining occurrences={len(remaining)}"

        self.run_step(
            "recurring event occurrence delete readback",
            _read_one_recurring_occurrence_delete,
        )

        def _delete_occurrence_delete_series_cleanup() -> str:
            remaining = event_holder["occurrence_delete_remaining"]
            series_id = remaining[0].get("seriesId") or remaining[0]["id"]

            self.client.delete(f"/client/v1/events/{self.encoded(series_id)}")
            return series_id

        self.run_step(
            "recurring event occurrence delete cleanup",
            _delete_occurrence_delete_series_cleanup,
        )

        def _edit_one_recurring_occurrence() -> str:
            occurrence = event_holder["occurrence_edit_middle"]
            occurrence_id = occurrence["id"]
            start = dt.datetime.combine(
                self.tomorrow + dt.timedelta(days=1),
                dt.time(hour=15, minute=15),
            )
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(occurrence_id)}",
                {
                    "title": f"RT recurring occurrence edited {self.run_id}",
                    "startsAt": start.isoformat(),
                    "endsAt": end.isoformat(),
                    "allDay": False,
                    "location": "Recurring occurrence regression test edited",
                    "description": "Edited only this occurrence by local regression script",
                    "recurrence": None,
                },
                query={"scope": "occurrence"},
            )

            event_holder["occurrence_edit_middle"] = data["event"]
            return data["event"].get("id", occurrence_id)

        self.run_step(
            "recurring event occurrence edit",
            _edit_one_recurring_occurrence,
        )

        def _read_one_recurring_occurrence_edit() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            original_title = f"RT recurring occurrence edit event {self.run_id}"
            edited_title = f"RT recurring occurrence edited {self.run_id}"
            edited_occurrence = event_holder["occurrence_edit_middle"]
            edited_occurrence_id = edited_occurrence["id"]

            original_remaining = [
                event
                for event in data.get("events", [])
                if event.get("title") == original_title and event.get("recurring") is True
            ]
            edited_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == edited_title and event.get("recurring") is True
            ]

            if len(original_remaining) != 2:
                raise RuntimeError(
                    f"Expected 2 original recurring occurrences after occurrence edit, found {len(original_remaining)}"
                )

            if len(edited_matches) != 1:
                raise RuntimeError(
                    f"Expected 1 edited detached recurring occurrence, found {len(edited_matches)}"
                )

            edited = edited_matches[0]
            if edited.get("id") != edited_occurrence_id:
                raise RuntimeError(
                    f"Edited detached occurrence id changed from {edited_occurrence_id} to {edited.get('id')}"
                )

            series_ids = {event.get("seriesId") for event in original_remaining + edited_matches}
            if len(series_ids) != 1:
                raise RuntimeError("Edited detached occurrence does not share the original series id")

            event_holder["occurrence_edit_remaining"] = original_remaining + edited_matches
            return (
                f"original occurrences={len(original_remaining)}, "
                f"edited occurrences={len(edited_matches)}"
            )

        self.run_step(
            "recurring event occurrence edit readback",
            _read_one_recurring_occurrence_edit,
        )

        def _edit_series_after_detached_occurrence() -> str:
            remaining = event_holder["occurrence_edit_remaining"]
            series_id = remaining[0].get("seriesId") or remaining[0]["id"]

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(series_id)}",
                {
                    "title": f"RT recurring occurrence edit series updated {self.run_id}",
                    "location": "Series metadata updated after detached occurrence edit",
                    "description": "Regression test for preserving detached occurrence during series metadata update",
                },
            )

            return data["event"].get("id", series_id)

        self.run_step(
            "recurring event series update after detached edit",
            _edit_series_after_detached_occurrence,
        )

        def _read_series_update_preserves_detached_occurrence() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            original_title = f"RT recurring occurrence edit event {self.run_id}"
            detached_title = f"RT recurring occurrence edited {self.run_id}"
            series_title = f"RT recurring occurrence edit series updated {self.run_id}"
            detached_occurrence_id = event_holder["occurrence_edit_middle"]["id"]

            original_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == original_title and event.get("recurring") is True
            ]
            detached_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == detached_title and event.get("recurring") is True
            ]
            series_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == series_title and event.get("recurring") is True
            ]

            if original_matches:
                raise RuntimeError(
                    f"Original series title still visible after series update: {len(original_matches)}"
                )

            if len(detached_matches) != 1:
                raise RuntimeError(
                    f"Expected detached edited occurrence to remain once, found {len(detached_matches)}"
                )

            detached = detached_matches[0]
            if detached.get("id") != detached_occurrence_id:
                raise RuntimeError(
                    f"Detached occurrence id changed from {detached_occurrence_id} to {detached.get('id')}"
                )

            if len(series_matches) != 2:
                raise RuntimeError(
                    f"Expected 2 updated series occurrences excluding detached occurrence, found {len(series_matches)}"
                )

            series_ids = {
                event.get("seriesId")
                for event in series_matches + detached_matches
            }
            if len(series_ids) != 1:
                raise RuntimeError(
                    "Detached occurrence and updated series occurrences do not share one series id"
                )

            event_holder["occurrence_edit_remaining"] = series_matches + detached_matches
            return (
                f"updated series occurrences={len(series_matches)}, "
                f"detached occurrences={len(detached_matches)}"
            )

        self.run_step(
            "recurring event series update preserves detached occurrence",
            _read_series_update_preserves_detached_occurrence,
        )

        def _delete_edited_recurring_occurrence() -> str:
            detached = event_holder["occurrence_edit_middle"]
            occurrence_id = detached["id"]

            self.client.delete(
                f"/client/v1/events/{self.encoded(occurrence_id)}",
                query={"scope": "occurrence"},
            )

            return occurrence_id

        self.run_step(
            "recurring event edited occurrence delete",
            _delete_edited_recurring_occurrence,
        )

        def _read_edited_recurring_occurrence_delete() -> str:
            data = self.client.get(
                "/client/v1/events",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=7)).isoformat(),
                },
            )

            detached_title = f"RT recurring occurrence edited {self.run_id}"
            series_title = f"RT recurring occurrence edit series updated {self.run_id}"
            deleted_occurrence_id = event_holder["occurrence_edit_middle"]["id"]

            detached_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == detached_title and event.get("recurring") is True
            ]
            series_matches = [
                event
                for event in data.get("events", [])
                if event.get("title") == series_title and event.get("recurring") is True
            ]

            if detached_matches:
                raise RuntimeError(
                    f"Deleted edited detached occurrence is still visible: {deleted_occurrence_id}"
                )

            if len(series_matches) != 2:
                raise RuntimeError(
                    f"Expected 2 remaining series occurrences after deleting edited occurrence, found {len(series_matches)}"
                )

            event_holder["occurrence_edit_remaining"] = series_matches
            return f"remaining series occurrences={len(series_matches)}"

        self.run_step(
            "recurring event edited occurrence delete readback",
            _read_edited_recurring_occurrence_delete,
        )

        def _delete_occurrence_edit_series_cleanup() -> str:
            remaining = event_holder["occurrence_edit_remaining"]
            series_id = remaining[0].get("seriesId") or remaining[0]["id"]

            self.client.delete(f"/client/v1/events/{self.encoded(series_id)}")
            return series_id

        self.run_step(
            "recurring event occurrence edit cleanup",
            _delete_occurrence_edit_series_cleanup,
        )

        def _edit_recurring_series_via_occurrence_id() -> str:
            event = event_holder["recurring_occurrence"]
            occurrence_id = event["id"]
            start = dt.datetime.combine(self.tomorrow, dt.time(hour=12, minute=0))
            end = start + dt.timedelta(minutes=45)

            data = self.client.patch(
                f"/client/v1/events/{self.encoded(occurrence_id)}",
                {
                    "title": f"RT recurring count event edited {self.run_id}",
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

            expected = f"RT recurring count event edited {self.run_id}"
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

            deleted_title = f"RT recurring count event edited {self.run_id}"
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

        def _create_recurring_chore(label: str, scheduled_at: dt.date) -> dict[str, Any]:
            data = self.client.post(
                "/client/v1/chores",
                {
                    "serviceId": chore_calendar["serviceId"],
                    "calendarId": chore_calendar["id"],
                    "title": f"RT chore {label} {self.run_id}",
                    "scheduledAt": scheduled_at.isoformat(),
                    "description": f"Recurring chore {label} created by local regression script",
                    "recurrence": "FREQ=DAILY",
                    "points": 1,
                },
            )
            chore = data["chore"]
            self.created_chore_ids.append(chore["id"])
            return chore

        def _chore_uid(chore: dict[str, Any]) -> str:
            uid = chore.get("choreUid") or chore.get("parentChoreUid")
            if isinstance(uid, str) and uid.strip():
                return uid

            chore_id = str(chore.get("id", ""))
            if ":" in chore_id:
                return chore_id.split(":", 1)[1]

            raise RuntimeError(f"Unable to determine chore UID for {chore_id}")

        def _list_chores() -> list[dict[str, Any]]:
            data = self.client.get(
                "/client/v1/chores",
                query={
                    "from": self.today.isoformat(),
                    "to": (self.today + dt.timedelta(days=14)).isoformat(),
                },
            )
            return data.get("chores", [])

        def _completion_logs_for(chore: dict[str, Any]) -> list[dict[str, Any]]:
            uid = _chore_uid(chore)
            return [
                item
                for item in _list_chores()
                if item.get("kind") == "completionLog" and item.get("choreUid") == uid
            ]

        def _base_chore_by_id(chore_id: str) -> dict[str, Any] | None:
            for item in _list_chores():
                if item.get("id") == chore_id and item.get("kind") == "baseChore":
                    return item
            return None

        def _create_skip_chore() -> str:
            chore = _create_recurring_chore("skip", self.today)
            chore_holder["skip_chore"] = chore
            return chore["id"]

        self.run_step("recurring chore skip create", _create_skip_chore)

        def _complete_skip_chore() -> str:
            chore_id = chore_holder["skip_chore"]["id"]
            self.client.post(
                f"/client/v1/chores/{self.encoded(chore_id)}/complete",
                {"date": self.today.isoformat()},
            )
            return "completed before skip"

        self.run_step("recurring chore skip completion", _complete_skip_chore)

        def _skip_recurring_chore() -> str:
            chore_id = chore_holder["skip_chore"]["id"]
            _, payload = self.client.delete(
                f"/client/v1/chores/{self.encoded(chore_id)}",
                query={
                    "action": "skip",
                    "date": self.today.isoformat(),
                },
            )
            data = payload.get("data", payload)
            next_scheduled = data.get("nextScheduledAt")
            if next_scheduled != self.tomorrow.isoformat():
                raise RuntimeError(
                    f"Expected nextScheduledAt={self.tomorrow.isoformat()}, got {next_scheduled}"
                )
            return f"nextScheduledAt={next_scheduled}"

        self.run_step("recurring chore skip this time", _skip_recurring_chore)

        def _read_skip_chore() -> str:
            chore = chore_holder["skip_chore"]
            base = _base_chore_by_id(chore["id"])
            if base is None:
                raise RuntimeError("Skipped recurring chore base item disappeared")

            if base.get("scheduledDate") != self.tomorrow.isoformat():
                raise RuntimeError(
                    f"Expected skipped chore scheduledDate={self.tomorrow.isoformat()}, got {base.get('scheduledDate')}"
                )

            if base.get("recurrence") != "FREQ=DAILY":
                raise RuntimeError(f"Skipped chore recurrence changed unexpectedly: {base.get('recurrence')}")

            logs = _completion_logs_for(chore)
            if not logs:
                raise RuntimeError("Completion history was not preserved after skipping recurring chore")

            return f"scheduledDate={base.get('scheduledDate')}; completion logs={len(logs)}"

        self.run_step("recurring chore skip readback", _read_skip_chore)

        def _create_stop_repeating_chore() -> str:
            chore = _create_recurring_chore("stop repeating", self.today)
            chore_holder["stop_repeating_chore"] = chore
            return chore["id"]

        self.run_step("recurring chore stop repeating create", _create_stop_repeating_chore)

        def _complete_stop_repeating_chore() -> str:
            chore_id = chore_holder["stop_repeating_chore"]["id"]
            self.client.post(
                f"/client/v1/chores/{self.encoded(chore_id)}/complete",
                {"date": self.today.isoformat()},
            )
            return "completed before stop repeating"

        self.run_step("recurring chore stop repeating completion", _complete_stop_repeating_chore)

        def _stop_repeating_chore() -> str:
            chore_id = chore_holder["stop_repeating_chore"]["id"]
            _, payload = self.client.delete(
                f"/client/v1/chores/{self.encoded(chore_id)}",
                query={"action": "stopRepeating"},
            )
            data = payload.get("data", payload)
            if data.get("stoppedRepeating") is not True:
                raise RuntimeError(f"Unexpected stopRepeating response: {data}")
            return chore_id

        self.run_step("recurring chore stop repeating", _stop_repeating_chore)

        def _read_stop_repeating_chore() -> str:
            chore = chore_holder["stop_repeating_chore"]
            base = _base_chore_by_id(chore["id"])
            if base is None:
                raise RuntimeError("Stop-repeating chore base item disappeared")

            if base.get("recurrence") not in (None, ""):
                raise RuntimeError(f"Expected recurrence to be removed, got {base.get('recurrence')}")

            logs = _completion_logs_for(chore)
            if not logs:
                raise RuntimeError("Completion history was not preserved after stopping recurring chore")

            return f"recurrence removed; completion logs={len(logs)}"

        self.run_step("recurring chore stop repeating readback", _read_stop_repeating_chore)

        def _create_permanent_delete_chore() -> str:
            chore = _create_recurring_chore("permanent delete", self.today)
            chore_holder["permanent_delete_chore"] = chore
            return chore["id"]

        self.run_step("recurring chore permanent delete create", _create_permanent_delete_chore)

        def _complete_permanent_delete_chore() -> str:
            chore_id = chore_holder["permanent_delete_chore"]["id"]
            self.client.post(
                f"/client/v1/chores/{self.encoded(chore_id)}/complete",
                {"date": self.today.isoformat()},
            )
            return "completed before permanent delete"

        self.run_step("recurring chore permanent delete completion", _complete_permanent_delete_chore)

        def _delete_permanent_chore() -> str:
            chore_id = chore_holder["permanent_delete_chore"]["id"]
            _, payload = self.client.delete(
                f"/client/v1/chores/{self.encoded(chore_id)}",
                query={"action": "deletePermanent"},
            )
            data = payload.get("data", payload)
            if data.get("deleted") is not True:
                raise RuntimeError(f"Unexpected permanent delete response: {data}")

            self.created_chore_ids.remove(chore_id)
            return f"deletedCompletionLogs={data.get('deletedCompletionLogs')}"

        self.run_step("recurring chore permanent delete", _delete_permanent_chore)

        def _read_permanent_delete_chore() -> str:
            chore = chore_holder["permanent_delete_chore"]
            chore_id = chore["id"]
            uid = _chore_uid(chore)
            items = _list_chores()

            base_matches = [
                item
                for item in items
                if item.get("id") == chore_id and item.get("kind") == "baseChore"
            ]
            log_matches = [
                item
                for item in items
                if item.get("kind") == "completionLog" and item.get("choreUid") == uid
            ]

            if base_matches:
                raise RuntimeError("Permanently deleted recurring chore is still visible")

            if log_matches:
                raise RuntimeError("Completion logs still exist after permanent chore delete")

            return "base chore and completion logs removed"

        self.run_step("recurring chore permanent delete readback", _read_permanent_delete_chore)

        def _delete() -> str:
            chore_id = chore_holder["chore"]["id"]
            self.client.delete(f"/client/v1/chores/{self.encoded(chore_id)}")
            self.created_chore_ids.remove(chore_id)
            return chore_id

        self.run_step("chore delete", _delete)

    def test_household_and_people(self) -> None:
        """
        Regression: login → (possibly no household) → ensure default family →
        bootstrap includes household → create person → list and verify → cleanup.
        """
        # ── 1. Record initial bootstrap household count ────────────────────
        initial_holder: dict[str, Any] = {}

        def _check_initial_bootstrap() -> str:
            bootstrap = self.client.get("/client/v1/bootstrap")
            households = bootstrap.get("contexts", {}).get("households", [])
            initial_holder["count"] = len(households)
            return f"initial households={len(households)}"

        self.run_step("household bootstrap initial", _check_initial_bootstrap)

        # ── 2. Ensure default family (idempotent) ────────────────────────────
        household_holder: dict[str, Any] = {}

        def _ensure_default_family() -> str:
            # Try idempotent endpoint first (mirrors CaleeHubClient behaviour).
            status, payload = self.client.request(
                "POST",
                "/client/v1/households/default",
                {},
                allow_statuses={404, 405},
            )
            if status not in (404, 405):
                data = payload.get("data", payload) if isinstance(payload, dict) else {}
                household = (
                    data.get("household")
                    or data.get("context")
                    or (data if isinstance(data, dict) and data.get("id") else None)
                )
                if isinstance(household, dict) and household.get("id"):
                    household_holder["household"] = household
                    return f"idempotent endpoint ok: id={household['id']}"

            # Fall back to create endpoint.
            data = self.client.post(
                "/client/v1/households",
                {"name": "My Family"},
            )
            household = (
                data.get("household")
                or data.get("context")
                or (data if isinstance(data, dict) and data.get("id") else None)
            )
            if not isinstance(household, dict) or not household.get("id"):
                raise RuntimeError(
                    f"ensureDefaultFamily: unexpected response shape: {data}"
                )
            household_holder["household"] = household
            return f"created via /households: id={household['id']}"

        self.run_step("household ensure default family", _ensure_default_family)

        # ── 3. Verify bootstrap now contains the household ───────────────────
        def _check_bootstrap_has_household() -> str:
            bootstrap = self.client.get("/client/v1/bootstrap")
            households = bootstrap.get("contexts", {}).get("households", [])
            if not households:
                raise RuntimeError(
                    "Bootstrap still has no households after ensureDefaultFamily"
                )
            household_id = household_holder["household"].get("id", "")
            ids = [h.get("id") for h in households]
            if household_id and household_id not in ids:
                raise RuntimeError(
                    f"Expected household {household_id} in bootstrap, got {ids}"
                )
            return f"households={len(households)}, target id present={household_id in ids}"

        self.run_step("household bootstrap after ensure", _check_bootstrap_has_household)

        # ── 4. Create a test person ──────────────────────────────────────────
        person_holder: dict[str, Any] = {}

        def _create_person() -> str:
            household_id = household_holder["household"]["id"]
            data = self.client.post(
                f"/client/v1/households/{self.encoded(household_id)}/people",
                {
                    "displayName": f"RT Person {self.run_id}",
                    "role": "member",
                    "sortOrder": 0,
                },
            )
            person = data.get("person")
            if not isinstance(person, dict) or not person.get("id"):
                raise RuntimeError(f"createPerson: unexpected response: {data}")
            person_holder["person"] = person
            self.created_person_ids.append((household_id, person["id"]))
            return f"id={person['id']}, name={person.get('displayName')}"

        self.run_step("household create person", _create_person)

        # ── 5. List people and verify created person is present ──────────────
        def _list_people() -> str:
            household_id = household_holder["household"]["id"]
            data = self.client.get(
                f"/client/v1/households/{self.encoded(household_id)}/people"
            )
            people = data.get("people", [])
            person_id = person_holder["person"]["id"]
            ids = [p.get("id") for p in people]
            if person_id not in ids:
                raise RuntimeError(
                    f"Created person {person_id} not found in list {ids}"
                )
            return f"found person {person_id} among {len(people)} active people"

        self.run_step("household list people", _list_people)

    def cleanup(self) -> None:
        if self.keep_created:
            self.record("cleanup", "SKIP", "--keep-created enabled")
            return

        # Archive test people (soft delete — keeps data integrity).
        for household_id, person_id in list(self.created_person_ids):
            try:
                self.client.delete(
                    f"/client/v1/households/{self.encoded(household_id)}/people/{self.encoded(person_id)}",
                    allow_statuses={404},
                )
                self.created_person_ids.remove((household_id, person_id))
                self.record("cleanup person", "PASS", person_id)
            except Exception as e:
                self.record("cleanup person", "FAIL", f"{person_id}: {e}")

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

            chore_service = self.pick_chore_service(bootstrap_holder["payload"])
            chore_service_id = chore_service["id"]
            self.record(
                "chore service selected",
                "INFO",
                f"{chore_service_id} ({chore_service.get('displayName', '')})",
            )

            if service_id != chore_service_id:
                def _reject_non_portal_chore_list_create() -> str:
                    status, payload = self.client.request(
                        "POST",
                        "/client/v1/calendars",
                        {
                            "serviceId": service_id,
                            "name": f"RT rejected chore-list {self.run_id}",
                            "primaryKind": "chores",
                            "color": "#3366CC",
                        },
                        allow_statuses={404},
                    )

                    if status != 404:
                        data = payload.get("data", payload) if isinstance(payload, dict) else {}
                        calendar = data.get("calendar", {}) if isinstance(data, dict) else {}
                        calendar_id = calendar.get("id") if isinstance(calendar, dict) else None

                        if isinstance(calendar_id, str) and calendar_id:
                            try:
                                self.delete_collection(calendar_id)
                            except Exception:
                                pass

                        raise RuntimeError(
                            f"Expected HTTP 404 for non-portal chore-list create, got {status}"
                        )

                    return f"rejected serviceId={service_id}"

                self.run_step(
                    "chore-list create rejected for non-portal service",
                    _reject_non_portal_chore_list_create,
                )

            calendar_collection, task_collection, chore_collection = self.test_collections(
                service_id,
                chore_service_id=chore_service_id,
            )

            if service_id != chore_service_id:
                def _reject_non_portal_chore_create() -> str:
                    status, _ = self.client.request(
                        "POST",
                        "/client/v1/chores",
                        {
                            "serviceId": service_id,
                            "calendarId": calendar_collection["id"],
                            "title": f"RT rejected non-portal chore {self.run_id}",
                            "scheduledAt": self.today.isoformat(),
                            "points": 1,
                        },
                        allow_statuses={404},
                    )

                    if status != 404:
                        raise RuntimeError(f"Expected HTTP 404 for non-portal chore create, got {status}")

                    return f"rejected serviceId={service_id}"

                self.run_step(
                    "chore create rejected for non-portal service",
                    _reject_non_portal_chore_create,
                )

            self.test_event_create_and_read(calendar_collection)
            self.test_tasks(task_collection)
            self.test_chores(chore_collection)
            self.test_household_and_people()

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

import copy
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


SCRIPT = Path(__file__).resolve().parents[1] / "skills/launch/scripts/spice-launch.sh"


class CommandResult(Exception):
    def __init__(self, data, ok):
        self.data = data
        self.ok = ok


class LaunchMonitorTests(unittest.TestCase):
    def setUp(self):
        source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        source = source.rsplit("\nmain()", 1)[0]
        self.ns = {"__name__": "launch_test"}
        exec(compile(source, str(SCRIPT), "exec"), self.ns)
        self.ctx = SimpleNamespace(
            dir=Path("/unused"), ref="acme/orders", state={},
            project_id=lambda: 123, save=Mock(),
        )
        self.monitors = {}
        self.calls = []
        self.unavailable = False
        self.readback_error = None
        self.delete_code = 200
        self.drill_resolves = True
        self.args = SimpleNamespace(
            dir="/unused", profile="demo", email=None, slack=None, webhook=None,
            webhook_token_env=None, webhook_no_token=False, latency_ms=None,
            query_failure_rate=0.05, dry_run=False, enable_disabled=False, timeout=5,
        )
        self.ns.update(
            Ctx=lambda a: self.ctx, api=self.api, status=lambda msg: None,
            emit=self.emit, get_project=lambda ctx, pid: {"config": {"spicepod": {}}},
            data_plane=lambda ctx: ("https://example.com", "key", None),
            sql=Mock(), local_env=lambda directory: {"HOOK_TOKEN": "private-token"},
            now=lambda: "2026-10-07T12:00:00Z",
            MONITORS=[self.ns["MONITORS"][0]],
        )

    def emit(self, data, ok=True):
        raise CommandResult(data, ok)

    def api(self, ctx, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == "GET" and path.endswith("/monitors"):
            return 200, {"monitors": list(copy.deepcopy(self.monitors).values())}
        alert_id = path.rsplit("/", 1)[-1]
        if method == "POST":
            if self.unavailable:
                return 404, {"code": "monitor_template_unavailable"}
            alert_id = "new-id"
            monitor = {
                **copy.deepcopy(body), "id": alert_id, "status": "active",
                "template_id": body["templateId"],
            }
            self.monitors[alert_id] = monitor
            return 201, copy.deepcopy(monitor)
        if method == "PATCH":
            self.monitors[alert_id].update(copy.deepcopy(body))
            return 200, copy.deepcopy(self.monitors[alert_id])
        if method == "DELETE":
            if self.delete_code == 200:
                del self.monitors[alert_id]
            return self.delete_code, {"ok": self.delete_code == 200}
        if method == "GET":
            monitor = copy.deepcopy(self.monitors[alert_id])
            if self.readback_error:
                monitor.update(self.readback_error)
            if monitor["name"] == "launch: fire drill":
                monitor["last_fired_at"] = "2026-10-06T12:00:00Z"
                if self.drill_resolves:
                    monitor["last_resolved_at"] = "2026-10-06T12:01:00Z"
            return 200, monitor
        self.fail(f"Unexpected API call: {method} {path}")

    def existing(self, status="active", spec=None, targets=None):
        monitor = {
            "id": "existing-id", "name": "launch: query failures",
            "template_id": "query_failures", "status": status,
            "spec": spec or {"op": "GT", "threshold": 0.05, "window": "5m",
                             "sustainSecs": 300, "severity": "warn"},
            "targets": targets or [{"type": "email", "emails": ["oncall@example.com"]}],
            "description": "User-edited description",
        }
        self.monitors[monitor["id"]] = monitor
        return monitor

    def run_command(self, name="cmd_monitors"):
        with self.assertRaises(CommandResult) as caught:
            self.ns[name](self.args)
        return caught.exception

    def test_create_requires_readback(self):
        self.args.email = ["oncall@example.com"]
        result = self.run_command()
        self.assertTrue(result.ok)
        self.assertEqual(result.data["status"], "monitored")
        self.assertIn(("GET", "/v1/projects/123/monitors/new-id", None), self.calls)

    def test_existing_condition_updates_same_id_and_preserves_description(self):
        self.existing()
        self.args.query_failure_rate = 0.1
        result = self.run_command()
        self.assertTrue(result.ok)
        self.assertEqual(result.data["monitors"][0]["id"], "existing-id")
        self.assertEqual(self.monitors["existing-id"]["description"], "User-edited description")
        self.assertNotIn("POST", [call[0] for call in self.calls])
        self.assertNotIn("DELETE", [call[0] for call in self.calls])

    def test_disabled_monitor_is_not_silently_enabled(self):
        self.existing(status="disabled")
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertEqual(result.data["monitors"][0]["status"], "disabled")
        self.assertNotIn("PATCH", [call[0] for call in self.calls])

    def test_explicit_enable_updates_existing_id(self):
        self.existing(status="disabled")
        self.args.enable_disabled = True
        result = self.run_command()
        self.assertTrue(result.ok)
        self.assertEqual(self.monitors["existing-id"]["status"], "active")

    def test_unchanged_monitor_is_read_back(self):
        self.existing()
        self.readback_error = {"evaluation_unavailable_reason": "cpu_limit_missing"}
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertEqual(result.data["monitors"][0]["status"], "verification_failed")

    def test_template_mismatch_does_not_change_signal(self):
        self.existing()["template_id"] = "http_5xx"
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertNotIn("PATCH", [call[0] for call in self.calls])

    def test_mismatched_destinations_fail_verification(self):
        self.args.email = ["oncall@example.com"]
        self.readback_error = {"targets": [{"type": "email", "emails": ["wrong@example.com"]}]}
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertIn("recipients do not match", result.data["monitors"][0]["error"])

    def test_mismatched_spec_fails_verification(self):
        self.readback_error = {"spec": {"threshold": 999}}
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertIn("condition does not match", result.data["monitors"][0]["error"])

    def test_condition_only_update_verifies_preserved_destinations(self):
        self.existing()
        self.args.query_failure_rate = 0.1
        self.readback_error = {"targets": [{"type": "email", "emails": ["wrong@example.com"]}]}
        self.assertFalse(self.run_command().ok)

    def test_explicit_emails_clear_and_verify_member_recipients(self):
        self.existing(targets=[{"type": "email", "recipientUserIds": [99]}])
        self.args.email = ["oncall@example.com"]
        self.readback_error = {"targets": [{"type": "email", "emails": self.args.email, "recipientUserIds": [99]}]}
        result = self.run_command()
        self.assertFalse(result.ok)
        patch_body = next(call[2] for call in self.calls if call[0] == "PATCH")
        self.assertEqual(patch_body["targets"][0]["recipientUserIds"], [])

    def test_failed_patch_does_not_recreate_alert(self):
        self.existing()
        self.args.query_failure_rate = 0.1
        api = self.api

        def failed_patch(ctx, method, path, body=None):
            if method == "PATCH":
                self.calls.append((method, path, copy.deepcopy(body)))
                return 502, {"error": "Backend update failed"}
            return api(ctx, method, path, body)

        self.ns["api"] = failed_patch
        result = self.run_command()
        self.assertFalse(result.ok)
        self.assertEqual(result.data["monitors"][0]["id"], "existing-id")
        self.assertNotIn("POST", [call[0] for call in self.calls])
        self.assertNotIn("DELETE", [call[0] for call in self.calls])

    def test_all_unavailable_cannot_report_monitored(self):
        self.unavailable = True
        self.assertFalse(self.run_command().ok)

    def test_partial_coverage_is_explicit(self):
        self.ns["MONITORS"].append(("HTTP 5xx", "http_5xx", {"op": "GT", "threshold": 0},
                                    {"demo": "warn"}, "meaning", "response", None))
        api = self.api

        def partly_available(ctx, method, path, body=None):
            if method == "POST" and body["templateId"] == "http_5xx":
                return 404, {"code": "monitor_template_unavailable"}
            return api(ctx, method, path, body)

        self.ns["api"] = partly_available
        result = self.run_command()
        self.assertTrue(result.ok)
        self.assertEqual(result.data["status"], "monitoring_incomplete")

    def test_profile_change_reports_but_does_not_delete_old_monitor(self):
        self.existing()
        self.monitors["old-id"] = {"id": "old-id", "name": "launch: CPU", "status": "active"}
        result = self.run_command()
        self.assertEqual(result.data["outside_profile"][0]["id"], "old-id")
        self.assertNotIn("DELETE", [call[0] for call in self.calls])

    def test_dry_run_reports_planned_without_mutations(self):
        self.args.dry_run = True
        result = self.run_command()
        self.assertEqual(result.data["status"], "planned")
        self.assertEqual([call[0] for call in self.calls], ["GET"])
        self.ctx.save.assert_not_called()

    def test_drill_requires_enabled_base_monitor(self):
        self.existing(status="disabled")
        self.assertFalse(self.run_command("cmd_fire_drill").ok)
        self.assertNotIn("POST", [call[0] for call in self.calls])

    def test_drill_stops_before_mutation_without_webhook_credentials(self):
        self.existing(targets=[{"type": "http", "url": "https://example.com/alerts"}])
        self.assertFalse(self.run_command("cmd_fire_drill").ok)
        self.assertNotIn("POST", [call[0] for call in self.calls])

    def test_drill_copies_webhook_token_without_printing_it(self):
        self.existing(targets=[{"type": "http", "url": "https://example.com/alerts"}])
        self.args.webhook_token_env = "HOOK_TOKEN"
        result = self.run_command("cmd_fire_drill")
        self.assertTrue(result.ok)
        body = next(call[2] for call in self.calls if call[0] == "POST")
        self.assertEqual(body["targets"][0]["token"], "private-token")
        self.assertNotIn("private-token", str(result.data))
        self.assertEqual(result.data["status"], "alert_fired")
        self.assertFalse(result.data["delivery_confirmed"])
        self.assertEqual(result.data["notification_targets"], ["http"])

    def test_drill_can_copy_explicit_unauthenticated_webhook(self):
        self.existing(targets=[{"type": "http", "url": "https://example.com/alerts"}])
        self.args.webhook_no_token = True
        self.assertTrue(self.run_command("cmd_fire_drill").ok)

    def test_drill_supports_legacy_singular_target(self):
        monitor = self.existing()
        monitor["target"] = monitor.pop("targets")[0]
        result = self.run_command("cmd_fire_drill")
        self.assertEqual(result.data["notification_targets"], ["email"])

    def test_drill_cleanup_failure_blocks_success(self):
        self.existing()
        self.delete_code = 502
        result = self.run_command("cmd_fire_drill")
        self.assertFalse(result.ok)
        self.assertEqual(result.data["id"], "new-id")
        self.assertFalse(result.data["drill_monitor_deleted"])

    def test_drill_timeout_still_deletes_temporary_alert(self):
        self.existing()
        self.args.timeout = 0
        result = self.run_command("cmd_fire_drill")
        self.assertFalse(result.ok)
        self.assertTrue(result.data["drill_monitor_deleted"])
        self.assertNotIn("new-id", self.monitors)

    def test_drill_waits_for_recovery_without_more_failing_queries(self):
        self.existing()
        self.drill_resolves = False
        reads = 0
        api = self.api

        def delayed_recovery(ctx, method, path, body=None):
            nonlocal reads
            code, response = api(ctx, method, path, body)
            if method == "GET" and path.endswith("/new-id"):
                reads += 1
                if reads == 2:
                    response["last_resolved_at"] = "2026-10-06T12:01:00Z"
            return code, response

        self.ns["api"] = delayed_recovery
        self.ns["time"] = SimpleNamespace(time=lambda: 0, sleep=lambda seconds: None)
        result = self.run_command("cmd_fire_drill")
        self.assertTrue(result.ok)
        self.assertTrue(result.data["resolved"])
        self.ns["sql"].assert_called_once()

    def test_unresolved_drill_reports_downstream_cleanup(self):
        self.existing()
        self.drill_resolves = False
        clock = iter([0, 0, 0, 6, 6])
        self.ns["time"] = SimpleNamespace(time=lambda: next(clock), sleep=lambda seconds: None)
        result = self.run_command("cmd_fire_drill")
        self.assertFalse(result.ok)
        self.assertTrue(result.data["drill_monitor_deleted"])
        self.assertIn("manual closure", result.data["error"])

    def test_memory_fallback_uses_saved_targets_and_resolves_before_delete(self):
        monitor = self.existing()
        monitor["name"] = "launch: memory"
        monitor["template_id"] = "memory_working_set"
        api = self.api

        def memory_only(ctx, method, path, body=None):
            if method == "POST" and body["templateId"] == "query_failures":
                return 404, {"code": "monitor_template_unavailable"}
            return api(ctx, method, path, body)

        self.ns["api"] = memory_only
        self.ns["time"] = SimpleNamespace(time=lambda: 0, sleep=lambda seconds: None)
        result = self.run_command("cmd_fire_drill")
        self.assertTrue(result.ok)
        self.assertEqual(result.data["template"], "memory_working_set")
        self.assertTrue(result.data["resolved"])
        self.assertTrue(result.data["drill_monitor_deleted"])
        self.ns["sql"].assert_not_called()
        post = next(call[2] for call in self.calls if call[0] == "POST")
        self.assertEqual(post["targets"], monitor["targets"])
        patch_body = next(call[2] for call in self.calls if call[0] == "PATCH")
        self.assertEqual(patch_body["spec"]["threshold"], 1000)
        self.assertIn("existing-id", self.monitors)

    def test_memory_recovery_update_failure_still_cleans_up(self):
        self.existing()
        api = self.api

        def failed_recovery(ctx, method, path, body=None):
            if method == "POST" and body["templateId"] == "query_failures":
                return 404, {"code": "monitor_template_unavailable"}
            if method == "PATCH":
                return 403, {"error": "Org admin required"}
            return api(ctx, method, path, body)

        self.ns["api"] = failed_recovery
        result = self.run_command("cmd_fire_drill")
        self.assertFalse(result.ok)
        self.assertTrue(result.data["drill_monitor_deleted"])
        self.assertIn("temporary memory condition", result.data["error"])


if __name__ == "__main__":
    unittest.main()

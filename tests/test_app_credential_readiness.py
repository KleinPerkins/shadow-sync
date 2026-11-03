import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch
import urllib.error

SOURCE = Path(__file__).resolve().parents[1] / "scripts/app-credential-readiness.py"
SPEC = importlib.util.spec_from_file_location("app_readiness", SOURCE)
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


def environment():
    return {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": app.REPOSITORY, "GITHUB_REPOSITORY_ID": str(app.REPOSITORY_ID),
            "GITHUB_REF": "refs/heads/main", "TRUSTED_WORKFLOW_SHA": "a" * 40,
            "GITHUB_SHA": "a" * 40, "APP_SLUG": "fixture-reviewer"}


def responses():
    repo = {"id": app.REPOSITORY_ID, "full_name": app.REPOSITORY, "private": False,
            "default_branch": "main", "archived": False, "disabled": False}
    return {"/installation/repositories?per_page=100": {"total_count": 1, "repositories": [repo]},
            "/repos/" + app.REPOSITORY: copy.deepcopy(repo),
            "/users/fixture-reviewer%5Bbot%5D": {"id": app.REVIEWER_BOT_ID,
                "login": "fixture-reviewer[bot]", "type": "Bot"}}


class Client:
    def __init__(self):
        self.values = responses()
        self.calls = []

    def get(self, path):
        self.calls.append(path)
        return self.values[path]


class Response:
    status = 200

    def __init__(self, data=b"{}", url="https://api.github.com/repos/" + app.REPOSITORY):
        self.data, self.url = data, url

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, limit):
        return self.data[:limit]

    def geturl(self):
        return self.url


class Opener:
    def __init__(self, response=None, error=None):
        self.response, self.error, self.requests = response or Response(), error, []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if self.error:
            raise self.error
        return self.response


class AppReadinessTests(unittest.TestCase):
    def setUp(self):
        self.argv = patch.object(sys, "argv", ["app-credential-readiness.py"])
        self.argv.start()
        self.addCleanup(self.argv.stop)

    def test_success_requires_three_gets_and_does_not_qualify_delivery(self):
        client = Client()
        receipt = app.qualify(environment(), client)
        self.assertEqual(client.calls, list(responses()))
        self.assertTrue(receipt["approved_reviewer_identity"])
        self.assertTrue(receipt["single_repository_scope"])
        self.assertFalse(receipt["diagnostic_pr_mutations"])
        self.assertFalse(receipt["ordinary_pr_delivery_qualified"])
        self.assertTrue(receipt["requires_separate_verified_revocation_receipt"])

    def test_cleanup_deletes_only_token_and_requires_subsequent_unauthorized(self):
        deleted = Response(url="https://api.github.com/installation/token"); deleted.status = 204
        url = "https://api.github.com/installation/repositories?per_page=100"
        opener = Opener()
        with patch.object(opener, "open", side_effect=[deleted, urllib.error.HTTPError(url, 401, "unauthorized", {}, None)]) as opened:
            app.GitHubReadClient("fixture-opaque", opener).revoke_and_confirm()
        self.assertEqual([(call.args[0].get_method(), call.args[0].full_url) for call in opened.call_args_list],
                         [("DELETE", "https://api.github.com/installation/token"), ("GET", url)])

    def test_failed_revoke_or_still_usable_token_refuses(self):
        for first_status, second_status in [(403, 401), (204, 200), (204, 403), (200, 401)]:
            deleted = Response(url="https://api.github.com/installation/token"); deleted.status = first_status
            denied = Response(url="https://api.github.com/installation/repositories?per_page=100"); denied.status = second_status
            opener = Opener()
            with patch.object(opener, "open", side_effect=[deleted, denied]), self.assertRaises(app.Refusal):
                app.GitHubReadClient("fixture-opaque", opener).revoke_and_confirm()

    def test_cleanup_transport_errors_and_redirects_refuse_without_secret(self):
        for opener in [Opener(error=urllib.error.URLError("fixture-secret")), Opener(Response(url="https://example.invalid"))]:
            with self.assertRaises(app.Refusal) as error:
                app.GitHubReadClient("fixture-secret", opener).revoke_and_confirm()
            self.assertNotIn("fixture-secret", str(error.exception))

    def test_cleanup_writes_distinct_receipt_only_after_verified_revocation(self):
        env = environment(); env["APP_TOKEN"] = "fixture-secret"
        with tempfile.TemporaryDirectory() as directory:
            prior = os.getcwd()
            try:
                os.chdir(directory)
                with patch.dict(os.environ, env, clear=True), patch.object(sys, "argv", ["checker", "--revoke"]), patch.object(app, "GitHubReadClient") as factory, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(app.main(), 0)
                    factory.return_value.revoke_and_confirm.assert_called_once_with()
                receipt = json.loads(Path("outputs/reviewer-app-revocation.json").read_text())
                self.assertTrue(receipt["token_revoked"])
                self.assertTrue(receipt["subsequent_request_rejected"])
                self.assertFalse(Path("outputs/reviewer-app-readiness.json").exists())
            finally:
                os.chdir(prior)

    def test_untrusted_context_refuses_before_network(self):
        for key, value in [("GITHUB_ACTIONS", "false"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_EVENT_NAME", "workflow_run"),
                           ("GITHUB_REPOSITORY", "fixture-owner/fork"), ("GITHUB_REPOSITORY_ID", "1"),
                           ("GITHUB_REF", "refs/heads/feature"), ("GITHUB_REF", "refs/tags/main")]:
            with self.subTest(key=key, value=value):
                env = environment(); env[key] = value; client = Client()
                with self.assertRaises(app.Refusal):
                    app.qualify(env, client)
                self.assertEqual(client.calls, [])

    def test_workflow_revision_is_exact_and_nonzero(self):
        for value in ["b" * 40, "0" * 40, "a" * 39, "A" * 40, "main"]:
            env = environment(); env["TRUSTED_WORKFLOW_SHA"] = value
            with self.assertRaises(app.Refusal):
                app.qualify(env, Client())

    def test_app_slug_cannot_change_api_host_or_path(self):
        for slug in ["", "../other", "fixture/other", "fixture?x=1", "fixture\nother", "X", "x" * 101]:
            env = environment(); env["APP_SLUG"] = slug; client = Client()
            with self.assertRaises(app.Refusal):
                app.qualify(env, client)
            self.assertEqual(client.calls, [])

    def test_token_cannot_cover_other_or_multiple_repositories(self):
        for total, repos in [(0, []), (2, [responses()["/repos/" + app.REPOSITORY]] * 2),
                             (True, [responses()["/repos/" + app.REPOSITORY]]), (1, []),
                             (1, [{"id": 1, "full_name": "fixture-owner/other", "private": False}])]:
            client = Client()
            client.values["/installation/repositories?per_page=100"] = {"total_count": total, "repositories": repos}
            with self.assertRaisesRegex(app.Refusal, "repository-token-scope-mismatch"):
                app.qualify(environment(), client)
            self.assertEqual(len(client.calls), 1)

    def test_wrong_repository_identity_or_state_refuses(self):
        for key, value in [("id", 1), ("id", True), ("full_name", "fixture-owner/other"),
                           ("private", True), ("default_branch", "other"), ("archived", True),
                           ("disabled", True), ("disabled", None)]:
            client = Client(); client.values["/repos/" + app.REPOSITORY][key] = value
            with self.assertRaisesRegex(app.Refusal, "repository-identity-mismatch"):
                app.qualify(environment(), client)

    def test_wrong_bot_type_id_or_login_refuses(self):
        for key, value in [("id", 1), ("id", True), ("login", "fixture-other[bot]"), ("type", "User")]:
            client = Client(); client.values["/users/fixture-reviewer%5Bbot%5D"][key] = value
            with self.assertRaisesRegex(app.Refusal, "reviewer-identity-mismatch"):
                app.qualify(environment(), client)

    def test_api_json_is_bounded_unambiguous_and_finite(self):
        for raw in [b"", b'{"id":1,"id":2}', b'{"x":NaN}', b'{"x":Infinity}', b"\xff", b"{}{}", b" " * (app.MAX_RESPONSE + 1)]:
            with self.assertRaises(app.Refusal):
                app.decode(raw)

    def test_token_is_opaque_and_not_assumed_forty_characters(self):
        token = "fixture-opaque." + "x" * 256
        opener = Opener()
        app.GitHubReadClient(token, opener).get("/repos/" + app.REPOSITORY)
        request, timeout = opener.requests[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.full_url, "https://api.github.com/repos/" + app.REPOSITORY)
        self.assertEqual(request.get_header("Authorization"), "Bearer " + token)
        self.assertEqual(timeout, 20)

    def test_missing_or_header_injection_token_refuses(self):
        for token in ["", "has space", "a\rb", "a\nb", "x" * 8193]:
            with self.assertRaises(app.Refusal):
                app.GitHubReadClient(token, Opener())

    def test_only_closed_read_endpoints_are_reachable(self):
        opener = Opener(); client = app.GitHubReadClient("fixture-opaque", opener)
        for path in ["https://example.invalid", "//example.invalid", "/repos/fixture-owner/other", "/app/installations", "/repos/" + app.REPOSITORY + "/pulls/1/merge"]:
            with self.assertRaises(app.Refusal):
                client.get(path)
        self.assertEqual(opener.requests, [])

    def test_redirects_are_refused(self):
        with self.assertRaises(app.Refusal):
            app.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://example.invalid")
        with self.assertRaises(app.Refusal):
            app.GitHubReadClient("fixture-opaque", Opener(Response(url="https://example.invalid"))).get("/repos/" + app.REPOSITORY)

    def test_environment_proxy_is_disabled(self):
        with patch.object(app.urllib.request, "build_opener", return_value=Opener()) as factory:
            app.GitHubReadClient("fixture-opaque")
        handlers = factory.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], app.NoRedirect)

    def test_transport_failure_does_not_include_response_or_token(self):
        token = "fixture-confidential-sentinel"
        error = urllib.error.URLError(token)
        with self.assertRaises(app.Refusal) as raised:
            app.GitHubReadClient(token, Opener(error=error)).get("/repos/" + app.REPOSITORY)
        self.assertEqual(str(raised.exception), "api-request-failed")
        self.assertNotIn(token, str(raised.exception))

    def test_non_success_response_refuses(self):
        response = Response(); response.status = 403
        with self.assertRaises(app.Refusal):
            app.GitHubReadClient("fixture-opaque", Opener(response)).get("/repos/" + app.REPOSITORY)

    def test_receipt_and_stdout_have_no_credentials_or_api_payload(self):
        env = environment(); env["APP_TOKEN"] = "fixture-confidential-sentinel"
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            prior = os.getcwd()
            try:
                os.chdir(directory)
                with patch.dict(os.environ, env, clear=True), patch.object(app, "GitHubReadClient", return_value=Client()), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(app.main(), 0)
                raw = Path("outputs/reviewer-app-readiness.json").read_text()
                self.assertNotIn(env["APP_TOKEN"], raw + out.getvalue() + err.getvalue())
                self.assertNotIn("fixture-reviewer", raw)
                self.assertEqual(Path("outputs/reviewer-app-readiness.json").stat().st_mode & 0o777, 0o600)
            finally:
                os.chdir(prior)

    def test_main_context_refusal_mints_no_client_and_writes_no_receipt(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(app, "GitHubReadClient") as factory, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(app.main(), 1)
        factory.assert_not_called()

    def test_unexpected_failure_is_redacted(self):
        env = environment(); env["APP_TOKEN"] = "fixture-secret-value"
        err = io.StringIO()
        with patch.dict(os.environ, env, clear=True), patch.object(app, "GitHubReadClient", side_effect=RuntimeError(env["APP_TOKEN"])), contextlib.redirect_stderr(err):
            self.assertEqual(app.main(), 1)
        self.assertNotIn(env["APP_TOKEN"], err.getvalue())
        self.assertIn("diagnostic-failed", err.getvalue())


if __name__ == "__main__":
    unittest.main()

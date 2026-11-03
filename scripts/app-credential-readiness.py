#!/usr/bin/env python3
"""Read-only qualification of the configured reviewer App on trusted main.

Token issuance requests the approved Contents/PR write scopes, but this checker
only reads identity and repository access. An ordinary exact-head PR canary must
separately prove approval/merge behavior. Cleanup explicitly revokes this token
and confirms a subsequent authenticated request is rejected. The action's
best-effort post step alone is not revocation evidence.
"""
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "KleinPerkins/shadow-sync"
REPOSITORY_ID = 1442961455
# Identity observed on Sterling's approved exact-head reviewer path. This is a
# public bot user ID, not a key or installation ID. A different App needs review.
REVIEWER_BOT_ID = 299927791
MAX_RESPONSE = 1_048_576


class Refusal(Exception):
    """Messages are fixed stage names, never HTTP bodies or credential values."""


def require(condition, stage):
    if not condition:
        raise Refusal(stage)


def closed_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "ambiguous-api-response")
        result[key] = value
    return result


def decode(data):
    require(0 < len(data) <= MAX_RESPONSE, "api-response-size")
    try:
        return json.loads(data, object_pairs_hook=closed_pairs,
                          parse_constant=lambda _: require(False, "invalid-api-json"))
    except (ValueError, UnicodeError, RecursionError):
        raise Refusal("invalid-api-json") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refusal("api-redirect-refused")


class GitHubReadClient:
    def __init__(self, token, opener=None):
        require(isinstance(token, str) and 0 < len(token) <= 8192
                and all(33 <= ord(c) <= 126 for c in token), "app-token-unavailable")
        self.token = token
        self.opener = opener or urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect())

    def get(self, path):
        require(path in {"/installation/repositories?per_page=100", "/repos/" + REPOSITORY}
                or re.fullmatch(r"/users/[a-z0-9-]{1,100}%5Bbot%5D", path), "api-path-refused")
        request = urllib.request.Request("https://api.github.com" + path, method="GET", headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "shadow-sync-app-readiness",
        })
        try:
            with self.opener.open(request, timeout=20) as response:
                require(response.status == 200, "api-request-failed")
                # Even a supplied opener may not silently redirect credentials.
                require(response.geturl() == request.full_url, "api-redirect-refused")
                return decode(response.read(MAX_RESPONSE + 1))
        except Refusal:
            raise
        except (OSError, urllib.error.URLError):
            raise Refusal("api-request-failed") from None

    def revoke_and_confirm(self):
        # The only write is deletion of this token, never a repository/PR write.
        for method, path, expected in (("DELETE", "/installation/token", 204),
                                       ("GET", "/installation/repositories?per_page=100", 401)):
            request = urllib.request.Request("https://api.github.com" + path, method=method, headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2026-03-10",
                "User-Agent": "shadow-sync-app-readiness",
            })
            try:
                try:
                    response = self.opener.open(request, timeout=20)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    require(response.geturl() == request.full_url, "api-redirect-refused")
                    require(response.status == expected, "token-revocation-unproven")
            except Refusal:
                raise
            except (OSError, urllib.error.URLError):
                raise Refusal("token-revocation-unproven") from None


def context(environment):
    require(environment.get("GITHUB_ACTIONS") == "true"
            and environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and environment.get("GITHUB_REPOSITORY") == REPOSITORY
            and environment.get("GITHUB_REPOSITORY_ID") == str(REPOSITORY_ID)
            and environment.get("GITHUB_REF") == "refs/heads/main", "untrusted-workflow-context")
    sha = environment.get("TRUSTED_WORKFLOW_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha) and sha != "0" * 40
            and environment.get("GITHUB_SHA") == sha, "workflow-revision-mismatch")
    slug = environment.get("APP_SLUG", "")
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,99}", slug), "invalid-app-identity")
    return sha, slug + "[bot]"


def repository_matches(repository):
    return (isinstance(repository, dict)
            and type(repository.get("id")) is int and repository["id"] == REPOSITORY_ID
            and repository.get("full_name") == REPOSITORY
            and repository.get("private") is False)


def qualify(environment, client):
    sha, login = context(environment)
    installation = client.get("/installation/repositories?per_page=100")
    require(isinstance(installation, dict) and type(installation.get("total_count")) is int
            and installation["total_count"] == 1
            and isinstance(installation.get("repositories"), list)
            and len(installation["repositories"]) == 1
            and repository_matches(installation["repositories"][0]), "repository-token-scope-mismatch")
    repo = client.get("/repos/" + REPOSITORY)
    require(repository_matches(repo) and repo.get("default_branch") == "main"
            and repo.get("archived") is False and repo.get("disabled") is False,
            "repository-identity-mismatch")
    bot = client.get("/users/" + urllib.parse.quote(login, safe=""))
    require(isinstance(bot, dict) and type(bot.get("id")) is int
            and bot["id"] == REVIEWER_BOT_ID and bot.get("login") == login
            and bot.get("type") == "Bot", "reviewer-identity-mismatch")
    return {"schema": "shadow-sync-reviewer-app-readiness/v1", "revision": sha,
            "trusted_main": True, "single_repository_scope": True,
            "repository_access": True, "approved_reviewer_identity": True,
            "diagnostic_pr_mutations": False,
            "ordinary_pr_delivery_qualified": False,
            "requires_separate_verified_revocation_receipt": True}


def main():
    try:
        sha, _ = context(os.environ)  # Refuse before reading a token or contacting GitHub.
        require(sys.argv[1:] in ([], ["--revoke"]), "invalid-mode")
        client = GitHubReadClient(os.environ.get("APP_TOKEN", ""))
        if sys.argv[1:] == ["--revoke"]:
            client.revoke_and_confirm()
            receipt = {"schema": "shadow-sync-reviewer-app-revocation/v1", "revision": sha,
                       "token_revoked": True, "subsequent_request_rejected": True}
            filename = "reviewer-app-revocation.json"
        else:
            receipt = qualify(os.environ, client)
            filename = "reviewer-app-readiness.json"
        if Path("outputs").exists():
            require(Path("outputs").is_dir() and not Path("outputs").is_symlink(), "invalid-output-directory")
        else:
            os.mkdir("outputs", 0o700)
        descriptor = os.open("outputs/" + filename,
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(receipt, stream, sort_keys=True)
            stream.write("\n")
        print("Reviewer App readiness stage completed; no PR changes made.")
        return 0
    except Refusal as error:
        print("Reviewer App readiness refused: " + str(error), file=sys.stderr)
    except Exception:
        print("Reviewer App readiness refused: diagnostic-failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

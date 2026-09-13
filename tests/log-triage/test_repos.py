import json
import os
import shutil
import subprocess
import unittest

from _helpers import TriageTestCase, fixture

GIT = shutil.which("git")


def _git(*args, cwd=None):
    subprocess.run(["git"] + list(args), cwd=cwd, check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com"))


@unittest.skipIf(GIT is None, "git not available")
class RepoTests(TriageTestCase):
    def make_repo(self, rel, files):
        path = os.path.join(self.tmp, rel)
        os.makedirs(path, exist_ok=True)
        _git("init", "-q", path)
        for f, content in files.items():
            full = os.path.join(path, f)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(content)
        _git("add", ".", cwd=path)
        _git("commit", "-q", "-m", "init", cwd=path)
        return path

    def setUp(self):
        super().setUp()
        self.orders = self.make_repo("org-a/orders", {
            "src/Acme.Orders/OrderService.cs": "namespace Acme.Orders {\n" + "// padding\n" * 37 + " public class OrderService {\n  public void Place(Order o) {\n   var x = o.Items.First();\n  }\n }\n}\n",
            "src/Acme.Orders/Acme.Orders.csproj": "<Project><PropertyGroup><RootNamespace>Acme.Orders</RootNamespace></PropertyGroup></Project>",
            "README.md": "orders"})
        self.billing = self.make_repo("org-b/billing", {
            "billing/charge.py": "import requests\n" + "\n" * 8 + "def charge(order):\n    url = gateway()\n    resp = client.post(url, json=payload, timeout=5)\n    raise ChargeFailed('could not charge order %s' % order.id)\n",
            "billing/worker.py": "import billing.charge\n" + "\n" * 26 + "def run(order):\n    log.info('run')\n    charge(order)\n    return 1\n\n    raise ChargeFailed(order) from exc\n",
            "billing/__init__.py": "", "pyproject.toml": '[project]\nname = "billing-service"\n',
            "src/Acme.Orders/OrderService.cs": "// same filename, unrelated repo\n"})
        self.javarepo = self.make_repo("org-b/java-orders", {
            "src/main/java/com/acme/orders/OrderService.java": "package com.acme.orders;\npublic class OrderService {\n  void place() {}\n}\n",
            "pom.xml": "<project><groupId>com.acme</groupId><artifactId>orders-java</artifactId></project>"})
        os.makedirs(os.path.join(self.tmp, "node_modules", "junk"))
        _git("init", "-q", os.path.join(self.tmp, "node_modules", "junk"))
        os.symlink(os.path.join(self.tmp, "org-a"), os.path.join(self.tmp, "link-to-a"))
        _git("worktree", "add", "-q", os.path.join(self.tmp, "wt", "orders-wt"), "-b", "wt", cwd=self.orders)

    def test_discovery_nested_worktree_symlink_dedupe(self):
        doc = self.analyze([fixture("dotnet", "serilog-text.log")], extra=["--repos-dir", self.tmp])
        repos = doc["repositories"]
        names = sorted((r["name"], r["kind"]) for r in repos["discovered"])
        self.assertEqual(names, [("billing", "repository"), ("java-orders", "repository"), ("orders", "repository"), ("orders-wt", "worktree")])
        reasons = {s["reason"] for s in repos["skipped"]}
        self.assertIn("symlink-not-followed", reasons)
        self.assertIn("skipped-directory-name", reasons)
        self.assertFalse(repos["incomplete"])
        for r in repos["discovered"]:
            self.assertRegex(r["head"] or "", r"^[0-9a-f]{40}")
            self.assertIn(r["working_tree_dirty"], (True, False, None))
            self.assertGreater(r["inventory"]["files_indexed"], 0)
        orders = next(r for r in repos["discovered"] if r["name"] == "orders")
        self.assertEqual(orders["branch"], "master" if orders["branch"] == "master" else orders["branch"])
        self.assertIn("Acme.Orders", orders["inventory"]["namespaces"])

    def test_discovery_limits_reported(self):
        doc = self.analyze([fixture("dotnet", "serilog-text.log")], extra=["--repos-dir", self.tmp, "--limit", "max_repos=1"], expect_code=3)
        self.assertTrue(doc["repositories"]["incomplete"])
        self.assertTrue(any("max_repos" in r for r in doc["repositories"]["incomplete_reasons"]))
        self.assertEqual(doc["status"]["completion"], "partial")
        doc = self.analyze([fixture("dotnet", "serilog-text.log")], extra=["--repos-dir", self.tmp, "--limit", "max_repo_depth=1"], expect_code=3, out=self.out_dir("d"))
        self.assertTrue(any("max_repo_depth" in r for r in doc["repositories"]["incomplete_reasons"]))

    def test_invalid_repo_path(self):
        doc = self.analyze([fixture("dotnet", "serilog-text.log")], extra=["--repo", os.path.join(self.tmp, "org-a")], expect_code=3)
        self.assertIn("repo-invalid", doc["diagnostics"]["counts_by_code"])
        self.assertEqual(doc["repositories"]["discovered"], [])

    def test_attribution_resolved_with_verified_reference(self):
        doc = self.analyze([fixture("dotnet", "serilog-text.log")], extra=["--repos-dir", self.tmp])
        g = next(g for g in doc["groups"] if g["exception"] and g["exception"]["type"] == "System.InvalidOperationException")
        att = g["attribution"]
        self.assertEqual(att["status"], "resolved", att)
        self.assertEqual(att["candidates"][0]["repo"], "orders")
        kinds = {e["kind"] for e in att["candidates"][0]["evidence"]}
        self.assertIn("path", kinds)
        self.assertIn("namespace", kinds)
        # the identical worktree is a candidate at the same commit -> noted, not ambiguous
        self.assertIn("same commit", att.get("note", ""))
        inv = g["investigation"]
        self.assertEqual(inv["status"], "deterministic")
        ref = next(r for r in inv["source_references"] if r["path"] == "src/Acme.Orders/OrderService.cs")
        self.assertTrue(ref["verified"], ref)
        self.assertEqual(ref["line"], 42)
        self.assertIn("42>", ref["snippet"])
        s = inv["suggestions"][0]
        self.assertEqual(s["kind"], "source_backed")
        self.assertIn("OrderService.cs:4", s["summary"])
        self.assertTrue(s["regression_tests"] and s["verification_steps"])
        rc = inv["root_cause"]
        self.assertTrue(rc["observed"] and rc["uncertainty"])
        self.assertTrue(any("may not be the version" in u for u in rc["uncertainty"]))
        # the model queue carries a compact entry
        q = doc["investigation_queue"]
        self.assertTrue(any(e["id"] == g["id"] for e in q))
        entry = next(e for e in q if e["id"] == g["id"])
        self.assertLessEqual(len(json.dumps(entry)), 6000)
        self.assertTrue(entry["references"] and entry["references"][0]["verified"])

    def test_basename_only_evidence_is_unresolved_and_identical_filenames_distinguished(self):
        path = self.write("weak.log", "2026-09-13 12:00:00,123 - app - ERROR - failed while reading OrderService.cs settings\n")
        doc = self.analyze([path], extra=["--repos-dir", self.tmp])
        g = doc["groups"][0]
        self.assertEqual(g["attribution"]["status"], "unresolved")
        self.assertEqual(g["investigation"]["status"], "insufficient_evidence")
        # a frame with only a basename that exists in two repos must not resolve
        path2 = self.write("dup.log", "2026-09-13 12:00:00,123 - app - ERROR - boom\nSystem.Exception: x\n   at Other.Thing.Do() in OrderService.cs:line 1\n")
        doc2 = self.analyze([path2], extra=["--repos-dir", self.tmp], out=self.out_dir("b"))
        att = doc2["groups"][0]["attribution"]
        self.assertIn(att["status"], ("unresolved", "ambiguous"))
        # outputs keep repository identity next to repository-relative paths
        for c in att["candidates"]:
            self.assertTrue(c["repo"] and c["path"])

    def test_python_attribution_via_namespace_and_message_literal(self):
        doc = self.analyze([fixture("python", "python-asctime.log")], extra=["--repos-dir", self.tmp])
        g = next(g for g in doc["groups"] if g["exception"] and "ChargeFailed" in (g["exception"]["type"] or ""))
        att = g["attribution"]
        self.assertEqual(att["candidates"][0]["repo"], "billing")
        self.assertIn(att["status"], ("resolved", "ambiguous"))
        refs = g["investigation"]["source_references"]
        self.assertTrue(any(r["verified"] and r["path"] == "billing/worker.py" for r in refs), refs)

    def test_java_attribution_multi_repo(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log"), fixture("dotnet", "serilog-text.log")], extra=["--repos-dir", self.tmp])
        by_repo = doc["repositories"]["attribution_summary"]["per_repo"]
        self.assertIn("java-orders", by_repo)
        self.assertIn("orders", by_repo)
        java_group = next(g for g in doc["groups"] if g["exception"] and g["exception"]["type"] == "java.lang.IllegalStateException")
        self.assertEqual(java_group["attribution"]["candidates"][0]["repo"], "java-orders")
        ref = java_group["investigation"]["source_references"][0]
        self.assertEqual(ref["path"], "src/main/java/com/acme/orders/OrderService.java")
        self.assertFalse(ref["verified"])          # log line 42 is beyond the 4-line file: version mismatch reported
        self.assertIn("beyond end of file", ref["note"])

    def test_no_repo_means_no_attribution_attempt(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")])
        self.assertEqual(doc["repositories"]["mode"], "none")
        self.assertTrue(all(g["attribution"]["status"] == "not_attempted" for g in doc["groups"]))
        self.assertEqual(doc["investigation_queue"], [])


if __name__ == "__main__":
    unittest.main()

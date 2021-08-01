"""
Comprehensive test suite for Anvil Python bindings.
"""

import os
import shutil
import tempfile
import unittest

from pyanvil import Repository, version, hash_bytes
from pyanvil.errors import BranchExistsError


class TestPyAnvil(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="pyanvil_test_")

    def tearDown(self):
        if os.path.exists(self.test_dir):
            shutil.rmtree(self.test_dir)

    def test_version(self):
        v = version()
        self.assertEqual(v, "1.0.0")

    def test_hash_bytes(self):
        # Canonical Git SHA-1 for "hello world\n"
        h = hash_bytes(b"hello world\n")
        self.assertEqual(h, "3b18e512dba79e4c8300dd08aeb37f8e728b8dad")

    def test_repo_lifecycle(self):
        # 1. Initialize
        repo = Repository.init(self.test_dir)
        self.assertTrue(os.path.isdir(os.path.join(self.test_dir, ".anvil")))

        # 2. Status empty
        st = repo.status()
        self.assertTrue(st.is_clean)
        self.assertEqual(st.staged_count, 0)

        # 3. Add file
        hello_path = os.path.join(self.test_dir, "hello.txt")
        with open(hello_path, "w") as f:
            f.write("Hello from Python bindings!\n")

        repo.add(hello_path)
        st = repo.status()
        self.assertEqual(st.staged_count, 1)

        # 4. Commit
        commit_sha = repo.commit("feat: initial python commit")
        self.assertEqual(len(commit_sha), 40)

        # 5. Rev parse
        head_sha = repo.rev_parse("HEAD")
        self.assertEqual(head_sha, commit_sha)

        # 6. Branch creation
        repo.branch("dev")
        with self.assertRaises(BranchExistsError):
            repo.branch("dev")

        # 7. Checkout branch
        repo.checkout("dev")

        # 8. Add second file on dev branch
        feature_path = os.path.join(self.test_dir, "feature.txt")
        with open(feature_path, "w") as f:
            f.write("New feature enabled\n")

        repo.add(feature_path)
        dev_commit = repo.commit("feat: dev feature")
        self.assertNotEqual(dev_commit, commit_sha)

        # 9. Checkout back to main
        repo.checkout("main")
        self.assertFalse(os.path.exists(feature_path))

        repo.close()


if __name__ == "__main__":
    unittest.main()

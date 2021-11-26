"""
Comprehensive test suite for Anvil Python bindings.
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from pyanvil import Repository, version, hash_bytes
from pyanvil.errors import AnvilError, BranchExistsError


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

    def test_hash_bytes_preserves_embedded_nul(self):
        data = b"before\0after"
        expected = hashlib.sha1(b"blob 12\0" + data).hexdigest()
        self.assertEqual(hash_bytes(data), expected)

    def test_repository_paths_reject_embedded_nul(self):
        root = Path(self.test_dir, "repo")
        with Repository.init(str(root)):
            with self.assertRaises(ValueError):
                with Repository(str(root) + "\0ignored"):
                    pass

        new_root = Path(self.test_dir, "new")
        with self.assertRaises(ValueError):
            with Repository.init(str(new_root) + "\0ignored"):
                pass
        self.assertFalse(new_root.exists())

    def test_repository_operations_reject_embedded_nul(self):
        with Repository.init(self.test_dir) as repo:
            Path(self.test_dir, "safe.txt").write_text("safe content", encoding="utf-8")
            repo.add("safe.txt")
            head = repo.commit("initial")
            index = Path(self.test_dir, ".anvil", "index")
            before = index.read_bytes()
            operations = {
                "add": lambda: repo.add("safe.txt\0ignored"),
                "commit": lambda: repo.commit("subject\0ignored"),
                "branch name": lambda: repo.branch("unsafe\0ignored"),
                "branch revision": lambda: repo.branch("unsafe-rev", "HEAD\0ignored"),
                "checkout": lambda: repo.checkout("main\0ignored"),
                "revision": lambda: repo.rev_parse("HEAD\0ignored"),
            }
            for name, operation in operations.items():
                with self.subTest(operation=name):
                    with self.assertRaises(ValueError):
                        operation()
                    self.assertEqual(repo.rev_parse("HEAD"), head)
                    self.assertEqual(index.read_bytes(), before)

    def test_add_relative_path_uses_repository_directory(self):
        # A Repository can refer to a directory other than the process cwd.
        with open(os.path.join(self.test_dir, "relative.txt"), "w") as f:
            f.write("repository-relative path\n")
        with Repository.init(self.test_dir) as repo:
            repo.add("relative.txt")
            self.assertEqual(repo.status().staged_count, 1)

    def test_commit_epoch_is_correct_outside_utc(self):
        code = """
from pathlib import Path
import sys
import time
import zlib
from pyanvil import Repository
root = Path(sys.argv[1])
before = int(time.time())
with Repository.init(str(root)) as repo:
    (root / 'tracked.txt').write_text('content', encoding='utf-8')
    repo.add('tracked.txt')
    oid = repo.commit('timestamp check')
    data = zlib.decompress((root / '.anvil/objects' / oid[:2] / oid[2:]).read_bytes())
    author = next(line for line in data.split(b'\\n') if line.startswith(b'author '))
    epoch = int(author.rsplit(b' ', 2)[1])
after = int(time.time())
assert before <= epoch <= after, (before, epoch, after)
"""
        env = dict(os.environ, TZ="UTC+09")
        result = subprocess.run([sys.executable, "-c", code, self.test_dir],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_branch_revision_does_not_default_to_head(self):
        with Repository.init(self.test_dir) as repo:
            Path(self.test_dir, "tracked.txt").write_text("content", encoding="utf-8")
            repo.add("tracked.txt")
            head = repo.commit("initial")
            with self.assertRaises(AnvilError):
                repo.branch("empty-start", "")
            self.assertFalse(Path(self.test_dir, ".anvil/refs/heads/empty-start").exists())
            repo.branch("default-start")
            self.assertEqual(repo.rev_parse("default-start"), head)
            repo.branch("explicit-start", "HEAD")
            self.assertEqual(repo.rev_parse("explicit-start"), head)

    def test_invalid_branch_names_raise_without_terminating_python(self):
        with Repository.init(self.test_dir) as repo:
            Path(self.test_dir, "tracked.txt").write_text("content", encoding="utf-8")
            repo.add("tracked.txt")
            repo.commit("initial")

        # An exception crossing the C ABI could terminate the interpreter, so
        # run the rejection checks in a child process and inspect its result.
        code = """
import sys
from pyanvil import Repository
from pyanvil.errors import AnvilError
with Repository(sys.argv[1]) as repo:
    for name in ('bad..name', 'bad.lock', 'bad//name', '.hidden', 'bad.', ''):
        try:
            repo.branch(name)
        except AnvilError:
            continue
        raise AssertionError(f'accepted invalid branch: {name!r}')
"""
        result = subprocess.run(
            [sys.executable, "-c", code, self.test_dir], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(path.name for path in Path(self.test_dir, ".anvil/refs/heads").iterdir()),
            ["main"],
        )

    def test_reinitialization_preserves_repository_state(self):
        root = Path(self.test_dir)
        metadata = root / ".anvil"
        with Repository.init(str(root)) as repo:
            (root / "tracked.txt").write_text("initial content", encoding="utf-8")
            repo.add("tracked.txt")
            repo.commit("initial")
            repo.branch("work")
            repo.checkout("work")
            (root / "tracked.txt").write_text("staged content", encoding="utf-8")
            repo.add("tracked.txt")

        config = metadata / "config"
        config.write_text(config.read_text() + "[user]\n\tname = Keep Me\n")
        saved = {
            name: (metadata / name).read_bytes()
            for name in ("HEAD", "config", "index", "refs/heads/work")
        }

        with Repository.init(str(root)) as reopened:
            for name, content in saved.items():
                with self.subTest(file=name):
                    self.assertEqual((metadata / name).read_bytes(), content)
            self.assertEqual(reopened.status().staged_count, 1)

    def test_locked_reference_writes_raise_without_terminating_python(self):
        root = Path(self.test_dir)
        with Repository.init(str(root)) as repo:
            (root / "tracked.txt").write_text("content", encoding="utf-8")
            repo.add("tracked.txt")
            head = repo.commit("initial")
        locks = [root / ".anvil/refs/heads" / name for name in ("main.lock", "blocked.lock")]
        for lock in locks:
            lock.write_text("other writer", encoding="utf-8")
        code = """
import sys
from pyanvil import Repository
from pyanvil.errors import AnvilError
accepted = []
with Repository(sys.argv[1]) as repo:
    for operation in (lambda: repo.branch('blocked'), lambda: repo.commit('blocked')):
        try:
            operation()
        except AnvilError:
            continue
        accepted.append('locked write accepted')
assert not accepted, accepted
"""
        result = subprocess.run([sys.executable, "-c", code, str(root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for lock in locks:
            self.assertEqual(lock.read_text(), "other writer")
        with Repository(str(root)) as repo:
            self.assertEqual(repo.rev_parse("HEAD"), head)
        self.assertFalse((root / ".anvil/refs/heads/blocked").exists())

    def test_bare_reinitialization_preserves_head_and_config(self):
        # Exercise the C ABI directly: opening bare repositories is not supported
        # by Repository yet, but the native initializer accepts bare=True.
        from pyanvil.repository import _lib

        root = Path(self.test_dir)
        encoded_root = os.fsencode(root)
        self.assertEqual(_lib.anvil_repo_init(encoded_root, 1), 0)
        head = root / "HEAD"
        config = root / "config"
        head.write_bytes(b"ref: refs/heads/work\n")
        custom_config = config.read_bytes() + b"[user]\n\tname = Keep Me\n"
        config.write_bytes(custom_config)

        self.assertEqual(_lib.anvil_repo_init(encoded_root, 1), 0)
        self.assertEqual(head.read_bytes(), b"ref: refs/heads/work\n")
        self.assertEqual(config.read_bytes(), custom_config)

    def test_relative_repository_path_survives_cwd_change(self):
        previous_cwd = os.getcwd()
        try:
            os.chdir(self.test_dir)
            with Repository.init("repo") as repo:
                with open(os.path.join(self.test_dir, "repo", "relative.txt"), "w") as f:
                    f.write("stable repository path")
                os.chdir(previous_cwd)
                repo.add("relative.txt")
                self.assertEqual(repo.status().staged_count, 1)
        finally:
            os.chdir(previous_cwd)

    def test_add_outside_path_preserves_index(self):
        root = Path(self.test_dir, "repo")
        sibling = Path(self.test_dir, "repo-other")
        sibling.mkdir()
        outside = Path(self.test_dir, "outside.txt")
        outside.write_text("outside sentinel", encoding="utf-8")
        sibling_file = sibling / "outside.txt"
        sibling_file.write_text("sibling sentinel", encoding="utf-8")

        with Repository.init(str(root)) as repo:
            (root / "inside.txt").write_text("inside content", encoding="utf-8")
            repo.add("inside.txt")
            index = root / ".anvil" / "index"
            before = index.read_bytes()

            for path in (str(outside), "../outside.txt", str(sibling_file)):
                with self.subTest(path=path):
                    with self.assertRaises(AnvilError):
                        repo.add(path)
                    self.assertEqual(index.read_bytes(), before)
                    self.assertEqual(repo.status().staged_count, 1)

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

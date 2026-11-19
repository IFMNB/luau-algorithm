#!/usr/bin/env python3
"""Build and run the parallel-api test suite against the real module source."""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CI_DIR = Path(__file__).resolve().parent
API_PATH = CI_DIR.parent / "src" / "api.luau"


def build_suite(strict: bool) -> str:
	"""(Re)creates the chunk exactly like the manual harness used during development."""

	parts = [
		f"local SHAREDTABLE_STRICT = {'true' if strict else 'false'}\n",
		(CI_DIR / "preamble.luau").read_text(encoding="utf-8"),
		"\n",
		API_PATH.read_text(encoding="utf-8"),
		"\n",
		(CI_DIR / "postamble.luau").read_text(encoding="utf-8"),
		(CI_DIR / "tests.luau").read_text(encoding="utf-8"),
	]

	return "".join(parts)


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument(
		"--luau",
		default=shutil.which("luau") or "luau",
		help="Luau CLI executable (default: first `luau` in PATH)",
	)
	parser.add_argument(
		"--no-codegen",
		action="store_true",
		help="do not pass --codegen to the Luau CLI",
	)
	args = parser.parse_args()

	if not API_PATH.is_file():
		print(f"missing module: {API_PATH}", file=sys.stderr)
		return 2

	flags = ["-O2"]
	if not args.no_codegen:
		flags.append("--codegen")

	failed = False

	with tempfile.TemporaryDirectory(prefix="parallel-api-ci-") as directory:
		for strict in (False, True):
			mode = "strict" if strict else "lenient"
			suite = Path(directory) / f"suite-{mode}.luau"
			suite.write_text(build_suite(strict), encoding="utf-8")

			print(f"=== SharedTable.update: {mode} ===")

			try:
				result = subprocess.run([args.luau, *flags, str(suite)])
			except FileNotFoundError:
				print(f"luau executable not found: {args.luau}", file=sys.stderr)
				return 2

			if result.returncode != 0:
				failed = True

	if failed:
		print("parallel-api: tests failed", file=sys.stderr)
		return 1

	print("parallel-api: tests passed")
	return 0


if __name__ == "__main__":
	sys.exit(main())

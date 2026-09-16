"""Running pg_dump / pg_restore without putting passwords on the command line."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from psycopg.conninfo import conninfo_to_dict


@dataclass(frozen=True)
class PgTools:
    bin_dir: Path | None = None

    def executable(self, name: str) -> str:
        if self.bin_dir is not None:
            for candidate in (self.bin_dir / name, self.bin_dir / f"{name}.exe"):
                if candidate.exists():
                    return str(candidate)
        found = shutil.which(name)
        if not found:
            raise FileNotFoundError(f"{name} not found; set PG_BIN_DIR")
        return found

    def version(self, name: str) -> str:
        out = subprocess.run([self.executable(name), "--version"], check=True, capture_output=True, text=True)
        return out.stdout.strip()


def connection_args(url: str) -> tuple[list[str], dict[str, str]]:
    """Splits a connection URL into libpq flags plus PGPASSWORD, so the secret never appears in `ps`."""
    info = conninfo_to_dict(url)
    args: list[str] = []
    for key, flag in (("host", "--host"), ("port", "--port"), ("user", "--username"), ("dbname", "--dbname")):
        if info.get(key):
            args += [flag, str(info[key])]
    env = dict(os.environ)
    if info.get("password"):
        env["PGPASSWORD"] = str(info["password"])
    if info.get("sslmode"):
        env["PGSSLMODE"] = str(info["sslmode"])
    return args, env


def run(cmd: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        # stderr from pg tools names objects, not data; still trimmed to keep logs small.
        raise RuntimeError(
            f"{Path(cmd[0]).name} failed ({result.returncode}): {result.stderr.strip()[-2000:]}"
        )
    return result

#!/usr/bin/env python3
"""
docker_watchdog.py — process supervision by INACTIVITY.

Replaces the earlier shell-based version. The reason is not stylistic: the
bash script depended on `stat -c`, `du -sb`, `find -printf` and `setsid`, all
specific to GNU coreutils. On macOS (BSD userland) they fail on the very
first check, which would defeat the portability that Docker gives the
pipeline in the first place.

Only the Python standard library is used here, which is already a mandatory
dependency of Snakemake. The module can be used in two ways:

  1. As a library, directly from the Snakefile (the preferred way, with no
     shell involved at all):

        import docker_watchdog as wd
        rc = wd.supervise(cmd=["docker", "run", ...], log_path="x.log",
                          mode="docker", container_name="my_container",
                          inactivity="90m")

  2. As a CLI, useful for debugging a single command in isolation:

        python docker_watchdog.py --log x.log --inactivity 90m \\
            --mode docker --name c1 -- docker run ...

Policy: a command is only stopped once it stops showing signs of life. As
long as there is writing to the log, writing to disk, CPU usage or container
I/O, it keeps running for as long as it needs. A 40-hour tool is never
interrupted for "exceeding the time limit".

Exit codes:
    0-123  the command's actual exit code
    124    stopped due to INACTIVITY
    125    stopped for exceeding the absolute ceiling (max_runtime)
    137    typically an OOM kill (the container hit its --memory limit)
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import signal
import subprocess
import sys
import time

__all__ = ["supervise", "parse_duration", "explain_exit_code", "redact_cmd",
           "EXIT_INACTIVITY", "EXIT_MAX_RUNTIME", "WatchdogError"]

EXIT_INACTIVITY = 124
# 125 CANNOT be used here: it is the code the docker client itself returns
# when the daemon refuses the `docker run` (invalid flag, a log driver that
# does not accept the option, a container name already in use). Reusing 125
# would make the watchdog report "exceeded the time ceiling" for what is
# actually a Docker configuration error.
EXIT_MAX_RUNTIME = 123

IS_WINDOWS = os.name == "nt"
IS_LINUX = platform.system() == "Linux"

# Cap on the number of entries walked per watched directory. Without this, a
# check every two minutes over an output directory with hundreds of
# thousands of files would become meaningful I/O cost on its own.
MAX_SCAN_ENTRIES = 50_000

_DURATION_RE = re.compile(r"^(\d+)\s*([smhd]?)$", re.IGNORECASE)
_MULTIPLIER = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 1}


class WatchdogError(RuntimeError):
    """Usage error of the watchdog itself (not of the supervised command)."""


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
def parse_duration(value, default=None):
    """Converts '30s', '90m', '48h', '2d' or a plain number (seconds) to int."""
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return int(value)
    match = _DURATION_RE.match(str(value).strip())
    if not match:
        raise WatchdogError(
            f"Invalid duration: {value!r}. Use formats like 30s, 90m, 48h, 2d."
        )
    amount, unit = match.groups()
    return int(amount) * _MULTIPLIER[unit.lower()]


_SECRET_RE = re.compile(
    r"^(.*(?:PASS|PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|CREDENTIAL)[^=]*)=.*$",
    re.IGNORECASE,
)


def redact_cmd(cmd):
    """Masks sensitive values before the command is logged.

    The normal path already avoids the problem by using --env-file (the
    secret stays in the file, never on the command line). This is a second
    line of defense, in case someone passes `-e PASSWORD=...` directly.
    """
    out = []
    for part in cmd:
        match = _SECRET_RE.match(str(part))
        out.append(f"{match.group(1)}=***" if match else str(part))
    return out


def explain_exit_code(code, log_path=None, rule_name=None):
    """Human-readable message for an exit code, with the next step to take."""
    where = f" in rule '{rule_name}'" if rule_name else ""
    logs = ""
    if log_path:
        logs = (f"\n  Tool log:     {log_path}"
                f"\n  Watchdog log: {log_path}.watchdog")

    if code == EXIT_INACTIVITY:
        return (
            f"Command{where} stopped due to INACTIVITY: no sign of progress "
            f"(log, disk, CPU or I/O) within the configured window."
            f"\n  If the tool really was still working, increase "
            f"watchdog.per_rule.{rule_name or '<rule>'}.inactivity_timeout"
            f"{logs}"
        )
    if code == EXIT_MAX_RUNTIME:
        return (
            f"Command{where} stopped for exceeding the absolute ceiling "
            f"(watchdog.per_rule.{rule_name or '<rule>'}.max_runtime)."
            f"{logs}"
        )
    if code in (137, -9):
        return (
            f"Command{where} killed with SIGKILL (code {code}), typically "
            f"an OOM kill: the container hit its --memory limit."
            f"\n  Increase resources.mem_mb or lower resources.max_jobs."
            f"{logs}"
        )
    if code in (134, -6):
        return (f"Command{where} aborted (code {code}). Possibly out of "
                f"shared memory; consider increasing docker.shm_size."
                f"{logs}")
    if code in (143, -15):
        return (f"Command{where} stopped by SIGTERM (code {code}). "
                f"This is usually the result of an interruption (Ctrl-C) or "
                f"of Snakemake shutting down after another rule failed, "
                f"rather than a problem with this rule itself.{logs}")
    if code == 130:
        return f"Command{where} interrupted with Ctrl-C (code 130).{logs}"

    # Codes generated by the docker CLIENT, before the tool ever started.
    if code == 125:
        return (
            f"`docker run` itself failed{where} (code 125): the daemon "
            f"refused the command. The tool never got to run.\n"
            f"  Common causes: a flag not supported by the daemon, a log "
            f"driver that does not accept --log-opt max-size (journald/"
            f"syslog), a container name already in use, or a bind-mount "
            f"path that does not exist.\n"
            f"  If it's the log driver, set docker.log_opts: false in config.yaml."
            f"{logs}"
        )
    if code == 126:
        return (f"The command inside the container{where} could not be "
                f"executed (code 126): no execute permission, or "
                f"--entrypoint points at something that is not executable."
                f"{logs}")
    if code == 127:
        return (f"Command not found inside the container{where} "
                f"(code 127): check --entrypoint and the executable name."
                f"{logs}")
    if code == 1:
        return (
            f"The tool{where} ran and exited with an error (code 1). "
            f"This is an error from the tool itself, not from the watchdog "
            f"or a resource limit.\n"
            f"  The cause is in the tool's log; the first line of the "
            f"watchdog log carries the exact docker command to reproduce it "
            f"by hand."
            f"{logs}"
        )
    return f"Command{where} failed with code {code}.{logs}"


def docker_path(path):
    """Normalizes a host path for use in `-v host:container`.

    On Windows, Docker Desktop accepts the native drive-letter form; we only
    normalize separators. The recommended path for Windows is still to run
    the pipeline under WSL2, where everything is POSIX.
    """
    abs_path = os.path.abspath(path)
    if IS_WINDOWS:
        return abs_path.replace("\\", "/")
    return abs_path


def host_user_spec(policy="auto"):
    """Returns 'uid:gid' when mapping the host user makes sense.

    This only applies on Linux. On Docker Desktop (macOS/Windows), file
    sharing goes through a VM that already translates ownership, and forcing
    a host UID tends to break containers whose entrypoint expects a user
    that exists in /etc/passwd.
    """
    if policy is False or policy == "false":
        return None
    if policy in (True, "true"):
        forced = True
    else:
        forced = False
    if not hasattr(os, "getuid"):
        return None
    if not IS_LINUX and not forced:
        return None
    return f"{os.getuid()}:{os.getgid()}"


# ---------------------------------------------------------------------------
# Collecting signs of life
# ---------------------------------------------------------------------------
def _file_signature(path):
    try:
        st = os.stat(path)
        return (st.st_size, int(st.st_mtime))
    except OSError:
        return None


def _tree_signature(root, max_entries=MAX_SCAN_ENTRIES):
    """(file count, total bytes, most recent mtime) of a directory tree.

    Portable equivalent of the shell version's `du -sb` + `find -printf '%T@'`.
    """
    count = 0
    total = 0
    newest = 0.0
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    if count >= max_entries:
                        return (count, total, newest)
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                            continue
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    count += 1
                    total += st.st_size
                    if st.st_mtime > newest:
                        newest = st.st_mtime
        except OSError:
            continue
    return (count, total, newest)


def _docker_stats(container_name, timeout=30):
    """CPU%, Block I/O and Net I/O of the container.

    MemUsage is deliberately ignored: it fluctuates even in a process stuck
    thrashing swap, which is exactly the case we need to detect.
    """
    try:
        proc = subprocess.run(
            ["docker", "stats", "--no-stream",
             "--format", "{{.CPUPerc}}|{{.BlockIO}}|{{.NetIO}}|{{.PIDs}}",
             container_name],
            capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    line = proc.stdout.strip()
    return line or None


def _cpu_percent(stats_line):
    if not stats_line:
        return None
    try:
        return float(stats_line.split("|", 1)[0].strip().rstrip("%"))
    except (ValueError, IndexError):
        return None


class ActivityMonitor:
    """Aggregates the signs of life into a single comparable fingerprint."""

    def __init__(self, log_path, watch_paths=(), container_name=None,
                 cpu_threshold=1.0):
        self.log_path = log_path
        self.watch_paths = list(watch_paths)
        self.container_name = container_name
        self.cpu_threshold = float(cpu_threshold)
        self._last_cpu = None

    def sample(self):
        parts = [_file_signature(self.log_path)]
        for path in self.watch_paths:
            parts.append(_tree_signature(path) if os.path.exists(path) else None)

        cpu_busy = False
        if self.container_name:
            stats = _docker_stats(self.container_name)
            # Block I/O and Net I/O are cumulative counters: if they changed,
            # work happened, even if the log stayed silent. This is what
            # saves eggNOG's diamond step, which spends hours writing to a
            # temp directory without printing anything.
            parts.append(stats.split("|", 1)[1] if stats else None)
            cpu = _cpu_percent(stats)
            self._last_cpu = cpu
            cpu_busy = cpu is not None and cpu >= self.cpu_threshold

        return tuple(parts), cpu_busy

    @property
    def last_cpu(self):
        return self._last_cpu


# ---------------------------------------------------------------------------
# Portable termination
# ---------------------------------------------------------------------------
def _remove_container(container_name, grace):
    """Stops and removes the container. Works the same way on Linux, macOS
    and Windows, because the action is carried out by the Docker daemon, not
    by the local operating system."""
    try:
        subprocess.run(["docker", "stop", "-t", str(int(grace)), container_name],
                       capture_output=True, timeout=grace + 60)
    except (subprocess.TimeoutExpired, OSError):
        pass
    try:
        subprocess.run(["docker", "rm", "-f", container_name],
                       capture_output=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _container_exists(container_name):
    try:
        proc = subprocess.run(["docker", "inspect", container_name],
                              capture_output=True, timeout=30)
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def _terminate_tree(proc, grace):
    """Terminates the process and its descendants.

    PGAP, for instance, launches its own containers; killing only the parent
    process would leave the whole tree orphaned.
    """
    if proc.poll() is not None:
        return

    if IS_WINDOWS:
        try:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                           capture_output=True, timeout=60)
        except (subprocess.TimeoutExpired, OSError):
            proc.kill()
        return

    # POSIX: the process was created with start_new_session=True, so it
    # leads its own process group and we can signal the whole tree at once.
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        pgid = None

    try:
        if pgid is not None:
            os.killpg(pgid, signal.SIGTERM)
        else:
            proc.terminate()
    except OSError:
        pass

    deadline = time.time() + grace
    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.5)

    try:
        if pgid is not None:
            os.killpg(pgid, signal.SIGKILL)
        else:
            proc.kill()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Supervision
# ---------------------------------------------------------------------------
def supervise(cmd, log_path, mode="docker", container_name=None,
              inactivity="90m", max_runtime=0, check_interval="120s",
              cpu_threshold=1.0, grace="120s", watch=(), poll_interval=5):
    """Runs `cmd` under inactivity supervision. Returns the exit code.

    cmd            list of arguments (never a string: no shell, no quoting)
    log_path       the command's stdout/stderr go here
    mode           'docker' injects --name and monitors the container via
                   docker stats
    inactivity     silence tolerated before stopping the command
    max_runtime    absolute safety ceiling (0 disables it)
    watch          directories whose changes count as a sign of life
    """
    if isinstance(cmd, str):
        raise WatchdogError(
            "cmd must be a list of arguments, not a string. Passing a "
            "string would require a shell, which is exactly what this "
            "module avoids for the sake of portability."
        )

    cmd = [str(part) for part in cmd]
    inactivity_s = parse_duration(inactivity)
    max_runtime_s = parse_duration(max_runtime, 0) or 0
    check_s = parse_duration(check_interval)
    grace_s = parse_duration(grace)

    if inactivity_s <= 0:
        raise WatchdogError("inactivity must be greater than zero")
    if check_s <= 0:
        raise WatchdogError("check_interval must be greater than zero")

    if mode == "docker":
        if not container_name:
            raise WatchdogError("container_name is required in docker mode")
        if cmd[:2] != ["docker", "run"]:
            raise WatchdogError("in docker mode the command must start with "
                                "'docker run'")
        # Naming the container is what lets us remove it even if the docker
        # client itself dies. Without this, `--rm` never runs and orphaned
        # containers pile up over the course of a large batch, consuming
        # memory.
        # A container left over from a previous attempt would make
        # `docker run --name` fail with "name already in use" (code 125).
        # This matters because `retries` re-executes the same rule for the
        # same sample, potentially producing the same name.
        if _container_exists(container_name):
            _remove_container(container_name, 10)
        cmd = cmd[:2] + ["--name", container_name] + cmd[2:]
    else:
        container_name = None

    log_dir = os.path.dirname(os.path.abspath(log_path))
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
    wd_log_path = f"{log_path}.watchdog"

    def wlog(message):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(wd_log_path, "a", encoding="utf-8") as handle:
                handle.write(f"[{stamp}] {message}\n")
        except OSError:
            pass

    wlog("=" * 60)
    wlog(f"Command: {' '.join(redact_cmd(cmd))}")
    wlog(f"Policy: inactivity={inactivity_s}s ceiling={max_runtime_s}s "
         f"interval={check_s}s cpu_min={cpu_threshold}%")
    if watch:
        wlog(f"Watched directories: {', '.join(watch)}")

    popen_kwargs = {}
    if IS_WINDOWS:
        popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        popen_kwargs["start_new_session"] = True

    monitor = ActivityMonitor(log_path, watch, container_name, cpu_threshold)
    kill_reason = None

    # The log is opened in APPEND mode, never truncated.
    #
    # The previous version truncated it on every call, which meant a
    # `retries` attempt would erase the log of the very attempt that
    # failed — exactly the evidence needed to diagnose the failure. Each
    # attempt now gets its own separator banner and the full history is
    # preserved.
    banner = (
        f"\n{'=' * 78}\n"
        f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] New attempt\n"
        f"Command: {' '.join(redact_cmd(cmd))}\n"
        f"{'=' * 78}\n"
    )
    try:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(banner)
    except OSError:
        pass

    with open(log_path, "ab") as log_handle:
        try:
            proc = subprocess.Popen(cmd, stdout=log_handle,
                                    stderr=subprocess.STDOUT, **popen_kwargs)
        except OSError as exc:
            wlog(f"Failed to start the command: {exc}")
            raise WatchdogError(f"Could not execute {cmd[0]!r}: {exc}")

        wlog(f"Started with PID {proc.pid}")
        started = time.time()
        last_activity = started
        last_sample, _ = monitor.sample()

        while True:
            # Fractional wait: wakes up within poll_interval seconds if the
            # process finishes, instead of sleeping the whole interval.
            # Without this, a 10-second job would be stuck until the end of
            # a 3-minute check_interval just waiting for the watchdog to
            # notice.
            waited = 0
            finished = False
            while waited < check_s:
                step = min(poll_interval, check_s - waited)
                try:
                    proc.wait(timeout=step)
                    finished = True
                    break
                except subprocess.TimeoutExpired:
                    waited += step
            if finished:
                break

            now = time.time()
            sample, cpu_busy = monitor.sample()
            if sample != last_sample or cpu_busy:
                last_activity = now
                last_sample = sample

            idle = int(now - last_activity)
            elapsed = int(now - started)
            cpu = monitor.last_cpu
            cpu_txt = f" cpu={cpu:.1f}%" if cpu is not None else ""
            wlog(f"alive={elapsed}s idle={idle}s{cpu_txt}")

            if idle >= inactivity_s:
                kill_reason = "inactivity"
                wlog(f"INACTIVITY: no sign of progress for {idle}s "
                     f"(limit {inactivity_s}s). Stopping.")
                break

            if 0 < max_runtime_s <= elapsed:
                kill_reason = "max_runtime"
                wlog(f"ABSOLUTE CEILING: {elapsed}s of runtime "
                     f"(limit {max_runtime_s}s). Stopping.")
                break

        if kill_reason:
            if container_name and _container_exists(container_name):
                _remove_container(container_name, grace_s)
            _terminate_tree(proc, grace_s)

        try:
            returncode = proc.wait(timeout=grace_s + 60)
        except subprocess.TimeoutExpired:
            proc.kill()
            returncode = proc.wait()

    # Final cleanup: makes sure no container outlives the job.
    if container_name and _container_exists(container_name):
        wlog(f"Cleanup: removing leftover container {container_name}")
        _remove_container(container_name, grace_s)

    if kill_reason == "inactivity":
        returncode = EXIT_INACTIVITY
    elif kill_reason == "max_runtime":
        returncode = EXIT_MAX_RUNTIME

    wlog(f"Finished with code {returncode}")

    if returncode != 0:
        # Now that the process has exited and released the descriptor, it is
        # safe to append the diagnosis to the main log on any platform.
        try:
            with open(log_path, "a", encoding="utf-8", errors="replace") as handle:
                handle.write("\n[watchdog] "
                             + explain_exit_code(returncode, log_path) + "\n")
        except OSError:
            pass

    return returncode


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Supervises a command by inactivity (cross-platform).",
        epilog="Example: %(prog)s --log x.log --inactivity 90m --mode docker "
               "--name c1 -- docker run --rm alpine sleep 60",
    )
    parser.add_argument("--log", required=True)
    parser.add_argument("--mode", choices=["docker", "process"], default="docker")
    parser.add_argument("--name", default=None)
    parser.add_argument("--inactivity", default="90m")
    parser.add_argument("--max-runtime", default="0s")
    parser.add_argument("--check-interval", default="120s")
    parser.add_argument("--cpu-threshold", type=float, default=1.0)
    parser.add_argument("--grace", default="120s")
    parser.add_argument("--watch", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args(argv)
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("no command given after '--'")

    try:
        return supervise(
            cmd=command, log_path=args.log, mode=args.mode,
            container_name=args.name, inactivity=args.inactivity,
            max_runtime=args.max_runtime, check_interval=args.check_interval,
            cpu_threshold=args.cpu_threshold, grace=args.grace,
            watch=args.watch,
        )
    except WatchdogError as exc:
        print(f"[docker_watchdog] ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

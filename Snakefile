# =============================================================================
# Snakefile — SnakeMergeAnnotation workflow
# =============================================================================
# Usage:
#   snakemake --configfile config.yaml --cores all --jobs 2 \
#             --keep-going --latency-wait 60 --rerun-incomplete
#
# PORTABILITY
# -----------
# The pipeline uses Docker specifically to be cross-platform, so the Snakefile
# does not depend on any host shell utility. All local logic (copies,
# directory creation, downloads, process supervision) is done with Python's
# standard library. The only external executables invoked are `docker` and
# `python`, both available on Linux, macOS and Windows.
#
# Shell commands only ever exist INSIDE the containers, where the operating
# system is always the same — which is the whole point of using containers.
#
# Tool order (optional):
#   --config merge.tool_order=prokka,dfast,pgap,eggnog
# =============================================================================
import glob
import hashlib
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import uuid
import urllib.error
import urllib.request

SNAKEFILE_DIR = os.path.dirname(os.path.abspath(workflow.snakefile))
SCRIPTS_DIR = os.path.join(SNAKEFILE_DIR, "scripts")

# The inactivity supervisor is imported as a MODULE, not run as an external
# script. This keeps the shell out of the critical path: no quoting, no
# differences between bash and zsh, no dependency on GNU coreutils (the
# previous version used `stat -c`, `du -sb` and `find -printf`, none of which
# exist in the BSD userland of macOS).
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)
try:
    import docker_watchdog as watchdog
except ImportError as _exc:
    raise ImportError(
        f"[SnakeMergeAnnotation] Could not import the inactivity supervisor. "
        f"Expected at: {os.path.join(SCRIPTS_DIR, 'docker_watchdog.py')}\n"
        f"Original error: {_exc}"
    )

IS_WINDOWS = os.name == "nt"


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def sanitize_prefix(name):
    """Replaces invalid characters (such as dots) with underscores."""
    return re.sub(r'[^a-zA-Z0-9_-]', '_', name)


def mem_to_mb(mem_str):
    """Converts '24g' or '24576m' to MB (int)."""
    mem_str = str(mem_str).lower().strip()
    match = re.match(r'^(\d+)\s*([gm]?)b?$', mem_str)
    if not match:
        return 8192
    num, unit = match.groups()
    num = int(num)
    if unit == 'g':
        return num * 1024
    return num


def ensure_writable_dir(path, mode=None):
    """Creates the directory and adjusts permissions on platforms that have
    the concept of POSIX permission bits.

    On Windows, POSIX bits do not apply; the call is simply skipped instead
    of failing.
    """
    os.makedirs(path, exist_ok=True)
    if IS_WINDOWS:
        return path
    try:
        os.chmod(path, mode if mode is not None else DIR_MODE)
    except (PermissionError, OSError, NameError):
        pass
    return path


def verify_output(path, tool_name, sample, search_dir=None, patterns=None):
    """Confirms that the output exists and is not empty. If the name differs
    from what was expected, looks for known alternatives before failing."""
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path

    if search_dir and patterns:
        found = []
        for pat in patterns:
            found.extend(glob.glob(os.path.join(search_dir, "**", pat), recursive=True))
        found = [f for f in found if os.path.getsize(f) > 0]
        if found:
            found.sort(key=lambda p: p.count(os.sep))
            shutil.copy(found[0], path)
            print(f"[{tool_name}] Warning: output name differs for '{sample}'. "
                  f"Copied '{found[0]}' -> '{path}'")
            return path

    raise RuntimeError(
        f"[{tool_name}] Failed to produce the expected output for sample '{sample}': "
        f"'{path}' does not exist or is empty.\n"
        f"  - Tool log:     check the rule's .log file\n"
        f"  - Watchdog log: same path with a .watchdog suffix"
    )


# =============================================================================
# CONFIG PARSING
# =============================================================================
FASTA_DIR  = config["paths"]["fasta_dir"]
OUTPUT_DIR = config["paths"]["output_dir"]
THREADS    = max(1, int(config["general"]["threads"]))

DIR_MODE = int(str(config.get("general", {}).get("dir_mode", "0775")), 8)

MEM_TOTAL = int(config["resources"]["mem_mb"])
MAX_JOBS  = max(1, int(config["resources"]["max_jobs"]))
MEM_PER_JOB = max(1024, MEM_TOTAL // MAX_JOBS)

# Per-rule memory ceiling. Tools with a peak well above average — DFAST's
# ghostx functional-annotation step or eggNOG's diamond, for instance — need
# more than MEM_TOTAL/max_jobs. A rule that requests nearly all of MEM_TOTAL
# automatically ends up running alone, because Snakemake's scheduler cannot
# fit another heavy job alongside it.
MEM_PER_RULE = config.get("resources", {}).get("per_rule", {}) or {}

# os.cpu_count() is portable; `nproc` only exists in GNU coreutils.
TOTAL_CORES = os.cpu_count() or 1

# ------------------------------- Docker --------------------------------------
DOCKER_CFG          = config.get("docker", {}) or {}
DOCKER_SHM          = DOCKER_CFG.get("shm_size", "2g")
DOCKER_LOG_MAX      = DOCKER_CFG.get("log_max_size", "10m")
# Some daemons default to the journald/syslog driver, and those drivers
# reject --log-opt max-size, making `docker run` fail with 125 before the
# tool even starts. Disable this here if that is the case.
DOCKER_LOG_OPTS     = bool(DOCKER_CFG.get("log_opts", True))
DOCKER_DISABLE_SWAP = bool(DOCKER_CFG.get("disable_swap", True))
DOCKER_USER_POLICY  = DOCKER_CFG.get("map_host_user", "auto")
DOCKER_EXTRA        = [str(f) for f in (DOCKER_CFG.get("extra_flags", []) or [])]

# On Docker Desktop (macOS/Windows), file sharing goes through a VM that
# already translates file ownership. Forcing -u with a host UID breaks
# containers whose entrypoint expects a user to exist in /etc/passwd, so the
# mapping is only applied on Linux (the 'auto' policy).
DOCKER_USER_SPEC = watchdog.host_user_spec(DOCKER_USER_POLICY)

# --------------------------- Container runtime --------------------------------
# Docker is not available on most HPC clusters (it requires a root daemon).
# Apptainer (formerly Singularity) is the standard alternative there: no
# daemon, runs as the invoking user by default, and can consume the exact
# same images referenced by docker_image directly via a `docker://` URI, or a
# locally pre-converted .sif file when compute nodes have no internet access.
CONTAINER_RUNTIME = str(config.get("container_runtime", "docker")).strip().lower()
if CONTAINER_RUNTIME not in ("docker", "apptainer"):
    raise ValueError(
        f"[SnakeMergeAnnotation] container_runtime must be 'docker' or "
        f"'apptainer', got: {CONTAINER_RUNTIME!r}"
    )
IS_APPTAINER = CONTAINER_RUNTIME == "apptainer"

APPTAINER_CFG   = config.get("apptainer", {}) or {}
APPTAINER_EXTRA = [str(f) for f in (APPTAINER_CFG.get("extra_flags", []) or [])]
APPTAINER_SIF   = APPTAINER_CFG.get("sif", {}) or {}


def resolve_image(tool_key, docker_image):
    """Resolves the image reference to actually pass to the container
    runtime.

    Under Apptainer, returns a local .sif path when one is configured under
    apptainer.sif.<tool_key> in config.yaml (the usual case on HPC nodes
    without internet access on the compute side), otherwise a
    `docker://<docker_image>` reference that Apptainer pulls and converts to
    SIF on first use, caching it locally. Under Docker, docker_image is
    returned unchanged.
    """
    if not IS_APPTAINER:
        return docker_image
    override = APPTAINER_SIF.get(tool_key)
    return override if override else f"docker://{docker_image}"


# ------------------------------ Watchdog -------------------------------------
WATCHDOG_CFG = config.get("watchdog", {}) or {}
MAX_RETRIES  = int(WATCHDOG_CFG.get("max_retries", 3))
WD_PER_RULE  = WATCHDOG_CFG.get("per_rule", {}) or {}


def wd_setting(rule_name, key, default):
    """Resolves a watchdog parameter: rule-specific value, then the global
    value, then the built-in default."""
    per = WD_PER_RULE.get(rule_name, {}) or {}
    if key in per:
        return per[key]
    if key in WATCHDOG_CFG:
        return WATCHDOG_CFG[key]
    return default


def wd_args(rule_name):
    return {
        "inactivity":     wd_setting(rule_name, "inactivity_timeout", "90m"),
        "max_runtime":    wd_setting(rule_name, "max_runtime", "0s"),
        "check_interval": wd_setting(rule_name, "check_interval", "120s"),
        "cpu_threshold":  float(wd_setting(rule_name, "cpu_threshold", 1.0)),
        "grace":          wd_setting(rule_name, "grace", "120s"),
    }


# ------------------------------- Images --------------------------------------
IMG_BAKTA  = resolve_image("bakta",  config["bakta"]["docker_image"])
IMG_PROKKA = resolve_image("prokka", config["prokka"]["docker_image"])
IMG_DFAST  = resolve_image("dfast",  config["dfast"]["docker_image"])
IMG_PATRIC = resolve_image("patric", config["patric"]["docker_image"])
IMG_MERGE  = resolve_image("merge",  config["merge"]["docker_image"])
IMG_EGGNOG = resolve_image("eggnog", config["eggnog"]["docker_image"])

DB_BAKTA      = config["bakta"]["db_path"]
BAKTA_GENUS   = config["bakta"].get("genus", "")
BAKTA_SPECIES = config["bakta"].get("species", "")
BAKTA_GRAM    = config["bakta"].get("gram", "?")
BAKTA_TTABLE  = config["bakta"].get("translation_table", 11)

PROKKA_GENUS   = config["prokka"].get("genus", "")
PROKKA_KINGDOM = config["prokka"].get("kingdom", "Bacteria")
PROKKA_GCODE   = config["prokka"].get("gcode", 11)

DB_DFAST    = config["dfast"]["db_path"]
DFAST_GCODE = int(config["dfast"].get("gcode", 11) or 11)

PATRIC_TAXID    = config["patric"]["taxonomy_id"]
PATRIC_DESC     = config["patric"]["description"]
PATRIC_WS       = config["patric"]["workspace_output_dir"]
PATRIC_INTERVAL = int(config["patric"].get("monitor_interval", 60))

# Credentials: read from config.yaml. An external env_file is still accepted,
# and takes precedence, for anyone who prefers to keep the secret out of the
# configuration file.
PATRIC_USER     = config["patric"].get("username", "")
PATRIC_PASS     = config["patric"].get("password", "")
PATRIC_ENV_FILE = config["patric"].get("env_file", "") or ""
if PATRIC_ENV_FILE and not os.path.isabs(PATRIC_ENV_FILE):
    PATRIC_ENV_FILE = os.path.join(SNAKEFILE_DIR, PATRIC_ENV_FILE)

MERGE_MIN_PIDENT = config["merge"].get("min_pident", 95.0)
MERGE_MIN_QCOV   = config["merge"].get("min_qcov", 0.9)
MERGE_JOBS       = config["merge"].get("jobs", 2)

DB_EGGNOG       = config["eggnog"]["db_path"]
EGGNOG_SENSMODE = config["eggnog"].get("sensmode", "diamond")

# =============================================================================
# DIRECTORIES
# =============================================================================
DIR_BAKTA  = os.path.join(OUTPUT_DIR, "bakta_out")
DIR_PROKKA = os.path.join(OUTPUT_DIR, "prokka_out")
DIR_DFAST  = os.path.join(OUTPUT_DIR, "dfast_out")
DIR_PATRIC = os.path.join(OUTPUT_DIR, "patric_out")
DIR_MERGE  = os.path.join(OUTPUT_DIR, "merge_input")
DIR_RESULT = os.path.join(OUTPUT_DIR, "merge_results")
DIR_EGGNOG = os.path.join(OUTPUT_DIR, "eggnog_out")
DIR_PGAP   = os.path.join(OUTPUT_DIR, "pgap_out")
DIR_LOGS   = os.path.join(OUTPUT_DIR, "logs")

for _d in [DIR_BAKTA, DIR_PROKKA, DIR_DFAST, DIR_PATRIC, DIR_MERGE,
           DIR_RESULT, DIR_EGGNOG, DIR_PGAP, DIR_LOGS]:
    ensure_writable_dir(_d)
for _sub in ["bakta", "prokka", "dfast", "patric", "eggnog", "pgap", "merge"]:
    ensure_writable_dir(os.path.join(DIR_LOGS, _sub))

# =============================================================================
# TOOL FLAGS
# =============================================================================
PATRIC_ENABLED = config.get("patric", {}).get("enabled", True)
BAKTA_ENABLED  = config.get("bakta", {}).get("enabled", True)
PROKKA_ENABLED = config.get("prokka", {}).get("enabled", True)
DFAST_ENABLED  = config.get("dfast", {}).get("enabled", True)
PGAP_ENABLED   = config.get("pgap", {}).get("enabled", False)
EGGNOG_ENABLED = config.get("eggnog", {}).get("enabled", True)

if IS_APPTAINER and PGAP_ENABLED:
    raise ValueError(
        "[SnakeMergeAnnotation] container_runtime='apptainer' is incompatible "
        "with pgap.enabled=true: NCBI's own pgap.py script launches Docker "
        "containers internally and has no Apptainer/Singularity mode of its "
        "own. Disable PGAP (pgap.enabled: false) for Apptainer/HPC runs, or "
        "set container_runtime back to 'docker' if PGAP is required."
    )

BASE_TOOL = config.get("base_tool", "patric")

_ENABLED_MAP = {
    "patric": PATRIC_ENABLED,
    "bakta":  BAKTA_ENABLED,
    "prokka": PROKKA_ENABLED,
    "dfast":  DFAST_ENABLED,
    "pgap":   PGAP_ENABLED,
}

if BASE_TOOL not in _ENABLED_MAP:
    raise ValueError(
        f"[SnakeMergeAnnotation] base_tool='{BASE_TOOL}' is not recognized. "
        f"Use one of: {list(_ENABLED_MAP.keys())}"
    )
if not _ENABLED_MAP[BASE_TOOL]:
    enabled_options = [k for k, v in _ENABLED_MAP.items() if v]
    raise ValueError(
        f"[SnakeMergeAnnotation] base_tool='{BASE_TOOL}' is DISABLED. "
        f"Enable '{BASE_TOOL}.enabled' in config.yaml or choose a base_tool "
        f"among the enabled ones: "
        f"{enabled_options if enabled_options else '[NONE]'}."
    )

# =============================================================================
# TOOL ORDER
# =============================================================================
_TOOL_ORDER_RAW = config.get("merge", {}).get("tool_order", None)
VALID_STEPS = {"patric", "bakta", "prokka", "dfast", "pgap", "eggnog"}

enabled_secondary = []
for _t, _flag in [("patric", PATRIC_ENABLED), ("bakta", BAKTA_ENABLED),
                  ("prokka", PROKKA_ENABLED), ("dfast", DFAST_ENABLED),
                  ("pgap", PGAP_ENABLED), ("eggnog", EGGNOG_ENABLED)]:
    if _flag and BASE_TOOL != _t:
        enabled_secondary.append(_t)

if _TOOL_ORDER_RAW:
    order_list = []
    seen = set()
    for item in str(_TOOL_ORDER_RAW).split(","):
        item = item.strip()
        if not item:
            continue
        if item not in VALID_STEPS:
            raise ValueError(
                f"Invalid tool in merge.tool_order: '{item}'. "
                f"Use: {sorted(VALID_STEPS)}"
            )
        if item not in seen:
            seen.add(item)
            order_list.append(item)
    order_list = [t for t in order_list if t in enabled_secondary]
    for t in enabled_secondary:
        if t not in order_list:
            order_list.append(t)
            print(f"[Warning] Tool '{t}' is enabled but was not in "
                  f"merge.tool_order; appended at the end.")
else:
    default_order = ["bakta", "prokka", "dfast", "pgap", "eggnog"]
    order_list = [t for t in default_order if t in enabled_secondary]
    for t in enabled_secondary:
        if t not in order_list:
            order_list.append(t)

TOOL_ORDER = ",".join(order_list)
ORDER_STR = "-".join(order_list)

# FIX: `rule all` used to only request generically-named final targets
# (CURED_PATTERN, with no order/threshold information in the file name).
# Changing merge.tool_order, merge.min_pident, merge.min_qcov or base_tool
# and re-running Snakemake would therefore report "Nothing to be done": the
# fixed-name targets already existed on disk, so run_merge was never
# re-triggered, silently keeping stale results from a previous configuration.
#
# RUN_TAG folds every merge-affecting parameter into the file names that
# run_merge actually produces (and that the merge engine itself receives via
# --run-tag), so a config change changes the target file name and Snakemake
# correctly detects that it must run again. ORDER_STR alone is kept for
# human-readable banners/messages.
_merge_params_sig = hashlib.sha1(
    f"{BASE_TOOL}|{MERGE_MIN_PIDENT}|{MERGE_MIN_QCOV}|{TOOL_ORDER}".encode()
).hexdigest()[:8]
RUN_TAG = f"{ORDER_STR}_{_merge_params_sig}" if ORDER_STR else _merge_params_sig

# =============================================================================
# PGAP
# =============================================================================
PGAP_SCRIPT  = os.path.join(SNAKEFILE_DIR, config.get("pgap", {}).get("script_path", "pgap.py"))
PGAP_MEM     = config.get("pgap", {}).get("mem", "24g")
PGAP_CPUS    = int(config.get("pgap", {}).get("cpus", 8))
PGAP_EXTRA   = config.get("pgap", {}).get("extra_args", "")
PGAP_SPECIES = config.get("pgap", {}).get("species", "")

# =============================================================================
# SAMPLE DETECTION
# =============================================================================
# FIX: sample detection used to accept .fa and .fna, but the rules required
# '{sample}.fasta' — any .fa/.fna would enter SAMPLES and later blow up with
# a MissingInputException. The real path is now remembered.
SAMPLE_FILES = {}


def get_samples():
    for ext in ("*.fasta", "*.fa", "*.fna"):
        for f in sorted(glob.glob(os.path.join(FASTA_DIR, ext))):
            name = os.path.splitext(os.path.basename(f))[0]
            SAMPLE_FILES.setdefault(name, f)
    if not SAMPLE_FILES:
        raise ValueError(
            f"[SnakeMergeAnnotation] No FASTA (.fasta/.fa/.fna) "
            f"found in: {FASTA_DIR}"
        )
    return sorted(SAMPLE_FILES)


SAMPLES = get_samples()


def sample_fasta(wildcards):
    return SAMPLE_FILES[wildcards.sample]


def fasta_basename(sample):
    return os.path.basename(SAMPLE_FILES[sample])


wildcard_constraints:
    sample = "|".join(re.escape(s) for s in SAMPLES)

# =============================================================================
# PARALLELISM
# =============================================================================
MAX_PESADOS_POR_CORES = max(1, TOTAL_CORES // max(1, THREADS // MAX_JOBS))
MAX_PESADOS_POR_MEM   = max(1, MEM_TOTAL // MEM_PER_JOB)
PARALELISMO_PESADO    = max(1, min(MAX_JOBS, MAX_PESADOS_POR_CORES, MAX_PESADOS_POR_MEM))
PARALELISMO_LEVE      = MAX_JOBS * 2

# FIX: heavy_slots/light_slots/mem_mb used to only take effect if passed via
# --resources on the command line. If you forgot, ALL parallelism control
# silently disappeared and several heavy jobs would run side by side — which
# is exactly what causes memory pressure and hangs.
try:
    workflow.global_resources.setdefault("heavy_slots", PARALELISMO_PESADO)
    workflow.global_resources.setdefault("light_slots", PARALELISMO_LEVE)
    workflow.global_resources.setdefault("mem_mb", MEM_TOTAL)
except AttributeError:
    print("[Warning] Could not set default resources on this Snakemake "
          "version. Pass --resources heavy_slots=%d light_slots=%d mem_mb=%d"
          % (PARALELISMO_PESADO, PARALELISMO_LEVE, MEM_TOTAL))

# =============================================================================
# OUTPUT NAMES
# =============================================================================
CURED_PATTERN = "{sample}_cured.gb"

# FIX: 'batch_' + '-'.join(SAMPLES) used to exceed the 255-byte limit per
# path component (ENAMETOOLONG) once a batch passed about 20 genomes.
if len(SAMPLES) == 1:
    RESULT_BATCH_DIR = SAMPLES[0]
else:
    _h = hashlib.sha1(",".join(SAMPLES).encode()).hexdigest()[:10]
    RESULT_BATCH_DIR = f"batch_{len(SAMPLES)}genomes_{_h}"


# =============================================================================
# SUPERVISED CONTAINER EXECUTION
# =============================================================================
def _mount_flag(host, container, mode=None):
    """Builds the `-v` argument, normalizing the host path to the convention
    accepted by Docker on each platform."""
    spec = f"{watchdog.docker_path(host)}:{container}"
    return f"{spec}:{mode}" if mode else spec


def build_docker_cmd(image, args, mounts=(), env=(), mem_mb=None, cpus=None,
                     shm_size=None, entrypoint=None, work_dir=None,
                     extra_flags=()):
    """Builds the argument list for a hardened `docker run`.

    Returns a LIST, never a string: the command is executed directly by
    Python, without going through a shell, so there is no quoting to get
    right and no differences between interpreters across platforms.

    Flags, and the reason for each one:
      --init          A real PID 1 that responds to SIGTERM and reaps
                      zombies. Without it, the kernel drops SIGTERM sent to
                      PID 1 and the container ignores any request to stop.
      --memory +
      --memory-swap   Set equal to each other, which disables swap in the
                      cgroup. The job dies with 137 (and the retry repeats
                      it) instead of thrashing for hours while looking alive.
      --cpus          Prevents a container from using every core, ignoring
                      the `threads` declared on the rule.
      --shm-size      Docker's default is 64 MB, which causes a silent
                      deadlock in tools that use multiprocessing.
    """
    cmd = ["docker", "run", "--rm", "--init"]

    if DOCKER_USER_SPEC:
        cmd += ["-u", DOCKER_USER_SPEC]

    if mem_mb:
        mem_mb = int(mem_mb)
        cmd.append(f"--memory={mem_mb}m")
        if DOCKER_DISABLE_SWAP:
            cmd.append(f"--memory-swap={mem_mb}m")

    if cpus:
        cmd.append(f"--cpus={cpus}")

    cmd.append(f"--shm-size={shm_size or DOCKER_SHM}")
    if DOCKER_LOG_OPTS:
        cmd += ["--log-opt", f"max-size={DOCKER_LOG_MAX}",
                "--log-opt", "max-file=2"]

    for mount in mounts:
        cmd += ["-v", _mount_flag(*mount)]
    for item in env:
        cmd += ["-e", str(item)]
    if work_dir:
        cmd += ["--workdir", work_dir]
    if entrypoint:
        cmd += ["--entrypoint", entrypoint]

    cmd += DOCKER_EXTRA + [str(f) for f in extra_flags]
    cmd.append(str(image))
    cmd += [str(a) for a in args]
    return cmd


def build_apptainer_cmd(image, args, mounts=(), env=(), mem_mb=None, cpus=None,
                        shm_size=None, entrypoint=None, work_dir=None,
                        extra_flags=()):
    """Builds the argument list for an Apptainer invocation.

    Accepts the same keyword arguments as build_docker_cmd so every call
    site in this Snakefile stays identical regardless of which runtime is
    active. mem_mb/cpus/shm_size are intentionally ignored: on Apptainer/HPC
    those ceilings are the job scheduler's job (SLURM, PBS, ...), not the
    container runtime's — Snakemake's own `resources:` block is still what
    controls how many jobs run side by side.

    Uses 'apptainer exec <image> <entrypoint> <args>' when an explicit
    entrypoint is given (mirrors Docker's --entrypoint override), or
    'apptainer run <image> <args>' otherwise. The latter invokes the
    runscript Apptainer synthesizes from the source image's own Docker
    ENTRYPOINT/CMD when converting a docker:// or .sif built from one —
    verified to reproduce `docker run image args...` byte-for-byte for an
    ENTRYPOINT-only image (e.g. the merge image used by run_merge).

    There is no daemon and no named container under Apptainer: the apptainer
    process itself is the job, so it is supervised as a plain subprocess
    (mode='process' in docker_watchdog.supervise), the same way pgap.py
    already is.
    """
    action = "exec" if entrypoint else "run"
    cmd = ["apptainer", action]

    for mount in mounts:
        cmd += ["--bind", _mount_flag(*mount)]
    for item in env:
        cmd += ["--env", str(item)]
    if work_dir:
        cmd += ["--pwd", work_dir]

    cmd += APPTAINER_EXTRA + [str(f) for f in extra_flags]
    cmd.append(str(image))
    if entrypoint:
        cmd.append(str(entrypoint))
    cmd += [str(a) for a in args]
    return cmd


def build_container_cmd(image, args, **kwargs):
    """Dispatches to the active container runtime. Every rule in this
    Snakefile calls run_docker() the same way regardless of whether
    container_runtime is 'docker' or 'apptainer'."""
    if IS_APPTAINER:
        return build_apptainer_cmd(image, args, **kwargs)
    return build_docker_cmd(image, args, **kwargs)


def _container_name(rule_name, tag):
    """Unique name per attempt.

    The PID alone is not enough: `run:` blocks execute in Snakemake's main
    process, so a retry of the same rule for the same sample would reuse the
    exact same name. If the previous container still existed, `docker run
    --name` would fail with 125 ("name already in use") and the retry would
    never get a chance to succeed.
    """
    unique = uuid.uuid4().hex[:8]
    return (f"smerge_{sanitize_prefix(rule_name)}_{sanitize_prefix(str(tag))}"
            f"_{unique}")


def _printable(cmd):
    """Renders the argument list as a copyable line. This is for diagnostics
    only; the actual execution never goes through a shell."""
    if IS_WINDOWS:
        return subprocess.list2cmdline(cmd)
    return shlex.join(str(c) for c in cmd)


def run_docker(rule_name, tag, image, args, logfile, watch=(), **kwargs):
    """Runs a tool container under inactivity supervision and fails with a
    useful message if something goes wrong. The active container runtime
    (Docker or Apptainer, selected via container_runtime in config.yaml) is
    resolved here; callers never need to know which one is in use."""
    cmd = build_container_cmd(image, args, **kwargs)
    settings = wd_args(rule_name)
    if IS_APPTAINER:
        # No daemon and no named containers under Apptainer: `docker stats`
        # has no equivalent, so cpu_threshold (which only means something
        # when that polling is available) is dropped, and the apptainer
        # process is supervised like any other subprocess — the same
        # mode already used for pgap.py.
        settings.pop("cpu_threshold", None)
        code = watchdog.supervise(
            cmd=cmd,
            log_path=logfile,
            mode="process",
            watch=[w for w in watch if w],
            **settings,
        )
    else:
        code = watchdog.supervise(
            cmd=cmd,
            log_path=logfile,
            mode="docker",
            container_name=_container_name(rule_name, tag),
            watch=[w for w in watch if w],
            **settings,
        )
    if code != 0:
        raise RuntimeError(
            watchdog.explain_exit_code(code, logfile, rule_name)
            + "\n\n  Command executed (copy and paste to reproduce):\n  "
            + _printable(watchdog.redact_cmd(cmd)))
    return code


def run_process(rule_name, cmd, logfile, watch=()):
    """Same supervision, for commands that are not `docker run` directly —
    the case of pgap.py, which launches its own containers internally."""
    settings = wd_args(rule_name)
    settings.pop("cpu_threshold", None)
    code = watchdog.supervise(
        cmd=cmd,
        log_path=logfile,
        mode="process",
        watch=[w for w in watch if w],
        **settings,
    )
    if code != 0:
        raise RuntimeError(
            watchdog.explain_exit_code(code, logfile, rule_name))
    return code


def rule_mem_base(rule_name):
    """Base ceiling for the rule: config override, or the default division."""
    if rule_name and rule_name in MEM_PER_RULE:
        return max(1024, mem_to_mb(MEM_PER_RULE[rule_name]))
    return MEM_PER_JOB


def mem_for(attempt, rule_name=None, ceiling=None):
    """Increasing memory per attempt: if the job died from lack of memory,
    retrying with the same ceiling would only repeat the failure."""
    base = rule_mem_base(rule_name)
    ceiling = ceiling or MEM_TOTAL
    return int(min(ceiling, base * attempt))


# =============================================================================
# BANNER AND MESSAGES
# =============================================================================
onstart:
    print("=" * 74)
    print(f"[SnakeMergeAnnotation] Platform: {platform.system()} "
          f"({platform.machine()}), {TOTAL_CORES} core(s)")
    print(f"[SnakeMergeAnnotation] {len(SAMPLES)} genome(s) detected")
    print(f"[SnakeMergeAnnotation] base_tool: {BASE_TOOL}")
    print(f"[SnakeMergeAnnotation] Tool order: {TOOL_ORDER or '(no secondary tool)'}")
    print(f"[SnakeMergeAnnotation] Container runtime: {CONTAINER_RUNTIME}")
    print(f"[SnakeMergeAnnotation] Parallelism: heavy_slots={PARALELISMO_PESADO} "
          f"light_slots={PARALELISMO_LEVE}")
    print(f"[SnakeMergeAnnotation] Memory per heavy job: {MEM_PER_JOB} MB "
          f"(ceiling {MEM_TOTAL} MB)")
    if IS_APPTAINER:
        print("[SnakeMergeAnnotation] User mapping: n/a (Apptainer runs as "
              "the invoking user by default)")
    else:
        print(f"[SnakeMergeAnnotation] User mapping: "
              f"{DOCKER_USER_SPEC or 'disabled (Docker Desktop handles this)'}")
    print("[SnakeMergeAnnotation] Watchdog: stops on INACTIVITY, not on total "
          "runtime. Slow but active tools are never interrupted.")
    print("=" * 74)


onerror:
    print("=" * 74)
    print("[SnakeMergeAnnotation] The pipeline failed.")
    print(f"Tool logs:     {os.path.join(DIR_LOGS, '<rule>', '<sample>.log')}")
    print(f"Watchdog logs: same path with a .watchdog suffix")
    print("")
    print("Exit codes recorded by the watchdog:")
    print("    1 -> the tool ran and failed on its own. The cause is in the")
    print("         tool's log, not a resource limit.")
    print("  124 -> stopped due to INACTIVITY. If the tool really was still")
    print("         working, increase watchdog.per_rule.<rule>.inactivity_timeout")
    print("  123 -> exceeded the absolute ceiling (watchdog.per_rule.<rule>.max_runtime)")
    print("  125 -> `docker run` was refused by the daemon; the tool never started")
    print("  137 -> OOM kill. Increase resources.mem_mb or resources.per_rule.<rule>")
    print("  143 -> SIGTERM (Ctrl-C or shutdown after another rule failed)")
    print("=" * 74)


onsuccess:
    print("=" * 74)
    print("[SnakeMergeAnnotation] Pipeline completed successfully.")
    print(f"Results: {DIR_RESULT}")
    print("=" * 74)


# =============================================================================
# PER-TOOL PATHS
# =============================================================================
def get_base_file_path(sample, tool):
    if tool == "patric":
        return os.path.join(DIR_PATRIC, f"{sample}_patric.gb")
    if tool == "bakta":
        return os.path.join(DIR_BAKTA, sample, f"{sample}_bakta.gbff")
    if tool == "prokka":
        return os.path.join(DIR_PROKKA, f"{sample}_prokka", f"{sample}_prokka.gbk")
    if tool == "dfast":
        return os.path.join(DIR_DFAST, f"{sample}_dfast.gbk")
    if tool == "pgap":
        return os.path.join(DIR_PGAP, sample, f"{sample}_pgap.gbk")
    raise ValueError(f"Unknown tool: {tool}")


def active_annotation_tools():
    """Base tool first, then the enabled secondary tools (except eggnog,
    which does not produce a GenBank file)."""
    tools = [BASE_TOOL]
    for t in ("patric", "bakta", "prokka", "dfast", "pgap"):
        if _ENABLED_MAP.get(t) and t != BASE_TOOL:
            tools.append(t)
    return tools


def get_merge_inputs(wildcards):
    return [get_base_file_path(wildcards.sample, t) for t in active_annotation_tools()]


def merge_copy_targets():
    """Copies that prepare_merge_input places in merge_input/.

    FIX: these copies used to be UNDECLARED outputs — the rule only declared
    the signal file. This left Snakemake blind to truncated copies and made
    --rerun-incomplete useless at this step."""
    return [
        os.path.join(DIR_MERGE, os.path.basename(get_base_file_path("{sample}", t)))
        for t in active_annotation_tools()
    ]


# =============================================================================
# FINAL RULE
# =============================================================================
rule all:
    input:
        expand(os.path.join(DIR_PATRIC, "{sample}_patric.gb"), sample=SAMPLES) if PATRIC_ENABLED else [],
        expand(os.path.join(DIR_BAKTA, "{sample}", "{sample}_bakta.gbff"), sample=SAMPLES) if BAKTA_ENABLED else [],
        expand(os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk"), sample=SAMPLES) if PROKKA_ENABLED else [],
        expand(os.path.join(DIR_DFAST, "{sample}_dfast.gbk"), sample=SAMPLES) if DFAST_ENABLED else [],
        expand(os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk"), sample=SAMPLES) if PGAP_ENABLED else [],
        # RUN_TAG-named targets: explicitly requesting these (rather than
        # only the generic CURED_PATTERN below) is what makes Snakemake
        # notice a change in merge.tool_order/min_pident/min_qcov/base_tool
        # and re-run run_merge instead of reusing a stale result. See the
        # comment at RUN_TAG's definition above.
        os.path.join(DIR_MERGE, f"hp_summary_report__{RUN_TAG}.tsv"),
        os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"hp_reduction_plot__{RUN_TAG}.png"),
        os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"article_ready_table__{RUN_TAG}.csv"),
        expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES),
        expand(os.path.join(DIR_RESULT, "{sample}", "{sample}_cured.gb"), sample=SAMPLES)


# =============================================================================
# BAKTA
# =============================================================================
rule annotate_bakta:
    input:
        fasta = sample_fasta
    output:
        gbff = os.path.join(DIR_BAKTA, "{sample}", "{sample}_bakta.gbff")
    params:
        outdir = os.path.join(DIR_BAKTA, "{sample}")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = lambda wc, attempt: mem_for(attempt, "annotate_bakta"),
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "bakta", "{sample}.log")
    run:
        ensure_writable_dir(params.outdir)
        ensure_writable_dir(os.path.dirname(log[0]))

        args = [
            "--db", "/db",
            "--output", "/output",
            "--prefix", f"{wildcards.sample}_bakta",
            "--threads", threads,
            "--translation-table", BAKTA_TTABLE,
            "--force",
        ]
        if BAKTA_GENUS:
            args += ["--genus", BAKTA_GENUS]
        if BAKTA_SPECIES:
            args += ["--species", BAKTA_SPECIES]
        if BAKTA_GRAM and BAKTA_GRAM != "?":
            args += ["--gram", BAKTA_GRAM]
        args.append(f"/input/{fasta_basename(wildcards.sample)}")

        run_docker(
            rule_name="annotate_bakta",
            tag=wildcards.sample,
            image=IMG_BAKTA,
            args=args,
            logfile=log[0],
            mounts=[(FASTA_DIR, "/input", "ro"),
                    (DB_BAKTA, "/db", "ro"),
                    (params.outdir, "/output")],
            mem_mb=resources.mem_mb,
            cpus=threads,
            watch=[params.outdir],
        )

        verify_output(output.gbff, "bakta", wildcards.sample,
                      search_dir=params.outdir,
                      patterns=["*_bakta.gbff", "*.gbff"])


# =============================================================================
# PROKKA
# =============================================================================
rule annotate_prokka:
    input:
        fasta = sample_fasta
    output:
        gbk = os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk")
    params:
        outdir = os.path.join(DIR_PROKKA, "{sample}_prokka")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = lambda wc, attempt: mem_for(attempt, "annotate_prokka"),
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "prokka", "{sample}.log")
    run:
        ensure_writable_dir(DIR_PROKKA)
        ensure_writable_dir(os.path.dirname(log[0]))

        args = [
            "prokka",
            "--outdir", f"/output/{wildcards.sample}_prokka",
            "--prefix", f"{wildcards.sample}_prokka",
            "--kingdom", PROKKA_KINGDOM,
            "--gcode", PROKKA_GCODE,
            "--cpus", threads,
            "--force",
        ]
        if PROKKA_GENUS:
            args += ["--genus", PROKKA_GENUS]
        args.append(f"/input/{fasta_basename(wildcards.sample)}")

        run_docker(
            rule_name="annotate_prokka",
            tag=wildcards.sample,
            image=IMG_PROKKA,
            args=args,
            logfile=log[0],
            mounts=[(FASTA_DIR, "/input", "ro"),
                    (DIR_PROKKA, "/output")],
            env=["HOME=/tmp"],
            mem_mb=resources.mem_mb,
            cpus=threads,
            watch=[params.outdir],
        )

        verify_output(output.gbk, "prokka", wildcards.sample,
                      search_dir=params.outdir,
                      patterns=["*_prokka.gbk", "*.gbk"])


# =============================================================================
# DFAST
# =============================================================================
rule annotate_dfast:
    input:
        fasta = sample_fasta
    output:
        gbk = os.path.join(DIR_DFAST, "{sample}_dfast.gbk")
    params:
        tmpdir = os.path.join(OUTPUT_DIR, "dfast_tmp")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = lambda wc, attempt: mem_for(attempt, "annotate_dfast"),
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "dfast", "{sample}.log")
    run:
        ensure_writable_dir(params.tmpdir)
        ensure_writable_dir(DIR_DFAST)
        ensure_writable_dir(os.path.dirname(log[0]))
        outdir = ensure_writable_dir(
            os.path.join(params.tmpdir, wildcards.sample + "_dfast"))

        try:
            run_docker(
                rule_name="annotate_dfast",
                tag=wildcards.sample,
                image=IMG_DFAST,
                args=[
                    "--genome", f"/input/{fasta_basename(wildcards.sample)}",
                    "--out", f"/output/{wildcards.sample}_dfast",
                    "--cpu", threads,
                    "--gcode", DFAST_GCODE,
                    "--force",
                ],
                logfile=log[0],
                mounts=[(FASTA_DIR, "/input", "ro"),
                        (params.tmpdir, "/output"),
                        (DB_DFAST, "/dfast_core/db", "ro")],
                entrypoint="dfast",
                mem_mb=resources.mem_mb,
                cpus=threads,
                watch=[outdir],
            )

            found = glob.glob(os.path.join(outdir, "**", "genome.gbk"), recursive=True)
            found = [f for f in found if os.path.getsize(f) > 0]
            if not found:
                raise RuntimeError(
                    f"[dfast] 'genome.gbk' not found in {outdir} "
                    f"for sample '{wildcards.sample}'."
                )
            shutil.copy(sorted(found, key=lambda p: p.count(os.sep))[0], output.gbk)
        finally:
            # Clean up even on failure, so the retry starts fresh.
            shutil.rmtree(outdir, ignore_errors=True)

        verify_output(output.gbk, "dfast", wildcards.sample)


# =============================================================================
# PATRIC / BV-BRC
# =============================================================================
rule annotate_patric:
    input:
        fasta = sample_fasta
    output:
        gb = os.path.join(DIR_PATRIC, "{sample}_patric.gb")
    params:
        jobs_dir = os.path.join(OUTPUT_DIR, "patric_jobs")
    threads: 1
    resources:
        mem_mb = lambda wc, attempt: min(MEM_TOTAL, 4096 * attempt),
        light_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "patric", "{sample}.log")
    run:
        import textwrap

        # Credentials come from config.yaml. What must NOT happen — and used
        # to happen — is the password leaking into the logs: the generated
        # script used 'set -euxo pipefail', and the '-x' echoed the
        # p3-login line with the password expanded, straight into
        # logs/patric/<sample>.log, one file per sample.
        #
        # Here the password never appears in the script, nor in the docker
        # command line (which the watchdog records in the log). It is
        # written to a temporary env-file with 600 permissions, read
        # directly by Docker, and deleted at the end even on failure.
        if PATRIC_ENV_FILE:
            if not os.path.exists(PATRIC_ENV_FILE):
                raise FileNotFoundError(
                    f"[patric] env_file configured but does not exist: "
                    f"{PATRIC_ENV_FILE}\n"
                    f"Remove the 'patric.env_file' key from config.yaml to use "
                    f"'username'/'password' instead, or create the file."
                )
            env_file = PATRIC_ENV_FILE
            temp_env = None
        else:
            if not PATRIC_USER or not PATRIC_PASS:
                raise ValueError(
                    "[patric] Missing credentials. Set 'username' and "
                    "'password' in the 'patric' section of config.yaml."
                )
            temp_env = None  # created below, after the directory is ensured

        ensure_writable_dir(params.jobs_dir, mode=0o700)
        ensure_writable_dir(DIR_PATRIC)
        ensure_writable_dir(os.path.dirname(log[0]))

        if not PATRIC_ENV_FILE:
            temp_env = os.path.join(
                params.jobs_dir, f".patric_env_{wildcards.sample}")
            # Created with 0600 from the start, with no window in which the
            # file exists with broad permissions.
            flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
            fd = os.open(temp_env, flags, 0o600)
            try:
                with os.fdopen(fd, "w", newline="\n") as handle:
                    handle.write(f"PATRIC_USER={PATRIC_USER}\n")
                    handle.write(f"PATRIC_PASS={PATRIC_PASS}\n")
            except Exception:
                os.close(fd) if not os.path.exists(temp_env) else None
                raise
            env_file = temp_env

        if not IS_WINDOWS and os.path.exists(env_file) \
                and (os.stat(env_file).st_mode & 0o077):
            print(f"[patric] WARNING: {env_file} is readable by other "
                  f"users on the system.")

        ensure_writable_dir(params.jobs_dir, mode=0o700)
        ensure_writable_dir(DIR_PATRIC)
        ensure_writable_dir(os.path.dirname(log[0]))

        # This script is bash, but it runs INSIDE the Linux container —
        # never on the host. That separation is exactly what keeps the
        # pipeline cross-platform.
        inner = os.path.join(params.jobs_dir, f"patric_{wildcards.sample}.sh")
        with open(inner, "w", newline="\n") as f:
            f.write(textwrap.dedent(f"""\
                #!/bin/bash
                # NOTE: no 'x' in set -euo pipefail. With -x, bash would echo
                # the p3-login line with the password expanded straight into
                # the log.
                set -euo pipefail

                gname="{wildcards.sample}"
                fasta="/input/{fasta_basename(wildcards.sample)}"
                TAXID="{PATRIC_TAXID}"
                DESC="{PATRIC_DESC}"
                WS_OUT="{PATRIC_WS}"
                STATE="/jobs/$gname.submitted"

                : "${{PATRIC_USER:?PATRIC_USER not set in the env-file}}"
                : "${{PATRIC_PASS:?PATRIC_PASS not set in the env-file}}"

                login_output=$(p3-login "$PATRIC_USER" "$PATRIC_PASS")
                USER_EMAIL=$(echo "$login_output" | grep -oP '(?<=Logged in with username ).*')
                echo "Authenticated as: $USER_EMAIL"

                REMOTE="/$USER_EMAIL/$WS_OUT/.$gname/$gname.gb"

                # IDEMPOTENCY: if the result already exists in the workspace,
                # do not resubmit. Previously, a retry would create a
                # DUPLICATE job on the server while the earlier one was
                # still running.
                if p3-ls "$REMOTE" >/dev/null 2>&1; then
                    echo "Result already exists in the workspace; skipping submission."
                elif [ -f "$STATE" ]; then
                    echo "Previous submission detected (job $(cat "$STATE")); monitoring only."
                else
                    out=$(p3-submit-genome-annotation -f \\
                        --contigs-file "$fasta" \\
                        -t "$TAXID" \\
                        -d "$DESC" \\
                        "/$USER_EMAIL/$WS_OUT" "$gname")
                    echo "$out"
                    sid=$(echo "$out" | grep -oP '(?<=Submitted annotation with id )\\d+' || echo "unknown")
                    echo "$sid" > "$STATE"
                    echo "Job submitted: $sid"
                fi

                # Monitoring. The periodic 'echo' is deliberate: it keeps the
                # log growing so the watchdog recognizes the wait as active,
                # instead of interpreting silence as a hang.
                waited=0
                while true; do
                    if p3-ls -l --type "/$USER_EMAIL/$WS_OUT/$gname" 2>/dev/null | grep -q "job_result"; then
                        echo "Annotation completed: $gname (after ${{waited}}s)"
                        break
                    fi
                    echo "Waiting for remote completion: $gname (${{waited}}s elapsed)"
                    sleep {PATRIC_INTERVAL}
                    waited=$((waited + {PATRIC_INTERVAL}))
                done

                p3-login "$PATRIC_USER" "$PATRIC_PASS" > /dev/null 2>&1
                p3-cp ws:"$REMOTE" "/output/${{gname}}_patric.gb"
                p3-logout
                rm -f "$STATE"
            """))
        if not IS_WINDOWS:
            os.chmod(inner, 0o700)

        try:
            run_docker(
                rule_name="annotate_patric",
                tag=wildcards.sample,
                image=IMG_PATRIC,
                args=["bash", f"/jobs/patric_{wildcards.sample}.sh"],
                logfile=log[0],
                mounts=[(FASTA_DIR, "/input", "ro"),
                        (DIR_PATRIC, "/output"),
                        (params.jobs_dir, "/jobs")],
                env=["HOME=/jobs"],
                mem_mb=resources.mem_mb,
                cpus=1,
                extra_flags=["--env-file", watchdog.docker_path(env_file)],
                watch=[DIR_PATRIC],
            )
        finally:
            # The temporary env-file never survives the job, even if it fails.
            if temp_env and os.path.exists(temp_env):
                try:
                    os.remove(temp_env)
                except OSError:
                    pass

        verify_output(output.gb, "patric", wildcards.sample)


# =============================================================================
# MERGE INPUT PREPARATION
# =============================================================================
rule prepare_merge_input:
    input:
        get_merge_inputs
    output:
        copies = merge_copy_targets(),
        signal = os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}")
    resources:
        light_slots = 1
    retries: MAX_RETRIES
    run:
        ensure_writable_dir(DIR_MERGE)
        for src, dst in zip(input, output.copies):
            if not os.path.exists(src) or os.path.getsize(src) == 0:
                raise FileNotFoundError(
                    f"[prepare_merge_input] Missing or empty input: {src}")
            shutil.copy2(src, dst)
        with open(output.signal, "w") as handle:
            handle.write("ok\n")


# =============================================================================
# EGGNOG
# =============================================================================
if EGGNOG_ENABLED:

    rule extract_cds:
        input:
            base_file   = lambda wc: get_base_file_path(wc.sample, BASE_TOOL),
            merge_ready = os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}")
        output:
            faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
        resources:
            mem_mb = lambda wc, attempt: min(MEM_TOTAL, 4096 * attempt),
            light_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "eggnog", "{sample}_extract.log")
        run:
            ensure_writable_dir(DIR_EGGNOG)
            ensure_writable_dir(os.path.dirname(log[0]))

            run_docker(
                rule_name="extract_cds",
                tag=wildcards.sample,
                image=IMG_MERGE,
                args=[
                    "/app/cds_extract.py",
                    f"/data/{os.path.basename(input.base_file)}",
                    f"/output/{wildcards.sample}_proteins.fasta",
                ],
                logfile=log[0],
                mounts=[(DIR_MERGE, "/data", "ro"),
                        (DIR_EGGNOG, "/output")],
                entrypoint="python",
                env=["PYTHONUNBUFFERED=1"],
                mem_mb=resources.mem_mb,
                cpus=1,
                watch=[DIR_EGGNOG],
            )

            verify_output(output.faa, "extract_cds", wildcards.sample)

    rule run_eggnog:
        input:
            faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
        output:
            annotations = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")
        threads: max(1, THREADS // MAX_JOBS)
        resources:
            mem_mb = lambda wc, attempt: mem_for(attempt, "run_eggnog"),
            heavy_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "eggnog", "{sample}_eggnog.log")
        run:
            import tempfile

            ensure_writable_dir(DIR_EGGNOG)
            ensure_writable_dir(os.path.dirname(log[0]))
            temp_dir = tempfile.mkdtemp(prefix=f"eggnog_{wildcards.sample}_",
                                        dir=DIR_EGGNOG)
            try:
                if not IS_WINDOWS:
                    os.chmod(temp_dir, DIR_MODE)
                run_docker(
                    rule_name="run_eggnog",
                    tag=wildcards.sample,
                    image=IMG_EGGNOG,
                    args=[
                        "emapper.py",
                        "-i", f"/data/{wildcards.sample}_proteins.fasta",
                        "--itype", "proteins",
                        "-m", EGGNOG_SENSMODE,
                        "--data_dir", "/eggnog_db",
                        "--output", f"{wildcards.sample}_eggnog",
                        "--output_dir", "/data",
                        "--cpu", threads,
                        "--override",
                        "--temp_dir", "/tmp",
                    ],
                    logfile=log[0],
                    mounts=[(DIR_EGGNOG, "/data", "rw"),
                            (DB_EGGNOG, "/eggnog_db", "ro"),
                            (temp_dir, "/tmp", "rw")],
                    env=["TMPDIR=/tmp", "TEMP=/tmp", "TMP=/tmp",
                         "PYTHONUNBUFFERED=1"],
                    work_dir="/data",
                    mem_mb=resources.mem_mb,
                    cpus=threads,
                    shm_size="4g",
                    # diamond spends hours writing to /tmp without emitting
                    # anything on stdout. Watching temp_dir is what stops the
                    # watchdog from mistaking silence for a hang.
                    watch=[temp_dir],
                )
                verify_output(output.annotations, "eggnog", wildcards.sample)
            finally:
                shutil.rmtree(temp_dir, ignore_errors=True)

    rule move_eggnog_result:
        input:
            eggnog = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")
        output:
            eggnog = os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations")
        resources:
            light_slots = 1
        retries: MAX_RETRIES
        run:
            ensure_writable_dir(os.path.dirname(output.eggnog))
            shutil.copy2(input.eggnog, output.eggnog)


# =============================================================================
# PGAP
# =============================================================================
if PGAP_ENABLED:

    rule download_pgap_script:
        output:
            script = PGAP_SCRIPT
        params:
            url = "https://raw.githubusercontent.com/ncbi/pgap/prod/scripts/pgap.py"
        log:
            os.path.join(DIR_LOGS, "pgap", "download.log")
        retries: 2
        run:
            # urllib instead of curl: curl is not guaranteed on every
            # platform, and urllib already ships with Python.
            ensure_writable_dir(os.path.dirname(output.script))
            ensure_writable_dir(os.path.dirname(log[0]))
            with open(log[0], "w") as logfile:
                logfile.write(f"Downloading {params.url}\n")
                try:
                    with urllib.request.urlopen(params.url, timeout=300) as response:
                        payload = response.read()
                except (urllib.error.URLError, OSError) as exc:
                    logfile.write(f"ERROR: {exc}\n")
                    raise RuntimeError(
                        f"[pgap] Failed to download pgap.py: {exc}")
                with open(output.script, "wb") as handle:
                    handle.write(payload)
                logfile.write(f"Wrote {len(payload)} bytes to {output.script}\n")
            if not IS_WINDOWS:
                os.chmod(output.script, 0o755)
            verify_output(output.script, "pgap_download", "script")

    rule annotate_pgap:
        input:
            fasta  = sample_fasta,
            script = PGAP_SCRIPT
        output:
            gbk = os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk")
        params:
            outdir  = os.path.join(DIR_PGAP, "{sample}"),
            mem     = PGAP_MEM,
            cpus    = PGAP_CPUS,
            extra   = PGAP_EXTRA,
            species = PGAP_SPECIES if PGAP_SPECIES else "{sample}"
        threads: PGAP_CPUS
        resources:
            mem_mb = lambda wc, attempt: min(MEM_TOTAL, mem_to_mb(PGAP_MEM) * attempt),
            heavy_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "pgap", "{sample}.log")
        run:
            safe_prefix = sanitize_prefix(wildcards.sample)
            ensure_writable_dir(os.path.dirname(params.outdir))
            ensure_writable_dir(os.path.dirname(log[0]))

            if os.path.exists(params.outdir):
                shutil.rmtree(params.outdir, ignore_errors=True)

            cmd = [
                sys.executable, input.script,
                "-r", "-v",
                "-o", params.outdir,
                "--prefix", safe_prefix,
                "-c", str(params.cpus),
                "-m", str(params.mem),
                "-g", input.fasta,
                "-s", str(params.species),
                "--no-self-update",
            ]
            if params.extra:
                # shlex.split is portable (does POSIX string parsing without
                # invoking any shell).
                cmd.extend(shlex.split(str(params.extra)))

            # pgap.py launches its own containers, so it cannot be wrapped in
            # `docker run`. The watchdog's 'process' mode creates its own
            # process group so it can terminate the whole tree, avoiding
            # orphaned child containers if the job needs to be killed.
            run_process(
                rule_name="annotate_pgap",
                cmd=cmd,
                logfile=log[0],
                watch=[params.outdir],
            )

            expected = os.path.join(params.outdir, f"{safe_prefix}.gbk")
            if os.path.exists(expected) and os.path.getsize(expected) > 0:
                src = expected
            else:
                found = []
                for pat in ("*.gbff", "*.gbk", "*.gbf", "*.gb", "*.gff"):
                    found.extend(glob.glob(
                        os.path.join(params.outdir, "**", pat), recursive=True))
                found = [f for f in found if os.path.getsize(f) > 0]
                if not found:
                    raise RuntimeError(
                        f"[pgap] No annotation file found in "
                        f"{params.outdir} for '{wildcards.sample}'."
                    )
                src = sorted(found, key=lambda p: p.count(os.sep))[0]

            shutil.copy2(src, output.gbk)
            verify_output(output.gbk, "pgap", wildcards.sample)


# =============================================================================
# MERGE
# =============================================================================
def run_merge_inputs():
    items = []
    for target in merge_copy_targets():
        items.extend(expand(target, sample=SAMPLES))
    items.extend(expand(
        os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}"), sample=SAMPLES))
    if EGGNOG_ENABLED:
        items.extend(expand(
            os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations"),
            sample=SAMPLES))
    return items


rule run_merge:
    input:
        run_merge_inputs()
    output:
        report    = os.path.join(DIR_MERGE, f"hp_summary_report__{RUN_TAG}.tsv"),
        hp_plot   = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"hp_reduction_plot__{RUN_TAG}.png"),
        art_table = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"article_ready_table__{RUN_TAG}.csv"),
        cured     = expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES)
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = lambda wc, attempt: mem_for(attempt, "run_merge"),
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "merge", "pipeline.log")
    run:
        ensure_writable_dir(DIR_RESULT)
        ensure_writable_dir(os.path.join(DIR_RESULT, RESULT_BATCH_DIR))
        ensure_writable_dir(os.path.dirname(log[0]))

        args = [
            "-i", "/data",
            "-o", "/results",
            "-t", threads,
            "--min-pident", MERGE_MIN_PIDENT,
            "--min-qcov", MERGE_MIN_QCOV,
            "--jobs", MERGE_JOBS,
        ]
        if not PATRIC_ENABLED: args.append("--no-patric")
        if not BAKTA_ENABLED:  args.append("--no-bakta")
        if not PROKKA_ENABLED: args.append("--no-prokka")
        if not DFAST_ENABLED:  args.append("--no-dfast")
        if not PGAP_ENABLED:   args.append("--no-pgap")
        if not EGGNOG_ENABLED: args.append("--no-eggnog")
        args += ["--base-tool", BASE_TOOL]
        if TOOL_ORDER:
            args += ["--tool-order", TOOL_ORDER]
        # RUN_TAG (not just the tool order) namespaces every file the merge
        # engine writes, so a change in min_pident/min_qcov/base_tool also
        # produces a distinctly-named result instead of overwriting the
        # previous configuration's output.
        args += ["--run-tag", RUN_TAG]

        run_docker(
            rule_name="run_merge",
            tag="batch",
            image=IMG_MERGE,
            args=args,
            logfile=log[0],
            mounts=[(DIR_MERGE, "/data"), (DIR_RESULT, "/results")],
            env=["PYTHONUNBUFFERED=1"],
            mem_mb=resources.mem_mb,
            cpus=threads,
            watch=[DIR_RESULT],
        )

        # --------------------------------------------------------------------
        # Flexible resolution of output names
        # --------------------------------------------------------------------
        def _shallowest(paths):
            return sorted(paths, key=lambda p: p.count(os.sep))

        def resolve_output(out_file, possible_names, search_dir=None):
            if search_dir is None:
                search_dir = os.path.dirname(out_file)
            ensure_writable_dir(os.path.dirname(out_file))

            for name in possible_names:
                matches = glob.glob(os.path.join(search_dir, "**", name),
                                    recursive=True)
                matches = [m for m in matches if os.path.getsize(m) > 0]
                if matches:
                    found = _shallowest(matches)[0]
                    if os.path.abspath(found) != os.path.abspath(out_file):
                        shutil.move(found, out_file)
                        print(f"[run_merge] '{found}' -> '{out_file}'")
                    return

            base = os.path.basename(out_file)
            if "__" in base:
                pattern = base.split("__")[0] + "*" + os.path.splitext(base)[1]
            else:
                pattern = base
            matches = glob.glob(os.path.join(search_dir, "**", pattern),
                                recursive=True)
            matches = [m for m in matches if os.path.getsize(m) > 0]
            if matches:
                m = _shallowest(matches)[0]
                shutil.move(m, out_file)
                print(f"[run_merge] pattern '{pattern}': '{m}' -> '{out_file}'")
                return

            if os.path.exists(search_dir):
                listing = "\n".join(sorted(
                    os.path.relpath(os.path.join(root, f), search_dir)
                    for root, _, files in os.walk(search_dir) for f in files
                )) or "(empty directory)"
            else:
                listing = "directory does not exist"
            raise RuntimeError(
                f"[run_merge] Output not found for {out_file}. "
                f"Looked in '{search_dir}': {possible_names} and '{pattern}'.\n"
                f"Contents:\n{listing}"
            )

        for out_file, (names, sdir) in {
            output.report: (
                ["hp_summary_report.tsv", f"hp_summary_report__{RUN_TAG}.tsv"],
                None),
            output.hp_plot: (
                ["hp_reduction_plot.png", f"hp_reduction_plot__{RUN_TAG}.png"],
                DIR_RESULT),
            output.art_table: (
                ["article_ready_table.csv", f"article_ready_table__{RUN_TAG}.csv"],
                DIR_RESULT),
        }.items():
            resolve_output(out_file, names, search_dir=sdir)

        for sample, cured_out in zip(SAMPLES, output.cured):
            resolve_output(cured_out, [
                f"{sample}_cured.gb",
                f"{sample}_cured__{RUN_TAG}.gb",
            ])

        # Archive loose raw folders left behind by the merge container.
        for entry in os.listdir(DIR_RESULT):
            entry_path = os.path.join(DIR_RESULT, entry)
            if (entry == RESULT_BATCH_DIR or entry in SAMPLES
                    or not os.path.isdir(entry_path)):
                continue
            if entry.startswith("order__"):
                dest = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, entry)
                if os.path.exists(dest):
                    shutil.rmtree(dest, ignore_errors=True)
                shutil.move(entry_path, dest)
                print(f"[run_merge] Raw folder archived to '{dest}'")


rule copy_cured_results:
    input:
        cured = os.path.join(DIR_MERGE, CURED_PATTERN)
    output:
        result_cured = os.path.join(DIR_RESULT, "{sample}", "{sample}_cured.gb")
    resources:
        light_slots = 1
    retries: MAX_RETRIES
    run:
        ensure_writable_dir(os.path.dirname(output.result_cured))
        shutil.copy2(input.cured, output.result_cured)


# move_eggnog_result is only listed here when eggNOG is enabled: it is a
# conditionally-defined rule (see "if EGGNOG_ENABLED:" above), and Snakemake
# warns if localrules references a rule name that was never declared.
if EGGNOG_ENABLED:
    localrules: all, prepare_merge_input, copy_cured_results, move_eggnog_result
else:
    localrules: all, prepare_merge_input, copy_cured_results

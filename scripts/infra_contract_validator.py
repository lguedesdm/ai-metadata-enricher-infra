#!/usr/bin/env python3
"""
Infrastructure Contract Validator
==================================
Validates Infrastructure-as-Code files against the canonical architecture contract.

Supported IaC file types: *.bicep, *.tf, *.yaml, *.json

Exit codes:
  0  — No violations (PASS)
  1  — Violations detected (ARCHITECTURE_DRIFT_DETECTED)
  2  — Contract load failure
"""

import sys
import os
import re
import glob as glob_module

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT_PATH = os.path.join(REPO_ROOT, "architecture", "runtime_architecture_contract.yaml")

# Directories to exclude from IaC scanning
EXCLUDED_DIRS = {".git", "node_modules", "bin", "obj", "publish", ".azurefunctions", "runtimes"}

# File names to exclude (development / build artifacts — not IaC definitions)
EXCLUDED_FILENAMES = {
    "local.settings.json",
    "extensions.json",
    "functions.metadata",
    "worker.config.json",
}

EXCLUDED_FILENAME_SUFFIXES = (
    ".deps.json",
    ".runtimeconfig.json",
    ".pdb",
)


# ---------------------------------------------------------------------------
# Violation dataclass
# ---------------------------------------------------------------------------

class Violation:
    def __init__(self, rule: str, file_path: str, line_num: int, description: str):
        self.rule = rule
        self.file_path = os.path.relpath(file_path, REPO_ROOT).replace("\\", "/")
        self.line_num = line_num
        self.description = description


# ---------------------------------------------------------------------------
# Contract loader
# ---------------------------------------------------------------------------

def load_contract() -> dict:
    """Load the YAML contract file and merge all documents into a single dict."""
    if not os.path.exists(CONTRACT_PATH):
        print(f"ERROR: Contract file not found: {CONTRACT_PATH}", file=sys.stderr)
        sys.exit(2)
    try:
        with open(CONTRACT_PATH, "r", encoding="utf-8") as fh:
            docs = list(yaml.safe_load_all(fh))
    except yaml.YAMLError as exc:
        print(f"ERROR: Failed to parse contract YAML: {exc}", file=sys.stderr)
        sys.exit(2)

    merged: dict = {}
    for doc in docs:
        if doc and isinstance(doc, dict):
            merged.update(doc)
    return merged


# ---------------------------------------------------------------------------
# IaC file discovery
# ---------------------------------------------------------------------------

def find_iac_files() -> list:
    """Return all IaC source files in the repository, excluding build artifacts."""
    extensions = ["*.bicep", "*.tf", "*.yaml", "*.yml", "*.json"]
    collected = []

    for ext in extensions:
        pattern = os.path.join(REPO_ROOT, "**", ext)
        for filepath in glob_module.glob(pattern, recursive=True):
            normalized = filepath.replace("\\", "/")
            parts = normalized.split("/")

            # Skip excluded directory trees
            if any(ex in parts for ex in EXCLUDED_DIRS):
                continue

            basename = os.path.basename(filepath)

            # Skip excluded file names
            if basename in EXCLUDED_FILENAMES:
                continue

            # Skip excluded filename suffixes
            if any(basename.endswith(sfx) for sfx in EXCLUDED_FILENAME_SUFFIXES):
                continue

            collected.append(filepath)

    return collected


# ---------------------------------------------------------------------------
# Search helpers
# ---------------------------------------------------------------------------

def read_lines(filepath: str) -> list:
    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as fh:
            return fh.readlines()
    except Exception:
        return []


def search_pattern_in_files(files: list, pattern: str, file_predicate=None, flags: int = 0):
    """
    Yield (filepath, line_num, line) for each line matching `pattern`.
    Optionally filter files with `file_predicate(filepath) -> bool`.
    """
    regex = re.compile(pattern, flags)
    for filepath in files:
        if file_predicate and not file_predicate(filepath):
            continue
        for line_num, line in enumerate(read_lines(filepath), 1):
            if regex.search(line):
                yield filepath, line_num, line.rstrip()


def is_bicep(path: str) -> bool:
    return path.endswith(".bicep")


def is_bicep_or_tf(path: str) -> bool:
    return path.endswith(".bicep") or path.endswith(".tf")


# ---------------------------------------------------------------------------
# RULE SB-001
# Verify Service Bus queue name matches contract canonical value.
# ---------------------------------------------------------------------------

def check_sb001(contract: dict, files: list) -> list:
    canonical = (
        contract.get("canonical_resource_names", {})
        .get("service_bus_queue", "enrichment-requests")
    )
    violations = []

    # Pattern: param mainQueueName string = '<value>'
    param_pattern = re.compile(r"param\s+mainQueueName\s+string\s*=\s*'([^']+)'")

    for filepath, line_num, line in search_pattern_in_files(
        files, r"mainQueueName\s+string\s*=\s*'", is_bicep
    ):
        match = param_pattern.search(line)
        if match:
            value = match.group(1)
            if value != canonical:
                violations.append(Violation(
                    "SB-001", filepath, line_num,
                    f'Service Bus enrichment queue name "{value}" does not match '
                    f'canonical value "{canonical}"',
                ))

    # Pattern: mainQueueName: '<value>'  (module parameter passing)
    pass_pattern = re.compile(r"mainQueueName:\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"mainQueueName:\s*'", is_bicep
    ):
        match = pass_pattern.search(line)
        if match:
            value = match.group(1)
            if value != canonical:
                violations.append(Violation(
                    "SB-001", filepath, line_num,
                    f'Service Bus enrichment queue name "{value}" does not match '
                    f'canonical value "{canonical}"',
                ))

    return violations


# ---------------------------------------------------------------------------
# RULE SB-002
# Verify Service Bus namespace naming pattern: {project}-{environment}-sbus
# ---------------------------------------------------------------------------

def check_sb002(contract: dict, files: list) -> list:
    violations = []

    for filepath in [f for f in files if is_bicep(f)]:
        lines = read_lines(filepath)
        for i, line in enumerate(lines):
            # Locate Service Bus namespace resource declarations (not queues)
            if (
                "Microsoft.ServiceBus/namespaces'" in line
                and "/queues" not in line
                and "existing" not in line
            ):
                # Inspect the next 5 lines for the name attribute
                for j in range(i, min(i + 6, len(lines))):
                    name_match = re.search(r"^\s*name:\s*'([^']+)'", lines[j])
                    if name_match:
                        name_value = name_match.group(1)
                        if not name_value.endswith("-sbus"):
                            violations.append(Violation(
                                "SB-002", filepath, j + 1,
                                f'Service Bus namespace name "{name_value}" does not match '
                                f'pattern {{project}}-{{environment}}-sbus',
                            ))
                        break  # Stop after finding the name attribute

    return violations


# ---------------------------------------------------------------------------
# RULE COSMOS-001
# Verify Cosmos DB database name matches contract value.
# ---------------------------------------------------------------------------

def check_cosmos001(contract: dict, files: list) -> list:
    canonical = (
        contract.get("canonical_resource_names", {})
        .get("cosmos_database", "metadata_enricher")
    )
    violations = []

    # Pattern 1: param databaseName string = '<value>'
    param_re = re.compile(r"param\s+databaseName\s+string\s*=\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"param\s+databaseName\s+string\s*=\s*'", is_bicep
    ):
        match = param_re.search(line)
        if match and match.group(1) != canonical:
            violations.append(Violation(
                "COSMOS-001", filepath, line_num,
                f'Cosmos DB database name "{match.group(1)}" does not match '
                f'canonical value "{canonical}"',
            ))

    # Pattern 2: databaseName: '<value>'  (module parameter passing)
    pass_re = re.compile(r"databaseName:\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"databaseName:\s*'", is_bicep
    ):
        match = pass_re.search(line)
        if match and match.group(1) != canonical:
            violations.append(Violation(
                "COSMOS-001", filepath, line_num,
                f'Cosmos DB database name "{match.group(1)}" does not match '
                f'canonical value "{canonical}"',
            ))

    return violations


# ---------------------------------------------------------------------------
# RULE COSMOS-002
# Verify Cosmos containers include: state, audit
# ---------------------------------------------------------------------------

def check_cosmos002(contract: dict, files: list) -> list:
    required = [
        contract.get("canonical_resource_names", {}).get("cosmos_state_container", "state"),
        contract.get("canonical_resource_names", {}).get("cosmos_audit_container", "audit"),
    ]
    found = {c: False for c in required}
    violations = []

    for filepath, line_num, line in search_pattern_in_files(
        files, r"name:\s*'(state|audit)'", is_bicep
    ):
        match = re.search(r"name:\s*'(state|audit)'", line)
        if match:
            found[match.group(1)] = True

    for container, is_found in found.items():
        if not is_found:
            violations.append(Violation(
                "COSMOS-002", os.path.join(REPO_ROOT, "infra", "cosmos"), 0,
                f'Required Cosmos DB container "{container}" not found in any IaC file',
            ))

    return violations


# ---------------------------------------------------------------------------
# RULE COSMOS-003
# Verify Cosmos partition key matches contract definition.
# ---------------------------------------------------------------------------

def check_cosmos003(contract: dict, files: list) -> list:
    raw_pk = (
        contract.get("state_store", {})
        .get("containers", {})
        .get("state", {})
        .get("partitionKey", "asset_type")
    )
    canonical_path = f"/{raw_pk}"
    violations = []

    # Pattern 1: param partitionKeyPath string = '<value>'
    param_re = re.compile(r"param\s+partitionKeyPath\s+string\s*=\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"param\s+partitionKeyPath\s+string\s*=\s*'", is_bicep
    ):
        match = param_re.search(line)
        if match and match.group(1) != canonical_path:
            violations.append(Violation(
                "COSMOS-003", filepath, line_num,
                f'Cosmos partition key "{match.group(1)}" does not match '
                f'canonical value "{canonical_path}"',
            ))

    # Pattern 2: partitionKeyPath: '<value>'  (module parameter passing)
    pass_re = re.compile(r"partitionKeyPath:\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"partitionKeyPath:\s*'", is_bicep
    ):
        match = pass_re.search(line)
        if match and match.group(1) != canonical_path:
            violations.append(Violation(
                "COSMOS-003", filepath, line_num,
                f'Cosmos partition key "{match.group(1)}" does not match '
                f'canonical value "{canonical_path}"',
            ))

    return violations


# ---------------------------------------------------------------------------
# RULE SEARCH-001
# Verify Azure AI Search index name equals canonical index name.
# ---------------------------------------------------------------------------

def check_search001(contract: dict, files: list) -> list:
    canonical = (
        contract.get("canonical_resource_names", {})
        .get("ai_search_index", "metadata-context-index")
    )
    violations = []

    # Bicep: param indexName string = '<value>'
    param_re = re.compile(r"param\s+indexName\s+string\s*=\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"param\s+indexName\s+string\s*=\s*'", is_bicep
    ):
        match = param_re.search(line)
        if match and match.group(1) != canonical:
            violations.append(Violation(
                "SEARCH-001", filepath, line_num,
                f'AI Search index name "{match.group(1)}" does not match '
                f'canonical value "{canonical}"',
            ))

    # Bicep: indexName: '<value>'
    pass_re = re.compile(r"indexName:\s*'([^']+)'")
    for filepath, line_num, line in search_pattern_in_files(
        files, r"indexName:\s*'", is_bicep
    ):
        match = pass_re.search(line)
        if match and match.group(1) != canonical:
            violations.append(Violation(
                "SEARCH-001", filepath, line_num,
                f'AI Search index name "{match.group(1)}" does not match '
                f'canonical value "{canonical}"',
            ))

    # JSON schema file: "name": "<value>" at the index root level
    json_re = re.compile(r'"name":\s*"(metadata-context-index[^"]*)"')
    for filepath in files:
        if not filepath.endswith(".json"):
            continue
        for line_num, line in enumerate(read_lines(filepath), 1):
            match = json_re.search(line)
            if match and match.group(1) != canonical:
                violations.append(Violation(
                    "SEARCH-001", filepath, line_num,
                    f'AI Search index name "{match.group(1)}" does not match '
                    f'canonical value "{canonical}"',
                ))

    return violations


# ---------------------------------------------------------------------------
# RULE STORAGE-001
# Verify Blob Storage containers exist for: synergy, zipline, documentation, schemas
# ---------------------------------------------------------------------------

def check_storage001(contract: dict, files: list) -> list:
    required = list(
        contract.get("storage", {})
        .get("blobStorage", {})
        .get("containers", {})
        .keys()
    ) or ["synergy", "zipline", "documentation", "schemas"]

    found = {c: False for c in required}
    violations = []

    pattern_str = r"name:\s*'(" + "|".join(re.escape(c) for c in required) + r")'"
    for filepath, line_num, line in search_pattern_in_files(files, pattern_str, is_bicep):
        match = re.search(pattern_str, line)
        if match:
            found[match.group(1)] = True

    for container, is_found in found.items():
        if not is_found:
            violations.append(Violation(
                "STORAGE-001", os.path.join(REPO_ROOT, "infra", "storage"), 0,
                f'Required blob storage container "{container}" not found in any IaC file',
            ))

    return violations


# ---------------------------------------------------------------------------
# RULE IDENTITY-001
# Verify resources reference Managed Identity rather than connection strings.
# ---------------------------------------------------------------------------

def check_identity001(contract: dict, files: list) -> list:
    violations = []

    conn_string_indicators = [
        (r"AccountKey\s*=\s*[A-Za-z0-9+/=]{20,}", "Storage AccountKey in connection string"),
        (r"SharedAccessKey\s*=", "SharedAccessKey in connection string"),
        (r"DefaultEndpointsProtocol=https;AccountName=", "Storage account connection string"),
        (r"Endpoint=sb://[^;]+;SharedAccessKeyName=", "Service Bus SAS connection string"),
    ]

    # Only scan authoritative IaC files — bicep and terraform
    for pattern_str, label in conn_string_indicators:
        for filepath, line_num, line in search_pattern_in_files(
            files, pattern_str, is_bicep_or_tf
        ):
            violations.append(Violation(
                "IDENTITY-001", filepath, line_num,
                f'{label} detected — all connections must use Managed Identity (no SAS/connection strings)',
            ))

    return violations


# ---------------------------------------------------------------------------
# RULE MSG-001
# Verify Service Bus messaging topology includes queue definitions from contract.
# ---------------------------------------------------------------------------

def check_msg001(contract: dict, files: list) -> list:
    queues_config = contract.get("messaging", {}).get("queues", {})
    required_queues = [q.get("name") for q in queues_config.values() if q.get("name")]

    violations = []

    for queue_name in required_queues:
        found = any(
            True
            for _ in search_pattern_in_files(files, re.escape(queue_name), is_bicep)
        )
        if not found:
            violations.append(Violation(
                "MSG-001", os.path.join(REPO_ROOT, "infra", "messaging"), 0,
                f'Service Bus queue "{queue_name}" defined in contract not found in any IaC file',
            ))

    return violations


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CHECKS = [
    ("SB-001",      check_sb001),
    ("SB-002",      check_sb002),
    ("COSMOS-001",  check_cosmos001),
    ("COSMOS-002",  check_cosmos002),
    ("COSMOS-003",  check_cosmos003),
    ("SEARCH-001",  check_search001),
    ("STORAGE-001", check_storage001),
    ("IDENTITY-001", check_identity001),
    ("MSG-001",     check_msg001),
]


def main() -> None:
    print("=" * 60)
    print("Infrastructure Contract Validator")
    print("=" * 60)
    print(f"Contract : {os.path.relpath(CONTRACT_PATH, REPO_ROOT)}")
    print(f"Repo root: {REPO_ROOT}")
    print()

    print("Loading architecture contract...")
    contract = load_contract()
    print("Contract loaded successfully.")
    print()

    print("Scanning IaC files...")
    files = find_iac_files()
    print(f"Found {len(files)} IaC file(s) to validate.")
    print()

    print("Running validation rules...")
    all_violations: list = []

    for rule_id, check_fn in CHECKS:
        violations = check_fn(contract, files)
        status = "FAIL" if violations else "PASS"
        print(f"  [{status}] {rule_id}")
        all_violations.extend(violations)

    print()

    if not all_violations:
        print("Architecture compliance check: PASS")
        sys.exit(0)

    print("ARCHITECTURE_DRIFT_DETECTED")
    print()
    for i, v in enumerate(all_violations, 1):
        print(f"{i}. [{v.rule}] {v.file_path}:{v.line_num}")
        print(f"   {v.description}")
        print()

    sys.exit(1)


if __name__ == "__main__":
    main()

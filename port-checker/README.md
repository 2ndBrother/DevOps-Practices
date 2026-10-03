# Port Manager

Port Manager is an interactive Bash utility for viewing and changing TCP `DROP` rules across multiple Linux nodes. It loads hosts from an inventory file, loads managed ports from a profile, checks nodes in parallel, and applies idempotent `iptables` commands over SSH.

> **Safety notice:** The included addresses are randomized examples from the IPv4 documentation ranges and are not intended to be reachable. The included SSH and application ports are also randomized. Replace all example values before using the script in an authorized environment. Firewall changes can interrupt access to production systems, so test in an isolated VM first.

## Project background

The original `Port_Check.sh` was written as a learning project using Stack Overflow references and without AI assistance. Version 2 uses that script as its base and was reorganized with AI assistance to support inventories, port profiles, status reporting, reusable functions, logging, and bounded parallel execution.

## Features

- Selectable host inventory and port-profile files
- Parallel status checks and changes with a configurable job limit
- Open or close every managed port on every node
- Open or close every managed port on one node
- Open or close one port on every node
- Confirmation before multi-node changes
- Idempotent `iptables` checks that avoid duplicate `DROP` rules
- Timestamped activity logging

## Repository layout

```text
port-checker/
├── port_manager.sh
├── inventories/
│   └── example_inventory.txt
└── profiles/
    └── ports_example.txt
```

## How status is interpreted

For each configured port, the script checks whether this exact rule exists:

```bash
iptables -C INPUT -p tcp --dport PORT -j DROP
```

- `CLOSED` means the matching `DROP` rule exists.
- `OPEN` means that exact rule was not found.
- `OFFLINE` means the configured SSH TCP port did not respond within two seconds.

This reports the state of the managed firewall rule. It does **not** prove that an application is listening on the port or that another firewall rule, security group, ACL, or network device permits the connection.

## Requirements

The controller requires Bash 4 or newer plus these commands:

- `ssh`
- `sshpass`
- `timeout`
- `iptables` on each managed node
- `figlet` (optional, banner only)

Example installation on a RHEL-compatible system:

```bash
sudo dnf install -y openssh-clients sshpass iptables
sudo dnf install -y figlet  # optional
```

The remote account must be authorized to run the required `iptables` commands with `sudo`. For unattended use, narrowly scoped passwordless `sudo` rules are preferable to unrestricted `sudo` access.

## Configuration

Edit the configuration block near the top of `port_manager.sh`:

```bash
SSH_USER="remoteadmin"
SSH_PORT=39222
SSH_TIMEOUT=10
MAX_JOBS=8
LOGFILE="./port_manager.log"

DEFAULT_INVENTORY="example_inventory.txt"
DEFAULT_PROFILE="ports_example.txt"
```

Inventory files belong in `inventories/` and contain one IPv4 address per line, with no comments or blank lines:

```text
192.0.2.47
198.51.100.131
203.0.113.84
```

Port profiles belong in `profiles/`, their names start with `ports_`, and they contain one TCP port per line:

```text
18443
27180
32081
45812
```

## Usage

```bash
chmod +x port_manager.sh
./port_manager.sh
```

The script asks for an inventory, a port profile, the SSH password, and an operation. Press Enter at the inventory or profile prompt to accept its displayed default.

Run only from a trusted administrator workstation. The script disables SSH host-key verification and supplies a password through `sshpass`; both choices trade security for convenience.

## Back-test summary

The corrected script was tested without contacting real systems. `sshpass`, `ssh`, `timeout`, and the remote `iptables` responses were replaced with local test doubles.

| Test | Result |
| --- | --- |
| Bash syntax validation with `bash -n` | Passed |
| Default inventory/profile loading | Passed |
| Parallel initial status display | Passed |
| Option 1: open all managed ports on all nodes | Passed |
| Option 2: close all managed ports on all nodes | Passed |
| Option 3: change all managed ports on one node | Passed |
| Option 4: change one port on all nodes | Passed |
| Option 5: refresh status | Passed |
| Missing inventory/profile handling | Passed |
| Invalid menu/action rejection | Passed |

These are behavioral back-tests with mocked network commands, not an integration test against a live host. Run a final test against a disposable VM whose console access does not depend on the rules being changed.

## Corrections made to V2

- Removed Markdown code fences that had been embedded in the Bash source.
- Repaired the split `find ... -exec` command for port-profile discovery.
- Added a no-op to the empty `else` branch so the conditional parses correctly.
- Corrected the first `case` label from `1.` to `1)`.
- Escaped the remote loop variable so it expands on the remote host instead of failing locally under `set -u`.
- Removed escaped quote characters that prevented `OPEN` status comparisons from matching.
- Kept each parallel node-status row together to prevent mixed output.
- Declared function-local command/result variables to prevent accidental state leakage.
- Normalized the script and data files to Unix LF line endings.
- Replaced environment-specific addresses, ports, filenames, and the example SSH username with publishable sample values.

The operational model remains the same: a present `DROP` rule means closed; removing that rule means open; adding it means closed.

## What can be done next

1. **Validate input before interpolation.** Reject malformed IP addresses, filenames, actions, and port values before building SSH commands. This is the most important next security improvement because options 3 and 4 accept interactive values.
2. **Replace password-based automation.** Use SSH keys, an agent, host-key verification, and a restricted `sudoers` policy. This removes the password from the `sshpass` process arguments and protects against connecting to an impersonated host.
3. **Detect partial failures.** Make each remote batch return a nonzero status if any individual `iptables` command fails, then report the exact node and port. The current result reflects the final remote command and can miss an earlier failure in the same batch.
4. **Use a dedicated firewall chain.** Managing rules in a named chain makes ownership, ordering, auditing, and rollback clearer than appending directly to `INPUT`.
5. **Add automatic rollback.** For remote firewall work, schedule a temporary recovery rule before applying changes and cancel it only after connectivity is verified.
6. **Improve input-file parsing.** Safely ignore blank lines and comments, reject duplicates, and validate the full inventory/profile before any change starts.
7. **Add a dry-run mode.** Print the planned node/port changes without making them, followed by an execution summary.
8. **Add automated tests and CI.** Commit the mock-based test harness and run syntax and behavior checks on every pull request.
9. **Support modern firewall backends.** Add selectable `nftables` or `firewalld` implementations while keeping `iptables` compatibility where required.
10. **Add structured audit output.** Record node, port, action, operator, result, and timestamp in JSON or CSV without logging credentials.

## Known limitations

- Only TCP `DROP` rules in the `INPUT` chain are managed.
- Existing firewall rule order may change the effective result.
- A successful command does not confirm application availability.
- The current script expects one interactive operation per run.
- Concurrent log writes can appear in completion order rather than inventory order.
- The included example addresses and ports must be replaced before real use.

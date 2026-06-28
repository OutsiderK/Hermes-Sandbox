# Validation status

The project was checked in the delivery environment with:

- YAML loading and policy assertions for `compose.yaml`;
- Python bytecode compilation for every runtime/test module;
- runtime unit tests for the secret-file parser and safe outbox exporter;
- POSIX shell syntax checks for the runtime and netguard entrypoints;
- token-aware delimiter checks for both PowerShell scripts;
- repository scans for privileged mode, host networking and Docker-socket mounts.

The delivery environment does not provide Docker Desktop or a PowerShell runtime, so it could not perform an actual Windows container launch or execute the PowerShell AST parser. The first real Windows start therefore deliberately runs, in order:

1. `docker compose config --quiet`;
2. image build and health checks;
3. effective-container inspection;
4. file write-boundary probes;
5. direct-egress and metadata-address probes;
6. mihomo controller localhost publication and sidecar privilege checks;
7. Dashboard authentication checks.

If any startup or security audit step fails, the script stops Hermes, mihomo and netguard instead of opening the Dashboard.

Run the checks again on the Windows host with:

```powershell
.\scripts\hermes.ps1 start -Open
.\scripts\hermes.ps1 audit
```

For repository-only checks on a machine with Python and PyYAML:

```text
python tests/static_check.py
python tests/test_runtime.py
```

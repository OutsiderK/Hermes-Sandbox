hermes.env is created locally and ignored by Git.

Create/rotate the Dashboard login:
  .\scripts\hermes.ps1 dashboard-password

Set an API key:
  .\scripts\hermes.ps1 secret-set DEEPSEEK_API_KEY

Hermes receives the values at runtime, but cannot modify this host file.
Use dedicated, low-privilege, revocable and rate-limited credentials.

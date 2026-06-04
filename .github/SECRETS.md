# GitHub repository secrets

Repository: [adab-tech/battery-life-helper](https://github.com/adab-tech/battery-life-helper)

No API keys or cloud secrets are required. CI validates PowerShell syntax on `windows-latest` only.

This tool runs locally on Windows and adjusts `powercfg` settings — test on your laptop with:

```cmd
Run-BatteryLifeHelper.cmd
```

or:

```powershell
.\BatteryLifeHelper.ps1 -Action status
```

# Battery Life Helper

`BatteryLifeHelper.ps1` is a small Windows utility that helps you squeeze more life out of your laptop battery without permanently changing your usual power plan.

## What it does

- Shows the current battery level, whether the laptop is plugged in, and which power plan is active.
- Clones your current Windows power plan into a temporary `Codex Battery Saver` plan.
- Tunes that temporary plan for battery use by shortening idle timeouts, lowering the processor cap, biasing the CPU toward efficiency, reducing brightness, and increasing wireless power saving while unplugged.
- Restores your original power plan later and removes the temporary one.
- Can watch your battery in the background and switch profiles automatically when charge drops below a threshold you choose.
- Generates `batteryreport` and `energy` HTML reports you can inspect in a browser.

## Tuned settings in battery saver mode

The helper supports three profiles:

- `standard`: light battery saving with less impact on comfort.
- `aggressive`: a stronger runtime-focused setup for typical unplugged work.
- `extreme`: the most battery-focused setup, intended to stretch runtime as far as the hardware allows.

Default `standard` values:

- Display turns off after `3` minutes on battery.
- Sleep starts after `10` minutes on battery.
- Hibernate starts after `30` minutes on battery.
- Disk idle timeout is set to `5` minutes on battery.
- CPU maximum state is capped at `60%` on battery.
- Display brightness is lowered and adaptive brightness is enabled when supported.
- CPU boost, cooling, PCIe, and wireless settings are biased toward efficiency when supported.

You can override those defaults from the command line.

## Quick start

Run the launcher:

```bat
Run-BatteryLifeHelper.cmd
```

Start automatic switching mode:

```bat
Start-BatteryAutoMode.cmd -Profile extreme -AutoThresholdPercent 35
```

Or run the script directly:

```powershell
.\BatteryLifeHelper.ps1
```

## Commands

Show status:

```powershell
.\BatteryLifeHelper.ps1 -Action status
```

Turn on the temporary battery saver plan:

```powershell
.\BatteryLifeHelper.ps1 -Action optimize
```

Turn on the strongest runtime-saving profile:

```powershell
.\BatteryLifeHelper.ps1 -Action optimize -Profile extreme
```

Restore your original plan:

```powershell
.\BatteryLifeHelper.ps1 -Action restore
```

Generate reports:

```powershell
.\BatteryLifeHelper.ps1 -Action report
```

Start auto mode with a 35% trigger and 60 second checks:

```powershell
.\BatteryLifeHelper.ps1 -Action auto -Profile extreme -AutoThresholdPercent 35 -CheckIntervalSeconds 60
```

Run auto mode once for a quick check without waiting in a loop:

```powershell
.\BatteryLifeHelper.ps1 -Action auto -RunOnce
```

Customize the battery saver plan:

```powershell
.\BatteryLifeHelper.ps1 -Action optimize -Profile aggressive -DisplayTimeoutMinutes 2 -SleepTimeoutMinutes 8 -HibernateTimeoutMinutes 20 -ProcessorMaxPercent 50
```

## Notes

- This tool is designed for Windows laptops.
- Some `powercfg` operations may require an elevated PowerShell window depending on your Windows setup.
- The generated reports are saved in the local `reports` folder next to the script.
- In auto mode, the helper enables the chosen battery saver profile once your charge falls to the threshold and restores your original plan again when you plug the laptop back in.
- A software-only battery profile can help a lot, but it cannot guarantee turning a real `2 hour` battery into `8+ hours` on every laptop. Large gains depend on screen brightness, battery health, CPU/GPU workload, and the hardware itself.

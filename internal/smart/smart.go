// Package smart reads a drive's SMART health through `smartctl --json` and
// reduces the three dialects it speaks (ATA, NVMe, SCSI) to one Report:
// a verdict, the handful of numbers worth showing, and the raw attribute
// table for anyone who wants to dig.
//
// Most of what airlock sees — thumb drives, SD cards behind a card reader —
// has no SMART at all; that's StatusUnsupported, not an error. USB SSDs and
// hard drives behind a SAT or NVMe bridge usually answer: smartctl's drive
// database picks the bridge type from the USB id. Bridges it doesn't know
// are left alone rather than probed with guessed pass-through commands.
package smart

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Status is the overall verdict.
type Status string

const (
	StatusPassed      Status = "passed"      // self-assessment passed, counters clean
	StatusWarning     Status = "warning"     // passed, but something worth knowing (bad sectors, worn out)
	StatusFailing     Status = "failing"     // the drive says it is failing
	StatusUnsupported Status = "unsupported" // no SMART behind this device (thumb drive, card reader)
	StatusStandby     Status = "standby"     // asleep; not woken just to read SMART
	StatusError       Status = "error"       // smartctl missing, or it failed
)

// Attribute is one row of the raw table: an ATA SMART attribute, or a
// field of the NVMe health log (those carry only Name and Raw).
type Attribute struct {
	ID         int    `json:"id,omitempty"`
	Name       string `json:"name"`
	Value      *int   `json:"value,omitempty"`  // normalised, 1-253; higher is better
	Worst      *int   `json:"worst,omitempty"`  // lowest normalised value seen
	Threshold  *int   `json:"thresh,omitempty"` // failure threshold for Value
	Raw        string `json:"raw"`
	Prefailure bool   `json:"prefailure,omitempty"` // crossing Threshold predicts failure
	Failed     string `json:"failed,omitempty"`     // "now", "past" or ""
}

// Report is the normalised SMART reading. Pointer fields are nil when the
// drive doesn't report them.
type Report struct {
	Status   Status   `json:"status"`
	Summary  string   `json:"summary"`
	Warnings []string `json:"warnings,omitempty"`
	Messages []string `json:"messages,omitempty"` // smartctl's own diagnostics

	Protocol string `json:"protocol,omitempty"` // "ATA", "NVMe", "SCSI"
	Model    string `json:"model,omitempty"`
	Serial   string `json:"serial,omitempty"`
	Firmware string `json:"firmware,omitempty"`

	TemperatureC         *int   `json:"temperature_c,omitempty"`
	PowerOnHours         *int64 `json:"power_on_hours,omitempty"`
	PowerCycles          *int64 `json:"power_cycles,omitempty"`
	PercentageUsed       *int   `json:"percentage_used,omitempty"` // of rated endurance; may pass 100
	AvailableSpare       *int   `json:"available_spare,omitempty"` // percent
	ReallocatedSectors   *int64 `json:"reallocated_sectors,omitempty"`
	PendingSectors       *int64 `json:"pending_sectors,omitempty"`
	UncorrectableSectors *int64 `json:"uncorrectable_sectors,omitempty"`
	MediaErrors          *int64 `json:"media_errors,omitempty"`
	UnsafeShutdowns      *int64 `json:"unsafe_shutdowns,omitempty"`
	DataWrittenBytes     *int64 `json:"data_written_bytes,omitempty"`

	Attributes []Attribute `json:"attributes,omitempty"`
	CheckedAt  time.Time   `json:"checked_at"`
}

// queryTimeout bounds one smartctl run. A healthy drive answers in well
// under a second; a confused bridge can stall for much longer.
const queryTimeout = 30 * time.Second

// Query reads SMART from the block device at path (e.g. "/dev/sdb").
// Failures come back as a Report with StatusError, never as a Go error, so
// callers can cache and show them like any other outcome.
func Query(ctx context.Context, path string) Report {
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()
	// -a: everything (identity, health, attributes, logs) — read-only.
	// -n standby: don't spin up a sleeping drive just to read it.
	// No -d: smartctl's auto-detection uses its USB bridge database.
	out, err := exec.CommandContext(ctx, "smartctl", "--json", "-a", "-n", "standby", path).Output()
	if errors.Is(err, exec.ErrNotFound) {
		return errorReport("smartctl isn't installed on this airlock (apt install smartmontools).")
	}
	// smartctl's exit status is a bitmask that's non-zero for plenty of
	// readable results (a failing drive, a log it couldn't fetch), so the
	// JSON decides — only a missing or garbled one is an error.
	r, perr := Parse(out)
	if perr != nil {
		if ctx.Err() != nil {
			return errorReport("smartctl timed out.")
		}
		if err != nil {
			return errorReport(fmt.Sprintf("smartctl failed: %v", err))
		}
		return errorReport(perr.Error())
	}
	return r
}

func errorReport(msg string) Report {
	return Report{Status: StatusError, Summary: msg, CheckedAt: time.Now()}
}

// smartctl --json exit-status bits (smartctl(8), RETURN VALUES).
const (
	exitOpenFailed     = 1 << 1 // device open failed, or in low-power mode with -n
	exitPrefailNow     = 1 << 4 // a prefail attribute is at or below its threshold
	exitAttrFailedPast = 1 << 5 // an attribute was at or below threshold in the past
)

// smartctlJSON is the subset of `smartctl --json -a` that Parse reads.
type smartctlJSON struct {
	Smartctl struct {
		ExitStatus int `json:"exit_status"`
		Messages   []struct {
			String   string `json:"string"`
			Severity string `json:"severity"`
		} `json:"messages"`
	} `json:"smartctl"`
	Device *struct {
		Protocol string `json:"protocol"`
	} `json:"device"`
	ModelName       string `json:"model_name"`
	SCSIModelName   string `json:"scsi_model_name"`
	SerialNumber    string `json:"serial_number"`
	FirmwareVersion string `json:"firmware_version"`
	SmartSupport    *struct {
		Available bool `json:"available"`
		Enabled   bool `json:"enabled"`
	} `json:"smart_support"`
	SmartStatus *struct {
		Passed bool `json:"passed"`
	} `json:"smart_status"`
	Temperature *struct {
		Current *int `json:"current"`
	} `json:"temperature"`
	PowerOnTime *struct {
		Hours *int64 `json:"hours"`
	} `json:"power_on_time"`
	PowerCycleCount *int64 `json:"power_cycle_count"`
	EnduranceUsed   *struct {
		CurrentPercent *int `json:"current_percent"`
	} `json:"endurance_used"` // smartctl 7.5+
	ATAAttributes *struct {
		Table []struct {
			ID         int    `json:"id"`
			Name       string `json:"name"`
			Value      int    `json:"value"`
			Worst      int    `json:"worst"`
			Thresh     int    `json:"thresh"`
			WhenFailed string `json:"when_failed"`
			Flags      struct {
				Prefailure bool `json:"prefailure"`
			} `json:"flags"`
			Raw struct {
				Value  int64  `json:"value"`
				String string `json:"string"`
			} `json:"raw"`
		} `json:"table"`
	} `json:"ata_smart_attributes"`
	NVMeLog *nvmeLog `json:"nvme_smart_health_information_log"`
	// SCSI drives: the grown defect list is their reallocated-sector count.
	SCSIGrownDefects *int64 `json:"scsi_grown_defect_list"`
}

type nvmeLog struct {
	CriticalWarning         int   `json:"critical_warning"`
	Temperature             int   `json:"temperature"`
	AvailableSpare          int   `json:"available_spare"`
	AvailableSpareThreshold int   `json:"available_spare_threshold"`
	PercentageUsed          int   `json:"percentage_used"`
	DataUnitsRead           int64 `json:"data_units_read"`
	DataUnitsWritten        int64 `json:"data_units_written"`
	HostReads               int64 `json:"host_reads"`
	HostWrites              int64 `json:"host_writes"`
	ControllerBusyTime      int64 `json:"controller_busy_time"`
	PowerCycles             int64 `json:"power_cycles"`
	PowerOnHours            int64 `json:"power_on_hours"`
	UnsafeShutdowns         int64 `json:"unsafe_shutdowns"`
	MediaErrors             int64 `json:"media_errors"`
	NumErrLogEntries        int64 `json:"num_err_log_entries"`
}

// nvmeDataUnit is the NVMe "data unit": 1000 512-byte sectors.
const nvmeDataUnit = 512 * 1000

// lifeLeftAttrs are ATA attributes whose normalised value is the percent
// of life remaining. Matched by name, not id: vendors reuse ids (177 is
// Samsung's Wear_Leveling_Count but SandForce's Wear_Range_Delta).
var lifeLeftAttrs = map[string]bool{
	"Wear_Leveling_Count":     true,
	"SSD_Life_Left":           true,
	"Media_Wearout_Indicator": true,
	"Percent_Lifetime_Remain": true,
	"Remaining_Lifetime_Perc": true,
	"Percent_Life_Remaining":  true,
}

// wornThreshold is the percent of rated endurance past which a drive gets
// a warning: it still works, but writes are on borrowed time.
const wornThreshold = 90

// Parse turns `smartctl --json -a` output into a Report.
func Parse(data []byte) (Report, error) {
	var j smartctlJSON
	if err := json.Unmarshal(data, &j); err != nil {
		return Report{}, fmt.Errorf("unreadable smartctl output: %w", err)
	}
	r := Report{CheckedAt: time.Now()}
	for _, m := range j.Smartctl.Messages {
		r.Messages = append(r.Messages, m.String)
	}
	exit := j.Smartctl.ExitStatus

	if exit&exitOpenFailed != 0 && mentions(r.Messages, "standby", "sleep") {
		r.Status = StatusStandby
		r.Summary = "The drive is asleep; Airlock doesn't wake it just to read SMART."
		return r, nil
	}
	if j.SmartStatus == nil {
		r.Status = StatusUnsupported
		r.Summary = "This device doesn't report SMART health. That's normal for thumb drives, SD cards and most card readers."
		if j.SmartSupport != nil && j.SmartSupport.Available && !j.SmartSupport.Enabled {
			r.Summary = "SMART is turned off on this drive."
		}
		return r, nil
	}

	if j.Device != nil {
		r.Protocol = j.Device.Protocol
	}
	r.Model = firstNonEmpty(j.ModelName, j.SCSIModelName)
	r.Serial = j.SerialNumber
	r.Firmware = j.FirmwareVersion
	if j.Temperature != nil {
		r.TemperatureC = j.Temperature.Current
	}
	if j.PowerOnTime != nil {
		r.PowerOnHours = j.PowerOnTime.Hours
	}
	r.PowerCycles = j.PowerCycleCount
	if j.EnduranceUsed != nil {
		r.PercentageUsed = j.EnduranceUsed.CurrentPercent
	}

	failing := !j.SmartStatus.Passed
	var warnings []string

	if j.ATAAttributes != nil {
		for _, a := range j.ATAAttributes.Table {
			attr := Attribute{
				ID: a.ID, Name: a.Name,
				Value: ptr(a.Value), Worst: ptr(a.Worst), Threshold: ptr(a.Thresh),
				Raw: a.Raw.String, Prefailure: a.Flags.Prefailure, Failed: a.WhenFailed,
			}
			r.Attributes = append(r.Attributes, attr)
			switch a.ID {
			case 5:
				r.ReallocatedSectors = ptr(a.Raw.Value)
			case 197:
				r.PendingSectors = ptr(a.Raw.Value)
			case 198:
				r.UncorrectableSectors = ptr(a.Raw.Value)
			}
			if lifeLeftAttrs[a.Name] && r.PercentageUsed == nil && a.Value >= 1 && a.Value <= 100 {
				r.PercentageUsed = ptr(100 - a.Value)
			}
			switch {
			case a.WhenFailed == "now" && a.Flags.Prefailure:
				failing = true
				warnings = append(warnings, a.Name+" is below its failure threshold")
			case a.WhenFailed == "now":
				warnings = append(warnings, a.Name+" is below its threshold (age-related)")
			case a.WhenFailed == "past":
				warnings = append(warnings, a.Name+" was below its threshold in the past")
			}
		}
	}

	if n := j.NVMeLog; n != nil {
		r.PercentageUsed = ptr(n.PercentageUsed)
		r.AvailableSpare = ptr(n.AvailableSpare)
		r.MediaErrors = ptr(n.MediaErrors)
		r.UnsafeShutdowns = ptr(n.UnsafeShutdowns)
		r.DataWrittenBytes = ptr(n.DataUnitsWritten * nvmeDataUnit)
		if r.TemperatureC == nil {
			r.TemperatureC = ptr(n.Temperature)
		}
		if r.PowerOnHours == nil {
			r.PowerOnHours = ptr(n.PowerOnHours)
		}
		if r.PowerCycles == nil {
			r.PowerCycles = ptr(n.PowerCycles)
		}
		r.Attributes = nvmeAttributes(n)
		if n.CriticalWarning != 0 {
			warnings = append(warnings, fmt.Sprintf("Critical warning flags set (0x%02x)", n.CriticalWarning))
		}
		if n.AvailableSpareThreshold > 0 && n.AvailableSpare < n.AvailableSpareThreshold {
			warnings = append(warnings, fmt.Sprintf("Spare capacity %d%% is below the %d%% threshold",
				n.AvailableSpare, n.AvailableSpareThreshold))
		}
	}

	if j.SCSIGrownDefects != nil {
		r.ReallocatedSectors = j.SCSIGrownDefects
	}

	// Counters that are non-zero on a passing drive: it works, but it's
	// losing sectors and shouldn't be trusted with the only copy.
	countWarn := func(v *int64, what string) {
		if v != nil && *v > 0 {
			warnings = append(warnings, fmt.Sprintf("%d %s", *v, what))
		}
	}
	countWarn(r.ReallocatedSectors, "reallocated sectors")
	countWarn(r.PendingSectors, "sectors pending reallocation")
	countWarn(r.UncorrectableSectors, "uncorrectable sectors")
	countWarn(r.MediaErrors, "media errors")
	if r.PercentageUsed != nil && *r.PercentageUsed >= wornThreshold {
		warnings = append(warnings, fmt.Sprintf("%d%% of rated write endurance used", *r.PercentageUsed))
	}
	if exit&(exitPrefailNow|exitAttrFailedPast) != 0 && len(warnings) == 0 {
		warnings = append(warnings, "smartctl flagged attributes at or below their thresholds")
	}
	r.Warnings = warnings

	switch {
	case failing:
		r.Status = StatusFailing
		r.Summary = "The drive reports it is failing. Copy off anything you need and replace it."
	case len(warnings) > 0:
		r.Status = StatusWarning
		r.Summary = "SMART check passed, with warnings: " + strings.ToLower(warnings[0][:1]) + warnings[0][1:] + "."
	default:
		r.Status = StatusPassed
		r.Summary = "SMART check passed."
	}
	return r, nil
}

func nvmeAttributes(n *nvmeLog) []Attribute {
	row := func(name string, v any) Attribute { return Attribute{Name: name, Raw: fmt.Sprint(v)} }
	return []Attribute{
		row("Critical Warning", fmt.Sprintf("0x%02x", n.CriticalWarning)),
		row("Temperature", fmt.Sprintf("%d °C", n.Temperature)),
		row("Available Spare", fmt.Sprintf("%d%%", n.AvailableSpare)),
		row("Available Spare Threshold", fmt.Sprintf("%d%%", n.AvailableSpareThreshold)),
		row("Percentage Used", fmt.Sprintf("%d%%", n.PercentageUsed)),
		row("Data Units Read", n.DataUnitsRead),
		row("Data Units Written", n.DataUnitsWritten),
		row("Host Read Commands", n.HostReads),
		row("Host Write Commands", n.HostWrites),
		row("Controller Busy Time", n.ControllerBusyTime),
		row("Power Cycles", n.PowerCycles),
		row("Power On Hours", n.PowerOnHours),
		row("Unsafe Shutdowns", n.UnsafeShutdowns),
		row("Media and Data Integrity Errors", n.MediaErrors),
		row("Error Information Log Entries", n.NumErrLogEntries),
	}
}

func mentions(msgs []string, words ...string) bool {
	for _, m := range msgs {
		lm := strings.ToLower(m)
		for _, w := range words {
			if strings.Contains(lm, w) {
				return true
			}
		}
	}
	return false
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

func ptr[T any](v T) *T { return &v }

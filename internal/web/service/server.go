Warning: truncated output (original token count: 23978)
Total output lines: 3038

package service

import (
	"archive/zip"
	"bufio"
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"maps"
	"math"
	"mime/multipart"
	stdnet "net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v3/internal/amneziawg"
	"github.com/mhsanaei/3x-ui/v3/internal/amneziawgkern"
	"github.com/mhsanaei/3x-ui/v3/internal/amneziawgnet"
	"github.com/mhsanaei/3x-ui/v3/internal/config"
	"github.com/mhsanaei/3x-ui/v3/internal/database"
	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
	"github.com/mhsanaei/3x-ui/v3/internal/logger"
	"github.com/mhsanaei/3x-ui/v3/internal/util/common"
	"github.com/mhsanaei/3x-ui/v3/internal/util/netsafe"
	"github.com/mhsanaei/3x-ui/v3/internal/util/sys"
	"github.com/mhsanaei/3x-ui/v3/internal/xray"

	"github.com/google/uuid"
	utls "github.com/refraction-networking/utls"
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/net"
)

// ProcessState represents the current state of a system process.
type ProcessState string

// Process state constants
const (
	Running ProcessState = "running" // Process is running normally
	Stop    ProcessState = "stop"    // Process is stopped
	Error   ProcessState = "error"   // Process is in error state
)

// Status represents comprehensive system and application status information.
// It includes CPU, memory, disk, network statistics, and Xray process status.
type Status struct {
	ResourceScope      string   `json:"resourceScope,omitempty"`
	UnavailableMetrics []string `json:"unavailableMetrics,omitempty"`

	T           time.Time `json:"-"`
	Cpu         float64   `json:"cpu"`
	CpuCores    int       `json:"cpuCores"`
	LogicalPro  int       `json:"logicalPro"`
	CpuSpeedMhz float64   `json:"cpuSpeedMhz"`
	Mem         struct {
		Current uint64 `json:"current"`
		Total   uint64 `json:"total"`
	} `json:"mem"`
	Swap struct {
		Current uint64 `json:"current"`
		Total   uint64 `json:"total"`
	} `json:"swap"`
	Disk struct {
		Current uint64 `json:"current"`
		Total   uint64 `json:"total"`
	} `json:"disk"`
	DiskIO struct {
		Read  uint64 `json:"read"`
		Write uint64 `json:"write"`
	} `json:"diskIO"`
	DiskTraffic struct {
		Read  uint64 `json:"read"`
		Write uint64 `json:"write"`
	} `json:"diskTraffic"`
	Xray struct {
		State    ProcessState `json:"state"`
		ErrorMsg string       `json:"errorMsg"`
		Version  string       `json:"version"`
	} `json:"xray"`
	// AmneziaWG gates the overview's AmneziaWG log view: Configured stays true
	// while an inbound exists but its embedded interface isn't up yet, which
	// is exactly when that view's event lines are worth reading.
	AmneziaWG struct {
		Configured bool `json:"configured"`
		Running    bool `json:"running"`
	} `json:"amneziawg"`
	PanelVersion string    `json:"panelVersion"`
	PanelGuid    string    `json:"panelGuid"`
	Uptime       uint64    `json:"uptime"`
	Loads        []float64 `json:"loads"`
	TcpCount     int       `json:"tcpCount"`
	UdpCount     int       `json:"udpCount"`
	NetIO        struct {
		Up      uint64 `json:"up"`
		Down    uint64 `json:"down"`
		PktUp   uint64 `json:"pktUp"`
		PktDown uint64 `json:"pktDown"`
	} `json:"netIO"`
	NetTraffic struct {
		Sent    uint64 `json:"sent"`
		Recv    uint64 `json:"recv"`
		PktSent uint64 `json:"pktSent"`
		PktRecv uint64 `json:"pktRecv"`
	} `json:"netTraffic"`
	PublicIP struct {
		IPv4 string `json:"ipv4"`
		IPv6 string `json:"ipv6"`
	} `json:"publicIP"`
	AppStats struct {
		Threads uint32 `json:"threads"`
		Mem     uint64 `json:"mem"`
		Uptime  uint64 `json:"uptime"`
	} `json:"appStats"`
}

// Release represents information about a software release from GitHub.
type Release struct {
	TagName         string `json:"tag_name"`         // The tag name of the release
	Body            string `json:"body"`             // The release notes; the dev channel reads its commit from here
	TargetCommitish string `json:"target_commitish"` // The branch/commit the tag points at
	Prerelease      bool   `json:"prerelease"`       // Whether this is a pre-release
}

// ServerService provides business logic for server monitoring and management.
// It handles system status collection, IP detection, and application statistics.
type ServerService struct {
	lxcMetrics sys.LXCReader

	xrayService        XrayService
	inboundService     InboundService
	settingService     SettingService
	cachedIPv4         string
	cachedIPv6         string
	nextIPv4Lookup     time.Time
	nextIPv6Lookup     time.Time
	ipv6RetryInterval  time.Duration
	publicIPLookupDone chan struct{}
	mu                 sync.Mutex
	lastCPUTimes       cpu.TimesStat
	hasLastCPUSample   bool
	hasNativeCPUSample bool
	emaCPU             float64
	cachedCpuSpeedMhz  float64
	lastCpuInfoAttempt time.Time

	lastStatusMu sync.RWMutex
	lastStatus   *Status
	coldStatusMu sync.Mutex

	versionsCacheMu sync.Mutex
	versionsCache   *cachedXrayVersions

	fail2banMu        sync.Mutex
	fail2banInstalled bool
	fail2banCheckedAt time.Time
}

type cachedXrayVersions struct {
	versions  []string
	fetchedAt time.Time
}

// xrayVersionsCacheTTL bounds how often /getXrayVersion hits GitHub. The list
// is purely informational (rendered in the "switch Xray version" picker) so a
// quarter-hour staleness window is fine and saves the API budget.
const xrayVersionsCacheTTL = 15 * time.Minute

// allowedHistoryBuckets is the bucket-second whitelist for time-series
// aggregation endpoints (server + node metrics). Restricting it prevents
// callers from triggering arbitrary aggregation work and keeps the
// frontend's bucket selector self-documenting.
var allowedHistoryBuckets = map[int]bool{
	2:     true, // 2m
	30:    true, // 30m
	60:    true, // 1h
	180:   true, // 3h
	360:   true, // 6h
	720:   true, // 12h
	1440:  true, // 24h
	2880:  true, // 2d
	10080: true, // 7d
}

// IsAllowedHistoryBucket reports whether a bucket-seconds value is in the
// whitelist used by /server/history, /server/cpuHistory, /server/xrayMetricsHistory,
// /server/xrayObservatoryHistory, and /nodes/history.
func IsAllowedHistoryBucket(bucketSeconds int) bool {
	return allowedHistoryBuckets[bucketSeconds]
}

// LastStatus returns the most recent Status snapshot collected by
// RefreshStatus. Safe for concurrent readers.
func (s *ServerService) LastStatus() *Status {
	s.lastStatusMu.RLock()
	defer s.lastStatusMu.RUnlock()
	return s.lastStatus
}

// CurrentStatus never reports "no status yet": the @2s ticker leaves LastStatus
// nil for the first seconds after a restart, and a master probing a node then
// reads the empty snapshot as an offline panel.
func (s *ServerService) CurrentStatus() *Status {
	if status := s.LastStatus(); status != nil {
		return status
	}
	s.coldStatusMu.Lock()
	defer s.coldStatusMu.Unlock()
	if status := s.LastStatus(); status != nil {
		return status
	}
	return s.RefreshStatus()
}

// Fail2banStatus tells the frontend whether the per-client IP limit can
// actually be enforced. Enforcement depends on fail2ban, so a limit set
// without it would silently do nothing.
type Fail2banStatus struct {
	Enabled   bool `json:"enabled"`
	Installed bool `json:"installed"`
	Usable    bool `json:"usable"`
	Windows   bool `json:"windows"`
}

const fail2banInstalledCacheTTL = 30 * time.Second

func (s *ServerService) GetFail2banStatus() Fail2banStatus {
	enabled := isFail2banEnabled()

	installed := false
	if enabled {
		installed = s.isFail2banInstalled()
	}

	return Fail2banStatus{
		Enabled:   enabled,
		Installed: installed,
		Usable:    enabled && installed,
		Windows:   runtime.GOOS == "windows",
	}
}

func isFail2banEnabled() bool {
	value, ok := os.LookupEnv("XUI_ENABLE_FAIL2BAN")
	return !ok || value == "true"
}

func (s *ServerService) isFail2banInstalled() bool {
	s.fail2banMu.Lock()
	defer s.fail2banMu.Unlock()

	if !s.fail2banCheckedAt.IsZero() && time.Since(s.fail2banCheckedAt) < fail2banInstalledCacheTTL {
		return s.fail2banInstalled
	}

	err := exec.CommandContext(context.Background(), "fail2ban-client", "-h").Run()
	s.fail2banInstalled = err == nil
	s.fail2banCheckedAt = time.Now()
	return s.fail2banInstalled
}

// RefreshStatus collects a new system snapshot, stores it as LastStatus, and
// appends it to the system-metrics time series. Returns the new snapshot (may
// be nil if collection failed). Called by the background ticker; the caller is
// responsible for any side effects (websocket broadcast, xray metrics sample).
func (s *ServerService) RefreshStatus() *Status {
	next := s.GetStatus(s.LastStatus())
	if next == nil {
		return nil
	}
	s.lastStatusMu.Lock()
	s.lastStatus = next
	s.lastStatusMu.Unlock()
	s.AppendStatusSample(time.Now(), next)
	return next
}

// GetXrayVersionsCached wraps GetXrayVersions with a TTL cache. On fetch
// failure we serve the last successful list (if any) so the UI doesn't go
// blank during a GitHub API hiccup; if there's no cache at all the underlying
// error is surfaced.
func (s *ServerService) GetXrayVersionsCached() ([]string, error) {
	s.versionsCacheMu.Lock()
	cache := s.versionsCache
	s.versionsCacheMu.Unlock()
	if cache != nil && time.Since(cache.fetchedAt) <= xrayVersionsCacheTTL {
		return cache.versions, nil
	}
	versions, err := s.GetXrayVersions()
	if err != nil {
		if cache != nil {
			logger.Warning("GetXrayVersionsCached: serving stale list:", err)
			return cache.versions, nil
		}
		return nil, err
	}
	s.versionsCacheMu.Lock()
	s.versionsCache = &cachedXrayVersions{versions: versions, fetchedAt: time.Now()}
	s.versionsCacheMu.Unlock()
	return versions, nil
}

// GetDefaultLogOutboundTags scans the default Xray config for freedom and
// blackhole outbound tags so /getXrayLogs can colour-code log lines without
// the controller re-doing the JSON walk. Falls back to the historical
// "direct"/"blocked" defaults when the config can't be read.
func (s *ServerService) GetDefaultLogOutboundTags() (freedoms, blackholes []string) {
	config, err := s.settingService.GetDefaultXrayConfig()
	if err == nil && config != nil {
		if cfgMap, ok := config.(map[string]any); ok {
			if outbounds, ok := cfgMap["outbounds"].([]any); ok {
				for _, outbound := range outbounds {
					obMap, ok := outbound.(map[string]any)
					if !ok {
						continue
					}
					tag, _ := obMap["tag"].(string)
					if tag == "" {
						continue
					}
					switch obMap["protocol"] {
					case "freedom":
						freedoms = append(freedoms, tag)
					case "blackhole":
						blackholes = append(blackholes, tag)
					}
				}
			}
		}
	}
	if len(freedoms) == 0 {
		freedoms = []string{"direct"}
	}
	if len(blackholes) == 0 {
		blackholes = []string{"blocked"}
	}
	return freedoms, blackholes
}

// AggregateCpuHistory returns up to maxPoints averaged buckets of size bucketSeconds.
// Kept for back-compat with the original /panel/api/server/cpuHistory/:bucket route;
// the response key is "cpu" (not "v") so legacy consumers parse unchanged.
func (s *ServerService) AggregateCpuHistory(bucketSeconds int, maxPoints int) []map[string]any {
	out := systemMetrics.aggregate(s.systemMetricKey("cpu"), bucketSeconds, maxPoints)
	for _, p := range out {
		p["cpu"] = p["v"]
		delete(p, "v")
	}
	return out
}

// AggregateSystemMetric returns up to maxPoints averaged buckets for any
// known system metric (see SystemMetricKeys). Output points have keys
// {"t": unixSec, "v": value}; the caller decides how to format the value.
func (s *ServerService) AggregateSystemMetric(metric string, bucketSeconds int, maxPoints int) []map[string]any {
	return systemMetrics.aggregate(s.systemMetricKey(metric), bucketSeconds, maxPoints)
}

type LogEntry struct {
	DateTime    time.Time `json:"DateTime" example:"2025-01-01T12:00:00Z"`
	FromAddress string    `json:"FromAddress" example:"192.0.2.10:54321"`
	ToAddress   string    `json:"ToAddress" example:"example.com:443"`
	Inbound     string    `json:"Inbound" example:"inbound-443"`
	Outbound    string    `json:"Outbound" example:"direct"`
	Email       string    `json:"Email" example:"alice@example.com"`
	Event       int       `json:"Event" example:"0"`
}

type NewUUIDResponse struct {
	UUID string `json:"uuid" example:"550e8400-e29b-41d4-a716-446655440000"`
}

type MLDSA65Response struct {
	Seed   string `json:"seed" example:"mldsa65-seed"`
	Verify string `json:"verify" example:"mldsa65-verify"`
}

type MLKEM768Response struct {
	Seed   string `json:"seed" example:"mlkem768-seed"`
	Client string `json:"client" example:"mlkem768-client"`
}

// maxPublicIPBytes caps an IP echo service's answer; a textual IPv6 address
// with its line ending fits well within it.
const maxPublicIPBytes = 64

func getPublicIP(url string) string {
	client := &http.Client{
		Timeout: 3 * time.Second,
	}

	req, reqErr := http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
	if reqErr != nil {
		return "N/A"
	}
	resp, err := client.Do(req)
	if err != nil {
		return "N/A"
	}
	defer resp.Body.Close()

	// Don't retry if access is blocked or region-restricted
	if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusUnavailableForLegalReasons {
		return "N/A"
	}
	if resp.StatusCode != http.StatusOK {
		return "N/A"
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxPublicIPBytes))
	if err != nil {
		return "N/A"
	}

	// The answer is cached and sent with every status sample, so only a bare
	// address is accepted; an over-long one is cut above and fails to parse.
	ip, err := netip.ParseAddr(strings.TrimSpace(string(body)))
	if err != nil {
		return "N/A"
	}

	return ip.WithZone("").String()
}

var publicIPv4Services = []string{
	"https://api4.ipify.org",
	"https://ipv4.icanhazip.com",
	"https://v4.api.ipinfo.io/ip",
	"https://ipv4.myexternalip.com/raw",
	"https://4.ident.me",
	"https://check-host.net/ip",
}

var publicIPv6Services = []string{
	"https://api6.ipify.org",
	"https://ipv6.icanhazip.com",
	"https://v6.api.ipinfo.io/ip",
	"https://ipv6.myexternalip.com/raw",
	"https://6.ident.me",
}

const (
	publicIPRefreshInterval = 5 * time.Minute
	publicIPRetryInterval   = time.Minute
)

// resolvePublicIPs waits for the initial lookup so cold backups can use it.
// Warm callers use cached addresses while a refresh runs in the background.
func (s *ServerService) resolvePublicIPs() {
	ipv4, ipv6 := s.publicIPs()
	if done := s.resolvePublicIPsInBackground(); done != nil && ipv4 == "" && ipv6 == "" {
		<-done
	}
}

// refreshedPublicIP retains a known address through temporary lookup failures.
func refreshedPublicIP(cached, fetched string, now time.Time) (string, time.Time) {
	if fetched != "" && fetched != "N/A" {
		return fetched, now.Add(publicIPRefreshInterval)
	}
	if cached == "" {
		cached = "N/A"
	}
	return cached, now.Add(publicIPRetryInterval)
}

func nextPublicIPv6RetryInterval(previous time.Duration) time.Duration {
	switch {
	case previous < time.Minute:
		return time.Minute
	case previous < 2*time.Minute:
		return 2 * time.Minute
	case previous < 5*time.Minute:
		return 5 * time.Minute
	default:
		return 15 * time.Minute
	}
}

// firstPublicIP returns the first service that answers, or "N/A" when every
// one of them fails.
func firstPublicIP(services []string) string {
	var ip string
	for _, service := range services {
		ip = getPublicIP(service)
		if ip != "N/A" {
			break
		}
	}
	return ip
}

// resolvePublicIPsInBackground shares one lookup without blocking status samples.
// Each address family has its own deadline; cached values stay readable.
func (s *ServerService) resolvePublicIPsInBackground() <-chan struct{} {
	s.mu.Lock()
	if done := s.publicIPLookupDone; done != nil {
		s.mu.Unlock()
		return done
	}
	now := time.Now()
	wantIPv4 := !now.Before(s.nextIPv4Lookup)
	wantIPv6 := !now.Before(s.nextIPv6Lookup)
	if !wantIPv4 && !wantIPv6 {
		s.mu.Unlock()
		return nil
	}
	done := make(chan struct{})
	s.publicIPLookupDone = done
	s.mu.Unlock()

	go func() {
		var ipv4, ipv6 string
		if wantIPv4 {
			ipv4 = firstPublicIP(publicIPv4Services)
		}
		if wantIPv6 {
			ipv6 = firstPublicIP(publicIPv6Services)
		}

		s.mu.Lock()
		defer s.mu.Unlock()
		now := time.Now()
		if wantIPv4 {
			s.cachedIPv4, s.nextIPv4Lookup = refreshedPublicIP(s.cachedIPv4, ipv4, now)
		}
		if wantIPv6 {
			s.cachedIPv6, s.nextIPv6Lookup = refreshedPublicIP(s.cachedIPv6, ipv6, now)
			if ipv6 != "" && ipv6 != "N/A" {
				s.ipv6RetryInterval = 0
			} else {
				s.ipv6RetryInterval = nextPublicIPv6RetryInterval(s.ipv6RetryInterval)
				s.nextIPv6Lookup = now.Add(s.ipv6RetryInterval)
			}
		}
		s.publicIPLookupDone = nil
		close(done)
	}()
	return done
}

func (s *ServerService) publicIPs() (ipv4 string, ipv6 string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cachedIPv4, s.cachedIPv6
}

func (s *ServerService) GetStatus(lastStatus *Status) *Status {
	now := time.Now()
	status := &Status{
		T: now,
	}

	scoped, scopeErr := s.lxcMetrics.Read(now)
	if scopeErr != nil {
		logger.Warning("get scoped metrics failed:", scopeErr)
	}
	if scoped != nil {
		applyLXCStats(status, scoped)
	} else {
		// CPU stats
		util, err := s.sampleCPUUtilization()
		if err != nil {
			logger.Warning("get cpu percent failed:", err)
		} else {
			status.Cpu = util
		}

		status.CpuCores, err = cpu.Counts(false)
		if err != nil {
			logger.Warning("get cpu cores count failed:", err)
		}

		status.LogicalPro = runtime.NumCPU()

		if status.CpuSpeedMhz = s.cachedCpuSpeedMhz; s.cachedCpuSpeedMhz == 0 && time.Since(s.lastCpuInfoAttempt) > 5*time.Minute {
			s.lastCpuInfoAttempt = time.Now()
			done := make(chan struct{})
			go func() {
				defer close(done)
				cpuInfos, err := cpu.Info()
				if err != nil {
					logger.Warning("get cpu info failed:", err)
					return
				}
				if len(cpuInfos) > 0 {
					s.cachedCpuSpeedMhz = cpuInfos[0].Mhz
					status.CpuSpeedMhz = s.cachedCpuSpeedMhz
				} else {
					logger.Warning("could not find cpu info")
				}
			}()
			select {
			case <-done:
			case <-time.After(1500 * time.Millisecond):
				logger.Warning("cpu info query timed out; will retry later")
			}
		} else if s.cachedCpuSpeedMhz != 0 {
			status.CpuSpeedMhz = s.cachedCpuSpeedMhz
		}

		// Uptime
		upTime, err := host.Uptime()
		if err != nil {
			logger.Warning("get uptime failed:", err)
		} else {
			status.Uptime = upTime
		}
	}

	// Memory stats
	memInfo, err := mem.VirtualMemory()
	if err != nil {
		logger.Warning("get virtual memory failed:", err)
	} else {
		status.Mem.Current = memInfo.Used
		status.Mem.Total = memInfo.Total
	}

	if scoped == nil {
		swapInfo, err := mem.SwapMemory()
		if err != nil {
			logger.Warning("get swap memory failed:", err)
		} else {
			status.Swap.Current = swapInfo.Used
			status.Swap.Total = swapInfo.Total
		}
	}

	// Disk stats
	diskInfo, err := disk.Usage("/")
	if err != nil {
		logger.Warning("get disk usage failed:", err)
	} else {
		status.Disk.Current = diskInfo.Used
		status.Disk.Total = diskInfo.Total
	}

	diskIOStats, err := disk.IOCounters()
	if err != nil {
		logger.Warning("get disk io counters failed:", err)
	} else {
		var totalRead, totalWrite uint64
		for _, counter := range diskIOStats {
			totalRead += counter.ReadBytes
			totalWrite += counter.WriteBytes
		}
		status.DiskTraffic.Read = totalRead
		status.DiskTraffic.Write = totalWrite

		if lastStatus != nil {
			duration := now.Sub(lastStatus.T)
			seconds := float64(duration) / float64(time.Second)
			if seconds > 0 && status.DiskTraffic.Read >= lastStatus.DiskTraffic.Read {
				status.DiskIO.Read = uint64(float64(status.DiskTraffic.Read-lastStatus.DiskTraffic.Read) / seconds)
			}
			if seconds > 0 && status.DiskTraffic.Write >= lastStatus.DiskTraffic.Write {
				status.DiskIO.Write = uint64(float64(status.DiskTraffic.Write-lastStatus.DiskTraffic.Write) / seconds)
			}
		}
	}

	// Load averages
	avgState, err := load.Avg()
	if err != nil {
		logger.Warning("get load avg failed:", err)
	} else {
		status.Loads = []float64{avgState.Load1, avgState.Load5, avgState.Load15}
	}

	// Network stats
	ioStats, err := net.IOCounters(true)
	if err != nil {
		logger.Warning("get io counters failed:", err)
	} else {
		var totalSent, totalRecv, totalPktSent, totalPktRecv uint64
		for _, iface := range ioStats {
			name := strings.ToLower(iface.Name)
			if isVirtualInterface(name) {
				continue
			}
			totalSent += iface.BytesSent
			totalRecv += iface.BytesRecv
			totalPktSent += iface.PacketsSent
			totalPktRecv += iface.PacketsRecv
		}
		status.NetTraffic.Sent = totalSent
		status.NetTraffic.Recv = totalRecv
		status.NetTraffic.PktSent = totalPktSent
		status.NetTraffic.PktRecv = totalPktRecv

		if lastStatus != nil {
			duration := now.Sub(lastStatus.T)
			seconds := float64(duration) / float64(time.Second)
			up := uint64(float64(status.NetTraffic.Sent-lastStatus.NetTraffic.Sent) / seconds)
			down := uint64(float64(status.NetTraffic.Recv-lastStatus.NetTraffic.Recv) / seconds)
			status.NetIO.Up = up
			status.NetIO.Down = down
			if seconds > 0 && status.NetTraffic.PktSent >= lastStatus.NetTraffic.PktSent {
				status.NetIO.PktUp = uint64(float64(status.NetTraffic.PktSent-lastStatus.NetTraffic.PktSent) / seconds)
			}
			if seconds > 0 && status.NetTraffic.PktRecv >= lastStatus.NetTraffic.PktRecv {
				status.NetIO.PktDown = uint64(float64(status.NetTraffic.PktRecv-lastStatus.NetTraffic.PktRecv) / seconds)
			}
		}
	}

	// TCP/UDP connections
	status.TcpCount, err = sys.GetTCPCount()
	if err != nil {
		logger.Warning("get tcp connections failed:", err)
	}

	status.UdpCount, err = sys.GetUDPCount()
	if err != nil {
		logger.Warning("get udp connections failed:", err)
	}

	s.resolvePublicIPsInBackground()
	status.PublicIP.IPv4, status.PublicIP.IPv6 = s.publicIPs()

	// Xray status
	if s.xrayService.IsXrayRunning() {
		status.Xray.State = Running
		// A core that runs but was refused the new config is a fault the
		// operator only ever sees here and in the node list.
		status.Xray.ErrorMsg = s.xrayService.GetHeldBackConfig()
	} else {
		err := s.xrayService.GetXrayErr()
		if err != nil {
			status.Xray.State = Error
		} else {
			status.Xray.State = Stop
		}
		status.Xray.ErrorMsg = s.xrayService.GetXrayResult()
	}
	status.Xray.Version = s.xrayService.GetXrayVersion()

	var amneziawgCount int64
	if err := database.GetDB().Model(model.Inbound{}).
		Where("protocol = ? AND enable = ? AND node_id IS NULL", model.AmneziaWG, true).
		Count(&amneziawgCount).Error; err != nil {
		logger.Warning("count amneziawg inbounds failed:", err)
	}
	status.AmneziaWG.Configured = amneziawgCount > 0
	status.AmneziaWG.Running = amneziawgnet.GetManager().HasRunning() || amneziawgkern.GetManager().HasRunning()

	status.PanelVersion = config.GetPanelVersion()
	if guid, err := s.settingService.GetPanelGuid(); err == nil {
		status.PanelGuid = guid
	}

	// Application stats
	if rss := sys.SelfRSS(); rss > 0 {
		status.AppStats.Mem = rss
	} else {
		var rtm runtime.MemStats
		runtime.ReadMemStats(&rtm)
		status.AppStats.Mem = rtm.Sys
	}
	status.AppStats.Threads = uint32(runtime.NumGoroutine())
	if process := currentXrayProcess(); process != nil && process.IsRunning() {
		status.AppStats.Uptime = process.GetUptime()
	} else {
		status.AppStats.Uptime = 0
	}

	return status
}

// AppendCpuSample is preserved for callers that only have the CPU number.
// New callers should prefer AppendStatusSample which writes the full set.
func (s *ServerService) AppendCpuSample(t time.Time, v float64) {
	systemMetrics.append(s.systemMetricKey("cpu"), t, v)
}

// AppendStatusSample writes one tick of every metric we keep — CPU, memory
// percent, network throughput (bytes/s), online client count, and the three
// load averages. Called by RefreshStatus on the same @2s cadence as
// AppendCpuSample, so all series stay aligned.
func (s *ServerService) AppendStatusSa…11978 tokens truncated…rorf("Error saving db: %v", err)
	}
	return nil
}

// IsValidGeofileName validates that the filename is safe for geofile operations.
// It checks for path traversal attempts and ensures the filename contains only safe characters.
func (s *ServerService) IsValidGeofileName(filename string) bool {
	if filename == "" {
		return false
	}

	// Check for path traversal attempts
	if strings.Contains(filename, "..") {
		return false
	}

	// Check for path separators (both forward and backward slash)
	if strings.ContainsAny(filename, `/\`) {
		return false
	}

	// Check for absolute path indicators
	if filepath.IsAbs(filename) {
		return false
	}

	// Additional security: only allow alphanumeric, dots, underscores, and hyphens
	// This is stricter than the general filename regex
	validGeofilePattern := `^[a-zA-Z0-9._-]+\.dat$`
	matched, _ := regexp.MatchString(validGeofilePattern, filename)
	return matched
}

// Repo is the upstream release base and Asset the name it publishes under; all
// three publish "geoip.dat", so only FileName tells the local copies apart.
type geofileEntry struct {
	Repo     string
	Asset    string
	FileName string
}

var geofileAllowlist = map[string]geofileEntry{
	"geoip.dat":      {"https://github.com/Loyalsoldier/v2ray-rules-dat", "geoip.dat", "geoip.dat"},
	"geosite.dat":    {"https://github.com/Loyalsoldier/v2ray-rules-dat", "geosite.dat", "geosite.dat"},
	"geoip_IR.dat":   {"https://github.com/chocolate4u/Iran-v2ray-rules", "geoip.dat", "geoip_IR.dat"},
	"geosite_IR.dat": {"https://github.com/chocolate4u/Iran-v2ray-rules", "geosite.dat", "geosite_IR.dat"},
	"geoip_RU.dat":   {"https://github.com/runetfreedom/russia-v2ray-rules-dat", "geoip.dat", "geoip_RU.dat"},
	"geosite_RU.dat": {"https://github.com/runetfreedom/russia-v2ray-rules-dat", "geosite.dat", "geosite_RU.dat"},
}

// GeodataSource identifies a file Xray downloads through its geodata configuration.
type GeodataSource struct {
	URL  string `json:"url"`
	File string `json:"file"`
}

// StandardGeodataSources derives the panel presets from the geofile update allowlist.
func StandardGeodataSources() []GeodataSource {
	sources := make([]GeodataSource, 0, len(geofileAllowlist))
	for _, entry := range geofileAllowlist {
		sources = append(sources, GeodataSource{URL: entry.latestURL(), File: entry.FileName})
	}
	slices.SortFunc(sources, func(a, b GeodataSource) int { return strings.Compare(a.File, b.File) })
	return sources
}

func (entry geofileEntry) latestURL() string {
	return entry.Repo + "/releases/latest/download/" + entry.Asset
}

func (entry geofileEntry) taggedURL(tag string) string {
	return entry.Repo + "/releases/download/" + tag + "/" + entry.Asset
}

// stagedGeofile is a verified download waiting to be moved into the asset folder.
type stagedGeofile struct {
	destPath  string
	stagePath string
}

// restartXrayAfterGeofileUpdate is a seam: tests assert that an update which
// installed nothing also restarted nothing.
var restartXrayAfterGeofileUpdate = (*ServerService).RestartXrayService

func (s *ServerService) UpdateGeofile(fileName string) error {
	// Strict allowlist check to avoid writing uncontrolled files
	if fileName != "" {
		if _, ok := geofileAllowlist[fileName]; !ok {
			return common.NewErrorf("Invalid geofile name: %q not in allowlist", fileName)
		}
	}

	wanted := geofileAllowlist
	if fileName != "" {
		wanted = map[string]geofileEntry{fileName: geofileAllowlist[fileName]}
	}

	// Atomic per upstream, not across all six: one release's databases belong
	// together, but a failing repo must not discard another repo's good files.
	byRepo := make(map[string][]geofileEntry, len(wanted))
	for _, entry := range wanted {
		byRepo[entry.Repo] = append(byRepo[entry.Repo], entry)
	}
	repos := slices.Sorted(maps.Keys(byRepo))

	binFolder := config.GetBinFolderPath()
	stageDir, err := os.MkdirTemp(binFolder, "geofile-")
	if err != nil {
		return common.NewErrorf("Failed to create staging folder for Geofiles: %v", err)
	}
	defer os.RemoveAll(stageDir)

	client := s.settingService.NewProxiedHTTPClient(0)

	var errorMessages []string
	installed := 0
	for _, repo := range repos {
		entries := byRepo[repo]
		slices.SortFunc(entries, func(a, b geofileEntry) int { return strings.Compare(a.FileName, b.FileName) })

		staged, err := s.stageGeofileRelease(client, entries, binFolder, stageDir)
		if err != nil {
			errorMessages = append(errorMessages, err.Error())
			continue
		}
		for _, file := range staged {
			if err := os.Rename(file.stagePath, file.destPath); err != nil {
				errorMessages = append(errorMessages, fmt.Sprintf("Failed to install Geofile %s: %v", file.destPath, err))
				continue
			}
			installed++
		}
	}

	// Nothing changed, so there is no reason to restart the core and drop every
	// client connection.
	if installed > 0 {
		if err := restartXrayAfterGeofileUpdate(s); err != nil {
			errorMessages = append(errorMessages, fmt.Sprintf("Updated Geofiles but Failed to start Xray: %v", err))
		}
	}

	if len(errorMessages) > 0 {
		return common.NewErrorf("%s", strings.Join(errorMessages, "\r\n"))
	}

	return nil
}

// stageGeofileRelease downloads one upstream's databases and verifies each
// against a digest from the same release, staging all of them or none.
func (s *ServerService) stageGeofileRelease(client *http.Client, entries []geofileEntry, binFolder, stageDir string) ([]stagedGeofile, error) {
	// Resolve "latest" once. These upstreams publish several times a day, and a
	// release landing mid-batch would check one release's digest against another's bytes.
	tag, err := resolveGeofileTag(client, entries[0].latestURL())
	if err != nil {
		return nil, common.NewErrorf("Error resolving Geofile release from %s: %v", entries[0].Repo, err)
	}

	var staged []stagedGeofile
	for _, entry := range entries {
		destPath := filepath.Join(binFolder, entry.FileName)
		stagePath := filepath.Join(stageDir, entry.FileName)
		changed, err := s.stageGeofile(client, entry, tag, destPath, stagePath)
		if err != nil {
			return nil, common.NewErrorf("Error downloading Geofile '%s': %v", entry.FileName, err)
		}
		if changed {
			staged = append(staged, stagedGeofile{destPath: destPath, stagePath: stagePath})
		}
	}
	return staged, nil
}

// resolveGeofileTag reads the immutable release tag a `latest` download
// redirects to, so the asset and its digest cannot come from two releases.
func resolveGeofileTag(client *http.Client, latestURL string) (string, error) {
	pinned := *client
	pinned.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, latestURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := pinned.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	location := resp.Header.Get("Location")
	if location == "" {
		return "", common.NewErrorf("expected a redirect to a tagged release, got HTTP %d", resp.StatusCode)
	}
	return geofileTagFromLocation(location)
}

// geofileTagFromLocation pulls <tag> out of a .../releases/download/<tag>/<asset>
// redirect target.
func geofileTagFromLocation(location string) (string, error) {
	const marker = "/releases/download/"
	_, after, ok := strings.Cut(location, marker)
	if !ok {
		return "", common.NewErrorf("unexpected release redirect %q", location)
	}
	tag, _, found := strings.Cut(after, "/")
	if !found || tag == "" {
		return "", common.NewErrorf("unexpected release redirect %q", location)
	}
	return tag, nil
}

// stageGeofile downloads one database into stagePath and checks it against the
// SHA-256 its upstream publishes. It reports false on 304, staging nothing.
func (s *ServerService) stageGeofile(client *http.Client, entry geofileEntry, tag, destPath, stagePath string) (bool, error) {
	assetURL := entry.taggedURL(tag)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, assetURL, nil)
	if err != nil {
		return false, common.NewErrorf("Failed to create HTTP request for %s: %v", assetURL, err)
	}

	if fileInfo, err := os.Stat(destPath); err == nil {
		if localFileModTime := fileInfo.ModTime(); !localFileModTime.IsZero() {
			req.Header.Set("If-Modified-Since", localFileModTime.UTC().Format(http.TimeFormat))
		}
	}

	resp, err := client.Do(req)
	if err != nil {
		return false, common.NewErrorf("Failed to download Geofile from %s: %v", assetURL, err)
	}
	defer resp.Body.Close()

	// Parse Last-Modified header from server
	var serverModTime time.Time
	if serverModTimeStr := resp.Header.Get("Last-Modified"); serverModTimeStr != "" {
		parsedTime, err := time.Parse(http.TimeFormat, serverModTimeStr)
		if err != nil {
			logger.Warningf("Failed to parse Last-Modified header for %s: %v", assetURL, err)
		} else {
			serverModTime = parsedTime
		}
	}

	// The conditional GET above reads this back, so it must survive the rename.
	setModTime := func(target string) {
		if !serverModTime.IsZero() {
			if err := os.Chtimes(target, serverModTime, serverModTime); err != nil {
				logger.Warningf("Failed to update modification time for %s: %v", target, err)
			}
		}
	}

	// Handle 304 Not Modified
	if resp.StatusCode == http.StatusNotModified {
		setModTime(destPath)
		return false, nil
	}

	if resp.StatusCode != http.StatusOK {
		return false, common.NewErrorf("Failed to download Geofile from %s: received status code %d", assetURL, resp.StatusCode)
	}

	file, err := os.Create(stagePath)
	if err != nil {
		return false, common.NewErrorf("Failed to create Geofile %s: %v", stagePath, err)
	}
	hasher := sha256.New()
	if _, err := io.Copy(io.MultiWriter(file, hasher), resp.Body); err != nil {
		file.Close()
		return false, common.NewErrorf("Failed to save Geofile %s: %v", stagePath, err)
	}
	if err := file.Close(); err != nil {
		return false, common.NewErrorf("Failed to save Geofile %s: %v", stagePath, err)
	}

	// TLS protects the transport, not the artifact. Xray parses these databases
	// when it builds its routing matchers, so a bad one takes the core down.
	want, err := s.fetchGeofileDigest(client, assetURL+".sha256sum", entry.Asset)
	if err != nil {
		return false, err
	}
	if got := hex.EncodeToString(hasher.Sum(nil)); !strings.EqualFold(got, want) {
		return false, common.NewErrorf("does not match the published SHA-256 checksum, so the download is corrupted or has been tampered with (expected %s, got %s)", want, got)
	}

	setModTime(stagePath)
	return true, nil
}

// fetchGeofileDigest downloads the .sha256sum sidecar published beside a geo
// database and returns the digest it lists for assetName.
func (s *ServerService) fetchGeofileDigest(client *http.Client, sumsURL, assetName string) (string, error) {
	req, reqErr := http.NewRequestWithContext(context.Background(), http.MethodGet, sumsURL, nil)
	if reqErr != nil {
		return "", fmt.Errorf("download geofile checksum: %w", reqErr)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("download geofile checksum: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download geofile checksum: unexpected HTTP %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxXrayDigestBytes))
	if err != nil {
		return "", fmt.Errorf("download geofile checksum: %w", err)
	}
	return parseGeofileDigest(raw, assetName)
}

// parseGeofileDigest returns the SHA-256 hex a sidecar lists for assetName,
// matching on base name since upstreams record "geoip.dat" or "release/geoip.dat".
func parseGeofileDigest(sums []byte, assetName string) (string, error) {
	for line := range strings.SplitSeq(string(sums), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		// A leading "*" is sha256sum's own binary-mode marker, not part of the name.
		if path.Base(strings.TrimPrefix(fields[1], "*")) != assetName {
			continue
		}
		digest := strings.ToLower(fields[0])
		if _, err := hex.DecodeString(digest); err != nil || len(digest) != sha256.Size*2 {
			return "", fmt.Errorf("geofile checksum: malformed SHA-256 entry for %s", assetName)
		}
		return digest, nil
	}
	return "", fmt.Errorf("geofile checksum: no SHA-256 entry for %s", assetName)
}

// parseXrayKeyPairOutput reads the two-line "Label: value" output that xray's
// key-generation subcommands (x25519, mldsa65, mlkem768) print and returns the
// two values. Short or label-less output yields an error instead of panicking
// on an out-of-range slice index, so a future xray version that changes the
// format degrades to a 500 with a message rather than a crash.
func parseXrayKeyPairOutput(output string) (string, string, error) {
	lines := strings.Split(output, "\n")
	if len(lines) < 2 {
		return "", "", common.NewError("unexpected key generator output")
	}
	first := strings.Split(lines[0], ":")
	second := strings.Split(lines[1], ":")
	if len(first) < 2 || len(second) < 2 {
		return "", "", common.NewError("unexpected key generator output")
	}
	return strings.TrimSpace(first[1]), strings.TrimSpace(second[1]), nil
}

func (s *ServerService) GetNewX25519Cert() (any, error) {
	// Run the command
	cmd := exec.CommandContext(context.Background(), xray.GetBinaryPath(), "x25519")
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return nil, err
	}

	privateKey, publicKey, err := parseXrayKeyPairOutput(out.String())
	if err != nil {
		return nil, err
	}

	keyPair := map[string]any{
		"privateKey": privateKey,
		"publicKey":  publicKey,
	}

	return keyPair, nil
}

func (s *ServerService) GetNewmldsa65() (*MLDSA65Response, error) {
	// Run the command
	cmd := exec.CommandContext(context.Background(), xray.GetBinaryPath(), "mldsa65")
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return nil, err
	}

	seed, verify, err := parseXrayKeyPairOutput(out.String())
	if err != nil {
		return nil, err
	}

	keyPair := &MLDSA65Response{
		Seed:   seed,
		Verify: verify,
	}

	return keyPair, nil
}

// GetCertHash parses a certificate (from a file path or inline PEM/DER content)
// and returns the hex-encoded SHA-256 over each certificate's raw DER — the
// value xray-core's pinnedPeerCertSha256 (pcs) expects. Lets the panel fill the
// pinned-cert field from the inbound's own certificate without the user
// computing the hash by hand.
func (s *ServerService) GetCertHash(certFile string, certContent string) ([]string, error) {
	var certBytes []byte
	if path := strings.TrimSpace(certFile); path != "" {
		// Guard against path traversal: only hash certificate files the panel
		// already references in its own configuration (an inbound's TLS
		// certificateFile or the panel's own web cert). The path is opened only
		// after this allow-list check, relative to its containing directory.
		known, ok := s.resolveKnownCertFile(path)
		if !ok {
			return nil, common.NewError("certificate file is not referenced by any inbound or panel setting")
		}
		b, err := xray.ReadConfiguredCertFile(filepath.Dir(known), filepath.Base(known))
		if err != nil {
			return nil, err
		}
		certBytes = b
	} else if strings.TrimSpace(certContent) != "" {
		certBytes = []byte(certContent)
	} else {
		return nil, common.NewError("no certificate provided")
	}

	var certs []*x509.Certificate
	if bytes.Contains(certBytes, []byte("BEGIN")) {
		rest := certBytes
		for {
			block, remain := pem.Decode(rest)
			if block == nil {
				break
			}
			cert, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				return nil, common.NewError("unable to decode certificate: ", err)
			}
			certs = append(certs, cert)
			rest = remain
		}
	} else {
		parsed, err := x509.ParseCertificates(certBytes)
		if err != nil {
			return nil, common.NewError("unable to parse certificates: ", err)
		}
		certs = parsed
	}

	if len(certs) == 0 {
		return nil, common.NewError("no certificates found")
	}

	hashes := make([]string, 0, len(certs))
	for _, cert := range certs {
		sum := sha256.Sum256(cert.Raw)
		hashes = append(hashes, hex.EncodeToString(sum[:]))
	}
	return hashes, nil
}

// resolveKnownCertFile checks the caller-supplied certificate path against the
// set of certificate files the panel already references (inbound TLS configs
// plus the panel's own web cert) and, on a match, returns the path taken from
// that configuration — not the caller's value. This both confines reads to
// known certificates and breaks the user-input-to-filesystem taint flow.
func (s *ServerService) resolveKnownCertFile(certFile string) (string, bool) {
	want := filepath.Clean(certFile)
	for _, known := range s.knownCertFiles() {
		if filepath.Clean(known) == want {
			return known, true
		}
	}
	return "", false
}

// knownCertFiles collects every certificate file path the panel legitimately
// references: the certificateFile of each inbound's TLS settings and the
// panel's own web TLS certificate.
func (s *ServerService) knownCertFiles() []string {
	var files []string
	if cert, err := s.settingService.GetCertFile(); err == nil {
		if cert = strings.TrimSpace(cert); cert != "" {
			files = append(files, cert)
		}
	}
	if inbounds, err := s.inboundService.GetAllInbounds(); err == nil {
		for _, inbound := range inbounds {
			// A node row's path names a file on the node's host, not on this one.
			if inbound.NodeID != nil {
				continue
			}
			files = collectCertFiles(inbound.StreamSettings, files)
		}
	}
	return files
}

// collectCertFiles walks a stream-settings JSON document and appends the value
// of every "certificateFile" field it finds (TLS settings may nest them under
// several keys depending on the security type).
func collectCertFiles(streamSettings string, out []string) []string {
	streamSettings = strings.TrimSpace(streamSettings)
	if streamSettings == "" {
		return out
	}
	var parsed any
	if err := json.Unmarshal([]byte(streamSettings), &parsed); err != nil {
		return out
	}
	return walkCertFiles(parsed, out)
}

func walkCertFiles(node any, out []string) []string {
	switch v := node.(type) {
	case map[string]any:
		for key, val := range v {
			if key == "certificateFile" {
				if path, ok := val.(string); ok {
					if path = strings.TrimSpace(path); path != "" {
						out = append(out, path)
					}
				}
			}
			out = walkCertFiles(val, out)
		}
	case []any:
		for _, item := range v {
			out = walkCertFiles(item, out)
		}
	}
	return out
}

// GetRemoteCertHash opens a uTLS (Chrome fingerprint) handshake to a remote
// endpoint and returns the hex-encoded SHA-256 of its leaf certificate — the
// value to put in pinnedPeerCertSha256 (pcs) when pinning a server whose
// certificate file you don't hold (a CDN front, a REALITY dest, an external
// proxy). A native handshake replaces the old `xray tls ping` subprocess so the
// real dial/handshake failure (connection refused, timeout, …) surfaces
// verbatim. `server` may be host or host:port; the port defaults to 443.
// allowPrivate lifts the SSRF guard for this one probe (the panel's confirmed opt-in).
func (s *ServerService) GetRemoteCertHash(server string, allowPrivate bool) ([]string, error) {
	server = strings.TrimSpace(server)
	if server == "" {
		return nil, common.NewError("no server provided")
	}

	host, port := server, "443"
	if h, p, err := stdnet.SplitHostPort(server); err == nil {
		host, port = h, p
	}

	ctx, cancel := context.WithTimeout(netsafe.ContextWithAllowPrivate(context.Background(), allowPrivate), 10*time.Second)
	defer cancel()
	tcpConn, err := netsafe.SSRFGuardedDialContext(ctx, "tcp", stdnet.JoinHostPort(host, port))
	if err != nil {
		return nil, fmt.Errorf("failed to dial %s: %w", stdnet.JoinHostPort(host, port), err)
	}
	defer tcpConn.Close()
	_ = tcpConn.SetDeadline(time.Now().Add(15 * time.Second))

	tlsConn := utls.UClient(tcpConn, &utls.Config{
		ServerName:         host,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h2", "http/1.1"},
	}, utls.HelloChrome_Auto)
	defer tlsConn.Close()
	if err := tlsConn.Handshake(); err != nil {
		return nil, common.NewErrorf("tls handshake with %s failed: %s", host, err)
	}

	certs := tlsConn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return nil, common.NewError("no certificate returned by ", host)
	}
	// PeerCertificates[0] is always the leaf the connection verifies against —
	// robust for IP-only self-signed certs that carry no DNS SANs.
	sum := sha256.Sum256(certs[0].Raw)
	return []string{hex.EncodeToString(sum[:])}, nil
}

func (s *ServerService) GetNewEchCert(sni string) (any, error) {
	// Run the command
	cmd := exec.CommandContext(context.Background(), xray.GetBinaryPath(), "tls", "ech", "--serverName", sni)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return nil, err
	}

	lines := strings.Split(out.String(), "\n")
	if len(lines) < 4 {
		return nil, common.NewError("invalid ech cert")
	}

	configList := lines[1]
	serverKeys := lines[3]

	return map[string]any{
		"echServerKeys": serverKeys,
		"echConfigList": configList,
	}, nil
}

func (s *ServerService) GetNewVlessEnc() (any, error) {
	cmd := exec.CommandContext(context.Background(), xray.GetBinaryPath(), "vlessenc")
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return nil, err
	}

	auths := parseVlessEncAuths(out.String())
	auths = append(auths, deriveVlessEncModes(auths)...)

	return map[string]any{
		"auths": auths,
	}, nil
}

func deriveVlessEncModes(auths []map[string]string) []map[string]string {
	var extra []map[string]string
	for _, a := range auths {
		for _, mode := range []string{"xorpub", "random"} {
			dec := strings.Replace(a["decryption"], ".native.", "."+mode+".", 1)
			enc := strings.Replace(a["encryption"], ".native.", "."+mode+".", 1)
			if dec == a["decryption"] && enc == a["encryption"] {
				continue
			}
			extra = append(extra, map[string]string{
				"id":         a["id"] + "_" + mode,
				"label":      a["label"] + " (" + mode + ")",
				"decryption": dec,
				"encryption": enc,
			})
		}
	}
	return extra
}

func parseVlessEncAuths(output string) []map[string]string {
	lines := strings.Split(output, "\n")
	var auths []map[string]string
	var current map[string]string

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Authentication:") {
			if current != nil {
				auths = append(auths, current)
			}
			label := strings.TrimSpace(strings.TrimPrefix(line, "Authentication:"))
			current = map[string]string{
				"id":    vlessEncAuthID(label),
				"label": label,
			}
		} else if strings.HasPrefix(line, `"decryption"`) || strings.HasPrefix(line, `"encryption"`) {
			parts := strings.SplitN(line, ":", 2)
			if len(parts) == 2 && current != nil {
				key := strings.Trim(parts[0], `" `)
				val := strings.TrimSpace(parts[1])
				val = strings.TrimSuffix(val, ",")
				val = strings.Trim(val, `" `)
				current[key] = val
			}
		}
	}

	if current != nil {
		auths = append(auths, current)
	}

	return auths
}

func vlessEncAuthID(label string) string {
	normalized := strings.NewReplacer("-", "", "_", "", " ", "").Replace(strings.ToLower(label))
	switch {
	case strings.Contains(normalized, "mlkem768"):
		return "mlkem768"
	case strings.Contains(normalized, "x25519"):
		return "x25519"
	default:
		return normalized
	}
}

func (s *ServerService) GetNewUUID() (*NewUUIDResponse, error) {
	newUUID, err := uuid.NewRandom()
	if err != nil {
		return nil, fmt.Errorf("failed to generate UUID: %w", err)
	}

	return &NewUUIDResponse{
		UUID: newUUID.String(),
	}, nil
}

func (s *ServerService) GetNewmlkem768() (*MLKEM768Response, error) {
	// Run the command
	cmd := exec.CommandContext(context.Background(), xray.GetBinaryPath(), "mlkem768")
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return nil, err
	}

	seed, client, err := parseXrayKeyPairOutput(out.String())
	if err != nil {
		return nil, err
	}

	keyPair := &MLKEM768Response{
		Seed:   seed,
		Client: client,
	}

	return keyPair, nil
}

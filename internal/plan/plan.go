package plan

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"
	"lukechampine.com/blake3"
)

const maxSafeInteger = 1<<53 - 1
const maxDepth = 128

var unsafeName = regexp.MustCompile(`[^a-z0-9_-]+`)

type Options struct {
	Ingest  RootSpec
	Archive RootSpec
	Date    string
	Device  string
	Project string
}

type Observation struct {
	Path        string `json:"source_relative_path"`
	AssetID     string `json:"asset_id"`
	SizeBytes   int64  `json:"size_bytes"`
	SourceInode uint64 `json:"source_inode"`
	ModifiedAt  string `json:"modified_at"`
	TargetPath  string `json:"archive_relative_path"`
	Action      string `json:"action"`
	DuplicateOf string `json:"duplicate_of,omitempty"`
}

type Issue struct {
	Path   string `json:"relative_path"`
	Reason string `json:"reason"`
}

type Plan struct {
	SchemaVersion int           `json:"schema_version"`
	Ingest        RootIdentity  `json:"ingest"`
	Archive       RootIdentity  `json:"archive"`
	RecordingDate *string       `json:"recording_date"`
	DeviceID      *string       `json:"device_id"`
	ProjectID     *string       `json:"project_id"`
	Complete      bool          `json:"complete"`
	SourceBytes   int64         `json:"source_bytes"`
	CopyBytes     int64         `json:"proposed_copy_bytes"`
	Rows          []Observation `json:"rows"`
	Issues        []Issue       `json:"issues"`
}

type Result struct {
	Digest string `json:"plan_sha256"`
	Plan   Plan   `json:"plan"`
}

// Build opens both admitted roots read-only and inspects proposed destinations.
// The returned observations describe a plan only. They authorize no writes.
func Build(options Options) (Result, error) {
	if options.Ingest.ID == options.Archive.ID || rootOverlap(options.Ingest.Path, options.Archive.Path) {
		return Result{}, fmt.Errorf("ingest and archive roots must be distinct and disjoint")
	}
	date, device, err := layout(options)
	if err != nil {
		return Result{}, err
	}
	ingest, err := openRoot(options.Ingest)
	if err != nil {
		return Result{}, err
	}
	defer ingest.file.Close()
	archive, err := openRoot(options.Archive)
	if err != nil {
		return Result{}, err
	}
	defer archive.file.Close()
	if ingest.Device == archive.Device && ingest.Inode == archive.Inode {
		return Result{}, fmt.Errorf("ingest and archive resolve to the same directory")
	}

	plan := Plan{
		SchemaVersion: 1, Ingest: ingest.RootIdentity, Archive: archive.RootIdentity,
		RecordingDate: optional(options.Date), DeviceID: optional(options.Device),
		ProjectID: optional(options.Project), Rows: []Observation{}, Issues: []Issue{},
	}
	scan(ingest.file, "", ingest.Device, 0, &plan)
	slices.SortFunc(plan.Rows, func(a, b Observation) int { return strings.Compare(a.Path, b.Path) })
	first := make(map[string]Observation)
	for i := range plan.Rows {
		row := &plan.Rows[i]
		if previous, ok := first[row.AssetID]; ok {
			row.TargetPath = previous.TargetPath
			row.DuplicateOf = previous.Path
			row.Action = "duplicate"
			continue
		}
		row.TargetPath = targetPath(row.Path, row.AssetID, date, device)
		row.Action, err = inspectDestination(archive, row.TargetPath, row.AssetID)
		if err != nil {
			plan.issue(row.TargetPath, "destination: "+err.Error())
		}
		if row.Action == "copy" {
			plan.CopyBytes += row.SizeBytes
		}
		first[row.AssetID] = *row
	}
	if err := checkRoot(options.Ingest, plan.Ingest); err != nil {
		return Result{}, err
	}
	if err := checkRoot(options.Archive, plan.Archive); err != nil {
		return Result{}, err
	}
	slices.SortFunc(plan.Issues, func(a, b Issue) int {
		if order := strings.Compare(a.Path, b.Path); order != 0 {
			return order
		}
		return strings.Compare(a.Reason, b.Reason)
	})
	plan.Complete = len(plan.Rows) > 0 && len(plan.Issues) == 0
	canonical, err := json.Marshal(plan)
	if err != nil {
		return Result{}, err
	}
	return Result{Digest: fmt.Sprintf("%x", sha256.Sum256(canonical)), Plan: plan}, nil
}

func optional(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func layout(options Options) (date, device string, err error) {
	date, device = "undated", "unknown-device"
	if options.Date != "" {
		if parsed, err := time.Parse("2006-01-02", options.Date); err != nil || parsed.Format("2006-01-02") != options.Date {
			return "", "", fmt.Errorf("date must be YYYY-MM-DD")
		}
		date = options.Date
	}
	if options.Device != "" {
		if !rootIDPattern.MatchString(options.Device) || options.Device == "." || options.Device == ".." {
			return "", "", fmt.Errorf("device must be a safe lowercase identifier")
		}
		device = options.Device
	}
	return date, device, nil
}

func targetPath(source, assetID, date, device string) string {
	base := strings.ToLower(path.Base(source))
	suffix := path.Ext(base)
	stem := unsafeName.ReplaceAllString(strings.TrimSuffix(base, suffix), "-")
	stem = strings.Trim(stem, "-_")
	if stem == "" {
		stem = "asset"
	}
	if len(stem) > 72 {
		stem = stem[:72]
	}
	if len(suffix) > 12 || unsafeName.MatchString(strings.TrimPrefix(suffix, ".")) {
		suffix = ""
	}
	return path.Join("Originals", device, date, stem+"--"+strings.TrimPrefix(assetID, "blake3:")+suffix)
}

func (p *Plan) issue(name, reason string) {
	p.Issues = append(p.Issues, Issue{Path: name, Reason: reason})
}

func scan(directory *os.File, prefix string, device uint64, depth int, plan *Plan) {
	if depth > maxDepth {
		plan.issue(prefix, "directory depth exceeds plan limit")
		return
	}
	entries, err := directory.ReadDir(-1)
	if err != nil {
		plan.issue(prefix, "directory read failed: "+err.Error())
		return
	}
	fd := int(directory.Fd())
	for _, entry := range entries {
		name := entry.Name()
		relative := path.Join(prefix, name)
		if prefix == "" && name == Marker {
			continue
		}
		if !utf8.ValidString(name) || strings.ContainsAny(name, "\\\x00\n\r") {
			plan.issue(relative, "filename cannot be represented unambiguously in a plan")
			continue
		}
		var info unix.Stat_t
		if err := unix.Fstatat(fd, name, &info, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			plan.issue(relative, "file stat failed: "+err.Error())
			continue
		}
		if uint64(info.Dev) != device {
			plan.issue(relative, "nested volume is outside the admitted root")
			continue
		}
		switch info.Mode & unix.S_IFMT {
		case unix.S_IFDIR:
			child, err := unix.Openat(fd, name, directoryFlags, 0)
			if err != nil {
				plan.issue(relative, "directory open failed: "+err.Error())
				continue
			}
			childDir := os.NewFile(uintptr(child), relative)
			var opened unix.Stat_t
			if unix.Fstat(child, &opened) != nil || opened.Ino != info.Ino || opened.Dev != info.Dev {
				plan.issue(relative, "directory identity changed before scan")
			} else {
				scan(childDir, relative, device, depth+1, plan)
				if err := unix.Fstatat(fd, name, &opened, unix.AT_SYMLINK_NOFOLLOW); err != nil ||
					opened.Ino != info.Ino || opened.Dev != info.Dev || opened.Mode&unix.S_IFMT != unix.S_IFDIR {
					plan.issue(relative, "directory identity changed during scan")
				}
			}
			childDir.Close()
		case unix.S_IFREG:
			row, err := hashFile(fd, name, relative, info)
			if err != nil {
				plan.issue(relative, err.Error())
				continue
			}
			if row.SizeBytes > maxSafeInteger-plan.SourceBytes {
				plan.issue(relative, "total byte count exceeds the plan limit")
				continue
			}
			plan.Rows = append(plan.Rows, row)
			plan.SourceBytes += row.SizeBytes
		default:
			plan.issue(relative, "symlink or non-regular file is outside scan scope")
		}
	}
}

func hashFile(parent int, name, relative string, expected unix.Stat_t) (Observation, error) {
	// The directory stat prevents opening a known device, FIFO, or similar input.
	if expected.Mode&unix.S_IFMT != unix.S_IFREG || expected.Size < 0 || expected.Size > maxSafeInteger {
		return Observation{}, fmt.Errorf("file is not a supported regular input")
	}
	file, err := openRegular(parent, name)
	if err != nil {
		return Observation{}, err
	}
	defer file.Close()
	var opened unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &opened); err != nil ||
		opened.Dev != expected.Dev || opened.Ino != expected.Ino || opened.Size != expected.Size {
		return Observation{}, fmt.Errorf("file identity changed before hashing")
	}
	before, err := file.Stat()
	if err != nil {
		return Observation{}, err
	}
	hash := blake3.New(32, nil)
	size, err := io.Copy(hash, io.LimitReader(file, expected.Size+1))
	if err != nil {
		return Observation{}, err
	}
	after, err := file.Stat()
	if err != nil {
		return Observation{}, err
	}
	var current unix.Stat_t
	if err := unix.Fstatat(parent, name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil ||
		current.Dev != expected.Dev || current.Ino != expected.Ino || current.Mode&unix.S_IFMT != unix.S_IFREG ||
		size != expected.Size || after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return Observation{}, fmt.Errorf("file changed while hashing")
	}
	return Observation{
		Path: relative, AssetID: "blake3:" + hex.EncodeToString(hash.Sum(nil)),
		SizeBytes: size, SourceInode: uint64(opened.Ino), ModifiedAt: before.ModTime().UTC().Format(time.RFC3339Nano),
	}, nil
}

func inspectDestination(archive *root, target, assetID string) (string, error) {
	parts := strings.Split(target, "/")
	parent := int(archive.file.Fd())
	defer func() {
		if parent != int(archive.file.Fd()) {
			unix.Close(parent)
		}
	}()
	for _, name := range parts[:len(parts)-1] {
		fd, err := unix.Openat(parent, name, directoryFlags, 0)
		if errors.Is(err, unix.ENOENT) {
			return "copy", nil
		}
		if err != nil {
			return "conflict", err
		}
		if parent != int(archive.file.Fd()) {
			unix.Close(parent)
		}
		parent = fd
		var dir unix.Stat_t
		if err := unix.Fstat(fd, &dir); err != nil || uint64(dir.Dev) != archive.Device {
			return "conflict", fmt.Errorf("archive path leaves the admitted device")
		}
	}
	name := parts[len(parts)-1]
	var occupant unix.Stat_t
	err := unix.Fstatat(parent, name, &occupant, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return "copy", nil
	}
	if err != nil {
		return "conflict", err
	}
	if uint64(occupant.Dev) != archive.Device {
		return "conflict", fmt.Errorf("archive file leaves the admitted device")
	}
	row, err := hashFile(parent, name, target, occupant)
	if err != nil {
		return "conflict", err
	}
	if row.AssetID != assetID {
		return "conflict", fmt.Errorf("existing content has a different digest")
	}
	return "reuse", nil
}

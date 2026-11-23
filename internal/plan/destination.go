package plan

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"

	"golang.org/x/sys/unix"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

type archiveDirectory struct {
	stamp fileStamp
	names map[string][]string
}

type destinationInspector struct {
	archive     *root
	directories map[fileIdentity]archiveDirectory
	fold        cases.Caser
}

func newDestinationInspector(archive *root) *destinationInspector {
	return &destinationInspector{
		archive: archive, directories: make(map[fileIdentity]archiveDirectory), fold: cases.Fold(),
	}
}

func (d *destinationInspector) equivalent(name string) string {
	return norm.NFC.String(d.fold.String(norm.NFC.String(name)))
}

func (d *destinationInspector) reserve(parent int, name string) error {
	var info unix.Stat_t
	if err := unix.Fstat(parent, &info); err != nil {
		return err
	}
	stamp := snapshot(info)
	if stamp.device != d.archive.Device || !stamp.hasChangeTime() {
		return fmt.Errorf("archive directory device or change metadata could not be verified")
	}
	directory, ok := d.directories[stamp.fileIdentity]
	if !ok {
		var err error
		directory, err = d.readDirectory(parent, stamp)
		if err != nil {
			return err
		}
		d.directories[stamp.fileIdentity] = directory
	}
	if directory.stamp != stamp {
		return fmt.Errorf("archive directory changed during planning")
	}
	matches := directory.names[d.equivalent(name)]
	if len(matches) > 1 || (len(matches) == 1 && matches[0] != name) {
		return fmt.Errorf("archive component %q has a case- or normalization-equivalent spelling", name)
	}
	return nil
}

func (d *destinationInspector) readDirectory(parent int, stamp fileStamp) (archiveDirectory, error) {
	reader, err := unix.Openat(parent, ".", directoryFlags, 0)
	if err != nil {
		return archiveDirectory{}, err
	}
	file := os.NewFile(uintptr(reader), "archive directory")
	defer file.Close()
	names, err := file.Readdirnames(-1)
	if err != nil {
		return archiveDirectory{}, err
	}
	var after unix.Stat_t
	if err := unix.Fstat(reader, &after); err != nil || snapshot(after) != stamp {
		return archiveDirectory{}, fmt.Errorf("archive directory changed while reserving names")
	}
	directory := archiveDirectory{stamp: stamp, names: make(map[string][]string, len(names))}
	for _, name := range names {
		if !utf8.ValidString(name) {
			return archiveDirectory{}, fmt.Errorf("archive directory contains a non-UTF-8 name")
		}
		key := d.equivalent(name)
		directory.names[key] = append(directory.names[key], name)
	}
	return directory, nil
}

func (d *destinationInspector) inspect(target, assetID string) (string, error) {
	parts := strings.Split(target, "/")
	rootFD := int(d.archive.file.Fd())
	parent := rootFD
	defer func() {
		if parent != rootFD {
			unix.Close(parent)
		}
	}()
	for _, name := range parts[:len(parts)-1] {
		if err := d.reserve(parent, name); err != nil {
			return "conflict", err
		}
		fd, err := unix.Openat(parent, name, directoryFlags, 0)
		if errors.Is(err, unix.ENOENT) {
			return "copy", nil
		}
		if err != nil {
			return "conflict", err
		}
		if parent != rootFD {
			unix.Close(parent)
		}
		parent = fd
	}
	name := parts[len(parts)-1]
	if err := d.reserve(parent, name); err != nil {
		return "conflict", err
	}
	var occupant unix.Stat_t
	err := unix.Fstatat(parent, name, &occupant, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return "copy", nil
	}
	if err != nil {
		return "conflict", err
	}
	if uint64(occupant.Dev) != d.archive.Device {
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

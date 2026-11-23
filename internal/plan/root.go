package plan

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"golang.org/x/sys/unix"
)

const Marker = ".media-vault-root"

const directoryFlags = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_NOFOLLOW | unix.O_CLOEXEC

var rootIDPattern = regexp.MustCompile(`^[a-z0-9._-]{1,64}$`)

type RootSpec struct {
	Path   string
	ID     string
	Device uint64
}

type RootIdentity struct {
	ID     string `json:"root_id"`
	Device uint64 `json:"device"`
	Inode  uint64 `json:"inode"`
}

type fileIdentity struct {
	device uint64
	inode  uint64
}

func identity(info unix.Stat_t) fileIdentity {
	return fileIdentity{device: uint64(info.Dev), inode: uint64(info.Ino)}
}

type root struct {
	file      *os.File
	ancestors []fileIdentity
	RootIdentity
}

func openRoot(spec RootSpec) (*root, error) {
	if !rootIDPattern.MatchString(spec.ID) || spec.ID == "." || spec.ID == ".." || spec.Device == 0 {
		return nil, fmt.Errorf("root requires a valid ID and a nonzero admitted device")
	}
	if !filepath.IsAbs(spec.Path) || filepath.Clean(spec.Path) != spec.Path || spec.Path == "/" {
		return nil, fmt.Errorf("root path must be an absolute canonical directory below /")
	}
	fd, err := unix.Open("/", directoryFlags, 0)
	if err != nil {
		return nil, err
	}
	var info unix.Stat_t
	var ancestors []fileIdentity
	for _, part := range strings.Split(strings.TrimPrefix(spec.Path, "/"), "/") {
		child, openErr := unix.Openat(fd, part, directoryFlags, 0)
		unix.Close(fd)
		if openErr != nil {
			return nil, fmt.Errorf("root %q unavailable: %w", spec.ID, openErr)
		}
		fd = child
		if err := unix.Fstat(fd, &info); err != nil {
			unix.Close(fd)
			return nil, fmt.Errorf("check root %q ancestry: %w", spec.ID, err)
		}
		ancestors = append(ancestors, identity(info))
	}
	dir := os.NewFile(uintptr(fd), spec.Path)
	if uint64(info.Dev) != spec.Device {
		dir.Close()
		return nil, fmt.Errorf("root %q unavailable: mounted device does not match", spec.ID)
	}
	marker, err := openRegular(fd, Marker)
	if err != nil {
		dir.Close()
		return nil, fmt.Errorf("root %q unavailable: marker: %w", spec.ID, err)
	}
	var markerStat unix.Stat_t
	err = unix.Fstat(int(marker.Fd()), &markerStat)
	if err != nil || uint64(markerStat.Dev) != spec.Device {
		marker.Close()
		dir.Close()
		return nil, fmt.Errorf("root %q unavailable: marker device could not be verified", spec.ID)
	}
	data, err := io.ReadAll(io.LimitReader(marker, 66))
	marker.Close()
	if err != nil || string(data) != spec.ID+"\n" {
		dir.Close()
		return nil, fmt.Errorf("root %q unavailable: marker does not match", spec.ID)
	}
	return &root{file: dir, ancestors: ancestors, RootIdentity: RootIdentity{
		ID: spec.ID, Device: spec.Device, Inode: uint64(info.Ino),
	}}, nil
}

func openRegular(parent int, name string) (*os.File, error) {
	var expected, opened unix.Stat_t
	if err := unix.Fstatat(parent, name, &expected, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, err
	}
	if expected.Mode&unix.S_IFMT != unix.S_IFREG {
		return nil, fmt.Errorf("%q is not a regular file", name)
	}
	fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if err := unix.Fstat(fd, &opened); err != nil {
		file.Close()
		return nil, err
	}
	if opened.Dev != expected.Dev || opened.Ino != expected.Ino || opened.Mode&unix.S_IFMT != unix.S_IFREG {
		file.Close()
		return nil, fmt.Errorf("%q identity changed during open", name)
	}
	return file, nil
}

func checkRoot(spec RootSpec, expected *root) error {
	current, err := openRoot(spec)
	if err != nil {
		return err
	}
	defer current.file.Close()
	if current.RootIdentity != expected.RootIdentity || !slices.Equal(current.ancestors, expected.ancestors) {
		return fmt.Errorf("root %q changed during planning", spec.ID)
	}
	return nil
}

func rootOverlap(a, b *root) bool {
	return slices.Contains(a.ancestors, b.ancestors[len(b.ancestors)-1]) ||
		slices.Contains(b.ancestors, a.ancestors[len(a.ancestors)-1])
}

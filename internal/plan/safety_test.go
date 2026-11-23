package plan

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestOpenedRootAncestryRefusesOverlap(t *testing.T) {
	outer := fixtureRoot(t, "outer")
	parent := filepath.Join(outer.Path, "CaseParent")
	child := filepath.Join(parent, "inner")
	if err := os.MkdirAll(child, 0700); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(parent, Marker), "parent\n")
	write(t, filepath.Join(child, Marker), "child\n")
	parentSpec := RootSpec{Path: parent, ID: "parent", Device: outer.Device}
	childSpec := RootSpec{Path: child, ID: "child", Device: outer.Device}
	for _, pair := range [][2]RootSpec{{parentSpec, childSpec}, {childSpec, parentSpec}} {
		if _, err := Build(Options{Ingest: pair[0], Archive: pair[1]}); err == nil ||
			!strings.Contains(err.Error(), "disjoint") {
			t.Fatalf("opened ancestry did not reject overlap: %v", err)
		}
	}
	t.Run("case-insensitive-alias", func(t *testing.T) {
		childSpec.Path = filepath.Join(outer.Path, "CASEPARENT", "inner")
		if _, err := os.Stat(childSpec.Path); os.IsNotExist(err) {
			t.Skip("fixture filesystem is case-sensitive")
		} else if err != nil {
			t.Fatal(err)
		}
		if _, err := Build(Options{Ingest: childSpec, Archive: parentSpec}); err == nil ||
			!strings.Contains(err.Error(), "disjoint") {
			t.Fatalf("case alias escaped inode ancestry check: %v", err)
		}
	})
}

func TestDestinationCaseEquivalentComponents(t *testing.T) {
	for _, name := range []string{"ancestor", "leaf"} {
		t.Run(name, func(t *testing.T) {
			ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
			write(t, filepath.Join(ingest.Path, "clip.mov"), "abc")
			options := Options{Ingest: ingest, Archive: archive}
			before, err := Build(options)
			if err != nil || len(before.Plan.Rows) != 1 {
				t.Fatalf("could not plan fixture: %+v %v", before, err)
			}
			target := filepath.Join(archive.Path, before.Plan.Rows[0].TargetPath)
			if name == "ancestor" {
				if err := os.Mkdir(filepath.Join(archive.Path, "ORIGINALS"), 0700); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
					t.Fatal(err)
				}
				write(t, filepath.Join(filepath.Dir(target), strings.ToUpper(filepath.Base(target))), "abc")
			}
			after, err := Build(options)
			if err != nil || after.Plan.Complete || len(after.Plan.Rows) != 1 ||
				after.Plan.Rows[0].Action != "conflict" || len(after.Plan.Issues) != 1 ||
				!strings.Contains(after.Plan.Issues[0].Reason, "equivalent") {
				t.Fatalf("equivalent destination not rejected: %+v %v", after, err)
			}
		})
	}
}

func TestDestinationUnicodeEquivalentNames(t *testing.T) {
	spec := fixtureRoot(t, "archive")
	write(t, filepath.Join(spec.Path, "Cafe\u0301.mov"), "file")
	root, err := openRoot(spec)
	if err != nil {
		t.Fatal(err)
	}
	defer root.file.Close()
	destination := newDestinationInspector(root)
	if err := destination.reserve(int(root.file.Fd()), "CAFÉ.mov"); err == nil ||
		!strings.Contains(err.Error(), "normalization-equivalent") {
		t.Fatalf("equivalent Unicode name was not reserved: %v", err)
	}
}

func TestStableReadRejectsMutationAndReplacement(t *testing.T) {
	spec := fixtureRoot(t, "ingest")
	name := "source.mov"
	filename := filepath.Join(spec.Path, name)
	write(t, filename, "abc")
	fixed := time.Unix(1700000000, 0)
	if err := os.Chtimes(filename, fixed, fixed); err != nil {
		t.Fatal(err)
	}
	root, err := openRoot(spec)
	if err != nil {
		t.Fatal(err)
	}
	defer root.file.Close()
	parent := int(root.file.Fd())
	file, err := openRegular(parent, name)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var initial, changed unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &initial); err != nil {
		t.Fatal(err)
	}
	if !stableFile(parent, name, file, snapshot(initial)) {
		t.Fatal("unchanged descriptor and name should match")
	}

	time.Sleep(10 * time.Millisecond)
	write(t, filename, "xyz")
	if err := os.Chtimes(filename, fixed, fixed); err != nil {
		t.Fatal(err)
	}
	if err := unix.Fstat(int(file.Fd()), &changed); err != nil {
		t.Fatal(err)
	}
	if initial.Size != changed.Size || initial.Mtim != changed.Mtim || initial.Ctim == changed.Ctim {
		t.Fatal("fixture did not isolate the change-time signal")
	}
	if stableFile(parent, name, file, snapshot(initial)) {
		t.Fatal("same-size rewrite with restored mtime was accepted")
	}
	if _, err := hashFile(parent, name, name, initial); err == nil {
		t.Fatal("stale scan identity was accepted at open")
	}
	replacement := filepath.Join(spec.Path, "replacement.mov")
	write(t, replacement, "xyz")
	if err := os.Rename(replacement, filename); err != nil {
		t.Fatal(err)
	}
	if stableFile(parent, name, file, snapshot(changed)) {
		t.Fatal("replacement at the original path was accepted")
	}
}

func TestMacMetadataSkipsAreReported(t *testing.T) {
	ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
	for _, name := range []string{"clip.mov", ".DS_Store", "._clip.mov"} {
		write(t, filepath.Join(ingest.Path, name), "abc")
	}
	result, err := Build(Options{Ingest: ingest, Archive: archive})
	if err != nil || !result.Plan.Complete || len(result.Plan.Rows) != 1 || len(result.Plan.Skipped) != 2 {
		t.Fatalf("unexpected skip result: %+v %v", result, err)
	}
}

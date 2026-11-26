package plan

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func fixtureRoot(t *testing.T, id string) RootSpec {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(path, Marker), id+"\n")
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		t.Fatal(err)
	}
	return RootSpec{Path: path, ID: id, Device: uint64(st.Dev)}
}

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestPlanIsReadOnlyAndDeterministic(t *testing.T) {
	ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
	write(t, filepath.Join(ingest.Path, "B.mov"), "abc")
	write(t, filepath.Join(ingest.Path, "A.mov"), "abc")
	options := Options{Ingest: ingest, Archive: archive, Date: "2026-11-23", Device: "camera-1", Project: "demo"}
	first, err := Build(options)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Build(options)
	if err != nil {
		t.Fatal(err)
	}
	if first.Digest != second.Digest || !first.Plan.Complete || len(first.Plan.Rows) != 2 ||
		first.Plan.SourceBytes != 6 || first.Plan.CopyBytes != 3 {
		t.Fatalf("unexpected plan: %+v", first)
	}
	a, b := first.Plan.Rows[0], first.Plan.Rows[1]
	if a.Path != "A.mov" || a.Action != "copy" || b.Action != "duplicate" ||
		b.DuplicateOf != a.Path || a.TargetPath != b.TargetPath ||
		!strings.HasPrefix(a.TargetPath, "Originals/camera-1/2026-11-23/") {
		t.Fatalf("unexpected duplicate plan: %+v", first.Plan.Rows)
	}
	if a.AssetID != "blake3:6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85" {
		t.Fatalf("incorrect BLAKE3 vector: %s", a.AssetID)
	}
	archiveEntries, err := os.ReadDir(archive.Path)
	if err != nil || len(archiveEntries) != 1 || archiveEntries[0].Name() != Marker {
		t.Fatalf("planner touched archive: %v %v", archiveEntries, err)
	}
	raw, err := os.ReadFile(filepath.Join(ingest.Path, "A.mov"))
	if err != nil || string(raw) != "abc" {
		t.Fatalf("planner touched ingest: %q %v", raw, err)
	}
}

func TestDestinationReuseAndConflict(t *testing.T) {
	ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
	write(t, filepath.Join(ingest.Path, "one.mov"), "abc")
	options := Options{Ingest: ingest, Archive: archive}
	value, err := Build(options)
	if err != nil || len(value.Plan.Rows) != 1 {
		t.Fatalf("planning fixture: %+v, %v", value, err)
	}
	target := filepath.Join(archive.Path, value.Plan.Rows[0].TargetPath)
	if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		t.Fatal(err)
	}
	write(t, target, "abc")
	value, err = Build(options)
	if err != nil || !value.Plan.Complete || value.Plan.Rows[0].Action != "reuse" || value.Plan.CopyBytes != 0 {
		t.Fatalf("matching destination not reusable: %+v, %v", value, err)
	}
	write(t, target, "bad")
	value, err = Build(options)
	if err != nil || value.Plan.Complete || value.Plan.Rows[0].Action != "conflict" {
		t.Fatalf("different destination not rejected: %+v, %v", value, err)
	}
	raw, err := os.ReadFile(target)
	if err != nil || string(raw) != "bad" {
		t.Fatalf("conflicted bytes changed: %q %v", raw, err)
	}
}

func TestSymlinkAndWrongDeviceRefused(t *testing.T) {
	ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
	write(t, filepath.Join(archive.Path, "external.mov"), "abc")
	if err := os.Symlink(filepath.Join(archive.Path, "external.mov"), filepath.Join(ingest.Path, "escape.mov")); err != nil {
		t.Fatal(err)
	}
	options := Options{Ingest: ingest, Archive: archive}
	value, err := Build(options)
	if err != nil || value.Plan.Complete || len(value.Plan.Rows) != 0 || len(value.Plan.Issues) != 1 {
		t.Fatalf("symlink was not excluded: %+v %v", value, err)
	}
	options.Ingest.Device++
	if _, err := Build(options); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("wrong mount was not refused: %v", err)
	}
}

func TestCatalogFixtureAssetIDs(t *testing.T) {
	type item struct {
		AssetID    string   `json:"asset_id"`
		SizeBytes  int64    `json:"size_bytes"`
		TrackRole  string   `json:"track_role"`
		SpeakerIDs []string `json:"speaker_ids"`
	}
	var catalog struct {
		Items []item `json:"items"`
	}
	readJSON(t, "../../docs/catalog/catalog-v1-example.json", &catalog)
	if len(catalog.Items) != 5 {
		t.Fatalf("expected five fixture items, got %d", len(catalog.Items))
	}
	ingest, archive := fixtureRoot(t, "ingest"), fixtureRoot(t, "archive")
	type expectedAsset struct {
		id   string
		size int64
	}
	expected := make(map[string]expectedAsset)
	sizes := make(map[string]int64)
	for i, item := range catalog.Items {
		payload := "fixture-old"
		switch item.TrackRole {
		case "speaker":
			if len(item.SpeakerIDs) != 1 || !strings.HasPrefix(item.SpeakerIDs[0], "speaker-") {
				t.Fatalf("bad speaker fixture: %+v", item)
			}
			payload = "synthetic session " + strings.TrimPrefix(item.SpeakerIDs[0], "speaker-")
		case "program":
			payload = "synthetic session mix"
		case "":
		default:
			t.Fatalf("unexpected fixture track role %q", item.TrackRole)
		}
		name := fmt.Sprintf("catalog-%d.mov", i)
		write(t, filepath.Join(ingest.Path, name), payload)
		expected[name] = expectedAsset{item.AssetID, item.SizeBytes}
		sizes[item.AssetID] = item.SizeBytes
	}
	var scenarios struct {
		AssetID string `json:"asset_id"`
		Cases   []struct {
			Name    string  `json:"name"`
			Payload *string `json:"opened_utf8"`
			AssetID string  `json:"opened_asset_id"`
		} `json:"cases"`
	}
	readJSON(t, "../../docs/catalog/catalog-v1-open-cases.json", &scenarios)
	selectedSize, ok := sizes[scenarios.AssetID]
	if !ok {
		t.Fatalf("selected asset %q is missing from the catalog fixture", scenarios.AssetID)
	}
	replacementCases := 0
	originalCases := 0
	for i, scenario := range scenarios.Cases {
		if scenario.Payload == nil {
			if scenario.AssetID != "" {
				t.Fatalf("%s has an opened asset ID without payload bytes", scenario.Name)
			}
			continue
		}
		id := scenarios.AssetID
		if scenario.AssetID == "" {
			originalCases++
		} else {
			replacementCases++
			id = scenario.AssetID
			if id == scenarios.AssetID {
				t.Fatalf("%s must have a different asset ID", scenario.Name)
			}
		}
		name := fmt.Sprintf("open-%d.mov", i)
		write(t, filepath.Join(ingest.Path, name), *scenario.Payload)
		expected[name] = expectedAsset{id, selectedSize}
	}
	if originalCases == 0 || replacementCases != 1 {
		t.Fatalf("expected original payloads and one replacement, got %d originals and %d replacements", originalCases, replacementCases)
	}

	result, err := Build(Options{Ingest: ingest, Archive: archive})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Plan.Complete || len(result.Plan.Rows) != len(expected) {
		t.Fatalf("expected a complete plan of %d fixture files, got %d rows and issues %+v", len(expected), len(result.Plan.Rows), result.Plan.Issues)
	}
	for _, row := range result.Plan.Rows {
		want, ok := expected[row.Path]
		if !ok {
			t.Fatalf("unexpected fixture row %q", row.Path)
		}
		if row.AssetID != want.id || row.SizeBytes != want.size {
			t.Errorf("%s: planner returned %s (%d bytes), want %s (%d bytes)", row.Path, row.AssetID, row.SizeBytes, want.id, want.size)
		}
		delete(expected, row.Path)
	}
}

func readJSON(t *testing.T, path string, target any) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		t.Fatal(err)
	}
}

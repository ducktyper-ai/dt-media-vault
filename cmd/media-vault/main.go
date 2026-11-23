package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/ducktyper-ai/dt-media-vault/internal/plan"
)

func run(args []string, output, diagnostic io.Writer) int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprintln(output, "Usage: media-vault plan [--ingest path --ingest-id id --ingest-device n --archive path --archive-id id --archive-device n]")
		return 0
	}
	if args[0] != "plan" {
		fmt.Fprintf(diagnostic, "Unknown command %q. Run media-vault --help.\n", args[0])
		return 2
	}
	var options plan.Options
	set := flag.NewFlagSet("media-vault plan", flag.ContinueOnError)
	set.SetOutput(diagnostic)
	set.StringVar(&options.Ingest.Path, "ingest", "", "canonical ingest directory")
	set.StringVar(&options.Ingest.ID, "ingest-id", "", "approved ingest root ID")
	set.Uint64Var(&options.Ingest.Device, "ingest-device", 0, "approved ingest device number")
	set.StringVar(&options.Archive.Path, "archive", "", "canonical archive directory")
	set.StringVar(&options.Archive.ID, "archive-id", "", "approved archive root ID")
	set.Uint64Var(&options.Archive.Device, "archive-device", 0, "approved archive device number")
	set.StringVar(&options.Date, "date", "", "known recording date for this batch (YYYY-MM-DD)")
	set.StringVar(&options.Device, "device", "", "known device ID for this batch")
	set.StringVar(&options.Project, "project", "", "known project ID for this batch")
	if err := set.Parse(args[1:]); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	if set.NArg() != 0 {
		fmt.Fprintln(diagnostic, "Unexpected positional arguments.")
		return 2
	}
	result, err := plan.Build(options)
	if err != nil {
		fmt.Fprintln(diagnostic, err)
		return 1
	}
	encoder := json.NewEncoder(output)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintln(diagnostic, err)
		return 1
	}
	if !result.Plan.Complete {
		return 1
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

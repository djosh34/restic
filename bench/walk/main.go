// Command walkbench generates a synthetic tree of small files shaped like
// Rust target and node_modules folders, and runs count-only scans over it.
//
//	walkbench gen  -root DIR -files N [-seed S]
//	walkbench scan -root DIR -mode walkdir-lstat|walkdir|bulk
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: walkbench gen|scan ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "gen":
		fl := flag.NewFlagSet("gen", flag.ExitOnError)
		root := fl.String("root", "", "root directory")
		files := fl.Int("files", 100000, "number of files and symlinks to create")
		seed := fl.Uint64("seed", 1, "random seed")
		workers := fl.Int("workers", 8, "parallel writers")
		fl.Parse(os.Args[2:])
		must(generate(*root, *files, *seed, *workers))
	case "scan":
		fl := flag.NewFlagSet("scan", flag.ExitOnError)
		root := fl.String("root", "", "root directory")
		mode := fl.String("mode", "walkdir-lstat", "walkdir-lstat, walkdir or bulk")
		fl.Parse(os.Args[2:])
		must(scan(*root, *mode))
	default:
		fmt.Fprintln(os.Stderr, "unknown command", os.Args[1])
		os.Exit(2)
	}
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// counts is what every scan reports.
type counts struct {
	Mode     string  `json:"mode"`
	Files    int64   `json:"files"`
	Dirs     int64   `json:"dirs"`
	Symlinks int64   `json:"symlinks"`
	Other    int64   `json:"other"`
	Bytes    int64   `json:"bytes"`
	Errors   int64   `json:"errors"`
	Seconds  float64 `json:"seconds"`
	// EntriesPerSec counts files, dirs, symlinks and other entries.
	EntriesPerSec float64 `json:"entries_per_sec"`
}

func scan(root, mode string) error {
	c := counts{Mode: mode}
	start := time.Now()
	var err error
	switch mode {
	case "walkdir-lstat":
		err = scanWalkDir(root, true, &c)
	case "walkdir":
		err = scanWalkDir(root, false, &c)
	case "bulk":
		err = scanBulk(root, &c)
	default:
		return fmt.Errorf("unknown mode %q", mode)
	}
	if err != nil {
		return err
	}
	c.Seconds = time.Since(start).Seconds()
	c.EntriesPerSec = float64(c.Files+c.Dirs+c.Symlinks+c.Other) / c.Seconds
	return json.NewEncoder(os.Stdout).Encode(c)
}

// scanWalkDir uses filepath.WalkDir. With lstat it calls os.Lstat on every
// entry, like a backup tool that needs size and mtime. Without it, it only
// uses the type bits that readdir returns.
func scanWalkDir(root string, lstat bool, c *counts) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			c.Errors++
			return nil
		}
		typ := d.Type()
		if lstat {
			fi, err := os.Lstat(path)
			if err != nil {
				c.Errors++
				return nil
			}
			typ = fi.Mode().Type()
			if fi.Mode().IsRegular() {
				c.Bytes += fi.Size()
			}
		}
		switch {
		case typ.IsDir():
			c.Dirs++
		case typ.IsRegular():
			c.Files++
		case typ&fs.ModeSymlink != 0:
			c.Symlinks++
		default:
			c.Other++
		}
		return nil
	})
}

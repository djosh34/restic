// probe is a test binary for issue 15: it carries the stock restic binary,
// writes it out, and replaces itself while running under launchd.
package main

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

//go:embed restic.bin
var resticBin []byte

//go:embed restic.sha256
var resticSum string

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: probe version|write-restic <path>|daemon <staged>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Printf("probe version=%s pid=%d\n", version, os.Getpid())
	case "write-restic":
		if err := writeFile(os.Args[2], resticBin); err != nil {
			fmt.Println("write-restic error:", err)
			os.Exit(1)
		}
		got, _ := os.ReadFile(os.Args[2])
		sum := sha256.Sum256(got)
		want := strings.TrimSpace(resticSum)
		fmt.Printf("write-restic ok path=%s sha256=%s match=%v\n", os.Args[2], hex.EncodeToString(sum[:]), hex.EncodeToString(sum[:]) == want)
	case "daemon":
		daemon(os.Args[2])
	}
}

// writeFile writes data to a temp file in the target's directory, then
// renames it over the target, so the target path always points at a whole file
// and a running copy keeps its old inode.
func writeFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".probe-new-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// daemon logs a heartbeat. On SIGUSR1 it replaces its own executable with the
// staged file and exits, so launchd (KeepAlive) starts the new version.
func daemon(staged string) {
	exe, _ := os.Executable()
	exe, _ = filepath.EvalSymlinks(exe)
	fmt.Printf("%s start version=%s pid=%d exe=%s\n", time.Now().Format(time.RFC3339), version, os.Getpid(), exe)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGUSR1, syscall.SIGTERM)
	tick := time.NewTicker(2 * time.Second)
	for {
		select {
		case <-tick.C:
			fmt.Printf("%s beat version=%s pid=%d\n", time.Now().Format(time.RFC3339), version, os.Getpid())
		case s := <-sig:
			if s == syscall.SIGTERM {
				fmt.Printf("%s SIGTERM version=%s, exiting\n", time.Now().Format(time.RFC3339), version)
				os.Exit(0)
			}
			data, err := os.ReadFile(staged)
			if err == nil {
				err = writeFile(exe, data)
			}
			fmt.Printf("%s self-replace from %s err=%v, exiting for launchd restart\n", time.Now().Format(time.RFC3339), staged, err)
			os.Exit(0)
		}
	}
}

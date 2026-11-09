package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func main() {
	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Не удалось определить путь установленного загрузчика:", err)
		os.Exit(2)
	}

	// Installed as runtime\\Scripts\\yandex-music-downloader.exe.
	// The embeddable CPython runtime is two directories above this launcher.
	runtimeDir := filepath.Dir(filepath.Dir(executable))
	pythonExe := filepath.Join(runtimeDir, "python.exe")
	if _, err := os.Stat(pythonExe); err != nil {
		fmt.Fprintf(os.Stderr, "Встроенный Python не найден: %s\nПереустановите Downloader Plus.\n", pythonExe)
		os.Exit(2)
	}

	args := make([]string, 0, len(os.Args)+4)
	// The upstream package registers ymd.cli:main as a console-script entry
	// point, but ymd/cli.py does not execute main() when run with python -m.
	args = append(args, "-u", "-c", "from ymd.cli import main; raise SystemExit(main())")
	args = append(args, os.Args[1:]...)

	cmd := exec.Command(pythonExe, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()

	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintln(os.Stderr, "Не удалось запустить встроенный Python:", err)
		os.Exit(1)
	}
}

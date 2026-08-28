package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/qrioso/ridenow-noping/relay/internal/access"
)

const defaultAccessFile = "/etc/ridenow-noping/access-keys.yaml"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "add":
		err = add(os.Args[2:])
	case "list":
		err = list(os.Args[2:])
	case "revoke":
		err = revoke(os.Args[2:])
	case "validate":
		err = validate(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: ridenow-token <add|list|revoke|validate> [options]")
}

func add(arguments []string) error {
	flags := flag.NewFlagSet("add", flag.ContinueOnError)
	path := flags.String("file", envOrDefault("RIDENOW_ACCESS_FILE", defaultAccessFile), "access file")
	id := flags.String("id", "", "unique token id")
	tokenFlag := flags.String("token", "", "owner-provided token")
	maxDevices := flags.Int("max-devices", 1, "maximum registered devices")
	note := flags.String("note", "", "operator note")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *id == "" {
		return fmt.Errorf("--id is required")
	}

	document, err := access.Load(*path)
	if err != nil {
		return err
	}
	token := *tokenFlag
	if token == "" {
		token = os.Getenv("RIDENOW_TOKEN")
	}
	if token == "" {
		token, err = access.GenerateToken(*id)
		if err != nil {
			return err
		}
	}
	if err := access.Add(&document, *id, token, *maxDevices, *note); err != nil {
		return err
	}
	if err := access.WriteAtomic(*path, document); err != nil {
		return err
	}
	fmt.Println("Llave creada. Guárdala ahora; no se volverá a mostrar:")
	fmt.Println(token)
	return nil
}

func list(arguments []string) error {
	flags := flag.NewFlagSet("list", flag.ContinueOnError)
	path := flags.String("file", envOrDefault("RIDENOW_ACCESS_FILE", defaultAccessFile), "access file")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	document, err := access.Load(*path)
	if err != nil {
		return err
	}
	for _, id := range access.SortedIDs(document) {
		entry := document.Keys[id]
		fmt.Printf("%s\tenabled=%t\tmaxDevices=%d\tnote=%s\n", id, entry.Enabled, entry.MaxDevices, entry.Note)
	}
	return nil
}

func revoke(arguments []string) error {
	flags := flag.NewFlagSet("revoke", flag.ContinueOnError)
	path := flags.String("file", envOrDefault("RIDENOW_ACCESS_FILE", defaultAccessFile), "access file")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: ridenow-token revoke [--file path] <id>")
	}
	document, err := access.Load(*path)
	if err != nil {
		return err
	}
	if err := access.Revoke(&document, flags.Arg(0)); err != nil {
		return err
	}
	if err := access.WriteAtomic(*path, document); err != nil {
		return err
	}
	fmt.Printf("Llave %s revocada.\n", flags.Arg(0))
	return nil
}

func validate(arguments []string) error {
	flags := flag.NewFlagSet("validate", flag.ContinueOnError)
	path := flags.String("file", envOrDefault("RIDENOW_ACCESS_FILE", defaultAccessFile), "access file")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	document, err := access.Load(*path)
	if err != nil {
		return err
	}
	fmt.Printf("Archivo válido: %d llave(s).\n", len(document.Keys))
	return nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
